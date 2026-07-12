package grotti

// Stratum message decode + dispatch. The one rule that matters (CLAUDE.md § The
// protocol): the pool sends server-initiated notifications with `id: null`, so
// dispatch is by the PRESENCE of "method" (a notification) versus "result" (a reply
// to one of our requests) — never by matching an id. A strict request/response
// client chokes here; this does not.
//
// Parsing allocates (core:encoding/json) — fine, this is per-message on Fenja's
// thread, never the hot loop. Everything is copied into the Job's inline buffers
// before the parse tree is freed.

import "core:encoding/json"

@(private)
hex_nibble :: proc(c: u8) -> (v: u8, ok: bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// hex_decode_into decodes hex `s` into `buf`, returning the byte count. Fails on odd
// length, non-hex, or overflow — a malformed job is dropped, never half-applied.
@(private)
hex_decode_into :: proc(s: string, buf: []u8) -> (n: int, ok: bool) {
	b := transmute([]u8)s
	if len(b) % 2 != 0 || len(b) / 2 > len(buf) {
		return 0, false
	}
	n = len(b) / 2
	for i in 0 ..< n {
		hi, ok1 := hex_nibble(b[i * 2])
		lo, ok2 := hex_nibble(b[i * 2 + 1])
		if !ok1 || !ok2 {
			return 0, false
		}
		buf[i] = (hi << 4) | lo
	}
	return n, true
}

@(private)
hex_exact :: proc(s: string, buf: []u8) -> bool {
	n, ok := hex_decode_into(s, buf)
	return ok && n == len(buf)
}

// fenja_handle_line parses and dispatches one JSON message.
fenja_handle_line :: proc(f: ^Fenja, line: []u8) {
	val, err := json.parse(line, parse_integers = true)
	if err != .None {
		return // tolerate blank/garbage lines
	}
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !is_obj {
		return
	}

	// A notification/request from the server carries "method" (id is null).
	if mval, has_method := obj["method"]; has_method {
		method, _ := mval.(json.String)
		params, _ := obj["params"].(json.Array)
		switch method {
		case "mining.set_difficulty":
			fenja_on_set_difficulty(f, params)
		case "mining.notify":
			fenja_on_notify(f, params)
		}
		return
	}

	// Otherwise it is a reply to one of our requests.
	if rval, has_result := obj["result"]; has_result {
		id, _ := obj["id"].(json.Integer)
		err_null := true
		if ev, has_err := obj["error"]; has_err {
			if _, is_null := ev.(json.Null); !is_null {
				err_null = false
			}
		}
		fenja_on_response(f, int(id), rval, err_null)
	}
}

@(private)
fenja_on_set_difficulty :: proc(f: ^Fenja, params: json.Array) {
	if len(params) < 1 {
		return
	}
	diff: f64
	#partial switch v in params[0] {
	case json.Integer:
		diff = f64(v)
	case json.Float:
		diff = v
	case:
		return
	}
	f.difficulty = diff
	f.target = target_from_difficulty(diff)
	f.have_diff = true
	if f.on_difficulty != nil {
		f.on_difficulty(f, diff)
	}
}

@(private)
fenja_on_notify :: proc(f: ^Fenja, params: json.Array) {
	if len(params) < 9 {
		return
	}
	job: Job

	id_s, _ := params[0].(json.String)
	job.id_len = copy(job.id[:], transmute([]u8)id_s)

	prev_s, _ := params[1].(json.String)
	prev_raw: [32]u8
	if !hex_exact(prev_s, prev_raw[:]) {
		return
	}
	job.prev = prevhash_stratum_to_internal(prev_raw)

	cb1_s, _ := params[2].(json.String)
	n1, ok1 := hex_decode_into(cb1_s, job.coinb1[:])
	if !ok1 {
		return
	}
	job.coinb1_len = n1

	cb2_s, _ := params[3].(json.String)
	n2, ok2 := hex_decode_into(cb2_s, job.coinb2[:])
	if !ok2 {
		return
	}
	job.coinb2_len = n2

	branches, _ := params[4].(json.Array)
	nb := 0
	for be in branches {
		if nb >= MAX_BRANCHES {
			break
		}
		bs, _ := be.(json.String)
		if !hex_exact(bs, job.branches[nb][:]) {
			return
		}
		nb += 1
	}
	job.n_branches = nb

	ver_s, _ := params[5].(json.String)
	nbits_s, _ := params[6].(json.String)
	ntime_s, _ := params[7].(json.String)
	v, okv := parse_u32_be_hex(ver_s)
	nbv, okn := parse_u32_be_hex(nbits_s)
	ntv, okt := parse_u32_be_hex(ntime_s)
	if !okv || !okn || !okt {
		return
	}
	job.version = v
	job.nbits = nbv
	job.ntime = ntv

	clean, _ := params[8].(json.Boolean)
	job.clean = bool(clean)

	// Fill in the per-session pieces the notify does not carry.
	job.en1_len = copy(job.en1[:], f.en1[:f.en1_len])
	job.en2_size = f.en2_size
	job.target = f.target
	job.net_target, _ = target_from_compact(job.nbits) // block threshold

	ring_publish(f.ring, job)
	f.job_count += 1
	if f.on_job != nil {
		f.on_job(f, &job)
	}
}

@(private)
fenja_on_response :: proc(f: ^Fenja, id: int, result: json.Value, err_null: bool) {
	switch id {
	case 1: // mining.subscribe
		arr, is_arr := result.(json.Array)
		if !is_arr || len(arr) < 3 {
			return
		}
		en1_s, _ := arr[1].(json.String)
		if n, ok := hex_decode_into(en1_s, f.en1[:]); ok {
			f.en1_len = n
		}
		#partial switch v in arr[2] {
		case json.Integer:
			f.en2_size = int(v)
		case json.Float:
			f.en2_size = int(v)
		}
		f.subscribed = true
	case 2: // mining.authorize
		b, _ := result.(json.Boolean)
		f.authorized = bool(b)
		if f.on_authorized != nil {
			f.on_authorized(f, bool(b))
		}
	case:
		// mining.submit reply (id >= 3): result true + no error == accepted.
		b, is_bool := result.(json.Boolean)
		accepted := is_bool && bool(b) && err_null
		if accepted {
			stats_accepted(f.stats)
		} else {
			stats_rejected(f.stats)
		}
		if f.on_share_result != nil {
			f.on_share_result(f, id, accepted)
		}
	}
}
