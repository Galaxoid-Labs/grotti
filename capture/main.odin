package main

// Stratum session capture — a throwaway tool to record exactly what
// pool.drivechain.info sends on the wire, so Fenja can be built against the pool's
// REAL messages instead of a guessed protocol (DEVELOPMENT.md § Phase 0).
//
// It connects, subscribes, authorizes with your real address, then prints every
// byte the pool sends, verbatim, for ~60 seconds (long enough for a set_difficulty
// and one or two mining.notify). Copy the whole "raw pool output" block back.
//
//   odin run capture
//
// It only reads and prints. It never hashes and never submits a share.

import "core:fmt"
import "core:net"
import "core:time"

POOL :: "pool.drivechain.info:3334"
// mining.authorize username is <thunder-addr>.<rig>; the password is ignored.
AUTH_USER :: "4C8nSSdfsAFJM9zb2m5mJvvSRN2Y.grotti1"

CAPTURE_SECONDS :: 60.0

main :: proc() {
	fmt.printfln("[capture] dialing %s ...", POOL)
	sock, derr := net.dial_tcp_from_hostname_and_port_string(POOL)
	if derr != nil {
		fmt.eprintfln("[capture] connect failed: %v", derr)
		return
	}
	defer net.close(sock)
	fmt.println("[capture] connected")

	// Time out blocking recv so we can stop after CAPTURE_SECONDS even if the pool
	// goes quiet between notifies.
	if oerr := net.set_option(sock, .Receive_Timeout, 5 * time.Second); oerr != nil {
		fmt.eprintfln("[capture] set timeout failed: %v", oerr)
	}

	send_line(sock, `{"id":1,"method":"mining.subscribe","params":["grotti/0.1.0"]}`)
	send_line(sock, fmt.tprintf(`{{"id":2,"method":"mining.authorize","params":["%s","x"]}}`, AUTH_USER))

	fmt.println("\n----- raw pool output (copy everything between the dashed lines) -----")

	buf: [8192]u8
	start := time.tick_now()
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if n > 0 {
			// Verbatim — do not reformat; the exact bytes are the whole point.
			fmt.print(string(buf[:n]))
		}
		if n == 0 && rerr == nil {
			fmt.println("\n[capture] connection closed by pool")
			break
		}
		if time.duration_seconds(time.tick_diff(start, time.tick_now())) >= CAPTURE_SECONDS {
			break
		}
		// A recv error here is almost always the 5s read timeout; keep waiting for
		// the next notify until the overall capture window elapses.
	}

	fmt.println("\n----- end raw pool output -----")
	fmt.println("[capture] done — paste the block above back to Claude")
}

send_line :: proc(sock: net.TCP_Socket, line: string) {
	fmt.printfln("[capture] >> %s", line)
	msg := fmt.tprintf("%s\n", line)
	_, serr := net.send_tcp(sock, transmute([]u8)msg)
	if serr != nil {
		fmt.eprintfln("[capture] send failed: %v", serr)
	}
}
