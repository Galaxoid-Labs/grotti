package grotti

// Fenja — the stratum client. One thread owns the socket; nothing else touches it
// (DEVELOPMENT.md § The shape). Blocking recv with a short receive timeout gives us
// timers for free: we wake often enough to drain the share queue and to notice the
// quit flag, without an event loop.
//
// It parses the pool's messages (fenja_jsonrpc.odin) into Jobs it publishes to the
// ring, and drains found shares back out as mining.submit. On disconnect it
// reconnects with exponential backoff and re-subscribes.

import "base:intrinsics"
import "core:fmt"
import "core:net"
import "core:time"

MAX_LINE :: 16384 // a notify line is ~1 KB; this is comfortable headroom

Fenja :: struct {
	// wiring
	ring:           ^Job_Ring,
	shares:         ^Share_Queue,
	stats:          ^Stats,
	quit:           ^u32, // atomic, shared with the engine
	// config
	pool_addr:      string, // "host:port"
	auth_user:      string, // "<thunder-addr>.<rig>"
	// session state
	en1:            [MAX_EN1]u8,
	en1_len:        int,
	en2_size:       int,
	difficulty:     f64, // share difficulty (set_difficulty)
	net_difficulty: f64, // network difficulty (from job nbits) — for a block ETA
	target:         [32]u8,
	have_diff:      bool,
	subscribed:     bool,
	authorized:     bool,
	job_count:      int,
	next_submit_id: int,
	// socket + line framing
	sock:           net.TCP_Socket,
	linebuf:        [MAX_LINE]u8,
	linelen:        int,
	line_overflow:  bool,
	// optional logging hooks (the CLI wires these to the console; Fenja stays
	// decoupled from output). Any may be nil.
	on_event:        proc(f: ^Fenja, msg: string),
	on_difficulty:   proc(f: ^Fenja, diff: f64),
	on_job:          proc(f: ^Fenja, job: ^Job),
	on_authorized:   proc(f: ^Fenja, ok: bool),
	on_share_result: proc(f: ^Fenja, id: int, accepted: bool),
	on_block:        proc(f: ^Fenja, sh: ^Share),
}

@(private)
fenja_emit :: proc(f: ^Fenja, msg: string) {
	if f.on_event != nil {
		f.on_event(f, msg)
	}
}

@(private)
fenja_quitting :: proc(f: ^Fenja) -> bool {
	return intrinsics.atomic_load_explicit(f.quit, .Acquire) != 0
}

// fenja_run is the reconnect supervisor. Runs on its own thread until quit.
fenja_run :: proc(f: ^Fenja) {
	backoff := 1.0
	for !fenja_quitting(f) {
		if !fenja_connect(f) {
			fenja_sleep(f, backoff)
			backoff = min(backoff * 2, 30)
			continue
		}
		backoff = 1.0
		fenja_session(f) // blocks until disconnect or quit
		net.close(f.sock)
		f.subscribed = false
		f.authorized = false
		f.linelen = 0
		f.line_overflow = false
		if !fenja_quitting(f) {
			fenja_emit(f, "disconnected — reconnecting")
			fenja_sleep(f, backoff)
			backoff = min(backoff * 2, 30)
		}
	}
}

@(private)
fenja_connect :: proc(f: ^Fenja) -> bool {
	fenja_emit(f, fmt.tprintf("connecting to %s", f.pool_addr))
	sock, err := net.dial_tcp_from_hostname_and_port_string(f.pool_addr)
	if err != nil {
		fenja_emit(f, fmt.tprintf("connect failed: %v", err))
		return false
	}
	f.sock = sock
	// Short timeout so recv returns often enough to drain shares / see quit.
	_ = net.set_option(sock, .Receive_Timeout, 250 * time.Millisecond)

	fenja_send(f, `{"id":1,"method":"mining.subscribe","params":["grotti/0.1.0"]}`)
	fenja_send(f, fmt.tprintf(`{{"id":2,"method":"mining.authorize","params":["%s","x"]}}`, f.auth_user))
	fenja_emit(f, "subscribe + authorize sent")
	return true
}

@(private)
fenja_session :: proc(f: ^Fenja) {
	buf: [4096]u8
	for !fenja_quitting(f) {
		n, rerr := net.recv_tcp(f.sock, buf[:])
		if n > 0 {
			fenja_feed(f, buf[:n])
		}
		if rerr == .None {
			if n == 0 {
				return // graceful close by pool
			}
		} else if rerr == .Timeout || rerr == .Would_Block || rerr == .Interrupted {
			// expected: no data this window — fall through to drain shares
		} else {
			return // real error → reconnect
		}
		fenja_drain_shares(f)
		free_all(context.temp_allocator) // reclaim per-message tprintf scratch
	}
}

// fenja_feed splits the incoming byte stream on newlines and hands each complete
// line to the dispatcher. Handles a line split across recvs and (defensively) an
// over-long line by skipping to the next newline.
@(private)
fenja_feed :: proc(f: ^Fenja, data: []u8) {
	for c in data {
		switch c {
		case '\n':
			if !f.line_overflow && f.linelen > 0 {
				fenja_handle_line(f, f.linebuf[:f.linelen])
			}
			f.linelen = 0
			f.line_overflow = false
		case '\r':
		// ignore
		case:
			if f.linelen < len(f.linebuf) {
				f.linebuf[f.linelen] = c
				f.linelen += 1
			} else {
				f.line_overflow = true // too long; drop until newline
			}
		}
	}
}

@(private)
fenja_drain_shares :: proc(f: ^Fenja) {
	for {
		sh, ok := share_dequeue(f.shares)
		if !ok {
			break
		}
		fenja_submit(f, sh)
	}
}

// fenja_submit sends one mining.submit. The submit echo rule (CLAUDE.md): en2 and
// ntime must be byte-identical to what was hashed — they come straight from the
// Share, unmodified. ntime/nonce are big-endian hex of the u32 (round-tripping the
// exact values the notify delivered).
@(private)
fenja_submit :: proc(f: ^Fenja, sh: Share) {
	sh := sh // shadow: params are not addressable, can't slice directly
	f.next_submit_id += 1
	id := f.next_submit_id + 2 // ids 1,2 are subscribe/authorize
	en2_hex := hex_encode(sh.en2[:sh.en2_len])
	job_id := string(sh.id[:sh.id_len])
	line := fmt.tprintf(
		`{{"id":%d,"method":"mining.submit","params":["%s","%s","%s","%08x","%08x"]}}`,
		id,
		f.auth_user,
		job_id,
		en2_hex,
		sh.ntime,
		sh.nonce,
	)
	fenja_send(f, line)
	if sh.is_block && f.on_block != nil {
		f.on_block(f, &sh)
	}
	fenja_emit(f, fmt.tprintf("submit job %s nonce %08x", job_id, sh.nonce))
}

@(private)
fenja_send :: proc(f: ^Fenja, line: string) {
	msg := fmt.tprintf("%s\n", line)
	_, _ = net.send_tcp(f.sock, transmute([]u8)msg)
}

// hex_encode lowercases a byte slice into a temp-allocated hex string.
@(private)
hex_encode :: proc(b: []u8, allocator := context.temp_allocator) -> string {
	HEX := "0123456789abcdef"
	out := make([]u8, len(b) * 2, allocator)
	for v, i in b {
		out[i * 2] = HEX[v >> 4]
		out[i * 2 + 1] = HEX[v & 0xf]
	}
	return string(out)
}

// fenja_sleep waits up to `seconds`, in short chunks, so quit is honored promptly.
@(private)
fenja_sleep :: proc(f: ^Fenja, seconds: f64) {
	elapsed := 0.0
	for elapsed < seconds && !fenja_quitting(f) {
		time.sleep(100 * time.Millisecond)
		elapsed += 0.1
	}
}
