package grotti

// Header construction and the byte-order conversions — CLAUDE.md § Byte order,
// the single biggest source of Stratum bugs. Three conventions collide here:
// header little-endian fields, internal-order 32-byte hashes, and Stratum's
// word-swapped prevhash. Every conversion below has a test against real block data.
//
// This file holds the deterministic, offline-testable math. Parsing a live
// mining.notify into a Job (JSON, the coinbase from the wire) lands with the
// Stratum layer once we have the Phase 0 trace — developing that against an
// imagined protocol is exactly what DEVELOPMENT.md forbids.

import "core:encoding/endian"
import "sha256d"

Header :: [80]u8

// reverse32 swaps between a hash's internal order and its display/RPC big-endian
// order — they are byte-reverses of each other.
reverse32 :: proc(b: [32]u8) -> (r: [32]u8) {
	for i in 0 ..< 32 {
		r[i] = b[31 - i]
	}
	return
}

// prevhash_stratum_to_internal recovers the header's prev_hash bytes from the
// word-swapped hex Stratum sends. Each 4-byte word is byte-reversed, word order
// preserved (CLAUDE.md: "Reverse each 4-byte group again to recover header
// bytes"). Getting this wrong makes every share reject as "low difficulty" — the
// #1 bug. This function is its own inverse; the live encoding is confirmed against
// the Phase 0 trace.
prevhash_stratum_to_internal :: proc(s: [32]u8) -> (out: [32]u8) {
	for w in 0 ..< 8 {
		out[w * 4 + 0] = s[w * 4 + 3]
		out[w * 4 + 1] = s[w * 4 + 2]
		out[w * 4 + 2] = s[w * 4 + 1]
		out[w * 4 + 3] = s[w * 4 + 0]
	}
	return
}

// serialize_header lays out the 80-byte header. version/ntime/nbits/nonce are the
// parsed u32 values (Stratum delivers them as big-endian hex; the header stores
// them little-endian, so the caller parses hex->u32 and this writes LE). prev and
// merkle are already in internal 32-byte order.
serialize_header :: proc(
	version: u32,
	prev_internal: [32]u8,
	merkle_internal: [32]u8,
	ntime: u32,
	nbits: u32,
	nonce: u32,
) -> (h: Header) {
	prev := prev_internal // shadow: params are not addressable, can't slice directly
	merkle := merkle_internal
	endian.unchecked_put_u32le(h[0:4], version)
	copy(h[4:36], prev[:])
	copy(h[36:68], merkle[:])
	endian.unchecked_put_u32le(h[68:72], ntime)
	endian.unchecked_put_u32le(h[72:76], nbits)
	endian.unchecked_put_u32le(h[76:80], nonce)
	return
}

// block_hash returns the header's hash in display (big-endian) order, ready to
// compare against a target or a known block hash.
block_hash :: proc(h: Header) -> [32]u8 {
	h := h // shadow to a local so it is addressable for slicing
	return reverse32(sha256d.sum256d(h[:]))
}

// parse_u32_be_hex parses up to 8 hex digits as the big-endian encoding of a u32,
// as version/nbits/ntime arrive on the wire. No allocation.
parse_u32_be_hex :: proc(s: string) -> (v: u32, ok: bool) {
	if len(s) == 0 || len(s) > 8 {
		return 0, false
	}
	for r in transmute([]u8)s {
		nibble: u32
		switch {
		case r >= '0' && r <= '9':
			nibble = u32(r - '0')
		case r >= 'a' && r <= 'f':
			nibble = u32(r - 'a' + 10)
		case r >= 'A' && r <= 'F':
			nibble = u32(r - 'A' + 10)
		case:
			return 0, false
		}
		v = (v << 4) | nibble
	}
	return v, true
}

// build_coinbase splices coinb1 || extranonce1 || extranonce2 || coinb2 into a
// caller-provided buffer (invariant #3: the caller owns the allocation). Returns
// the filled subslice.
build_coinbase :: proc(coinb1, en1, en2, coinb2: []u8, buf: []u8) -> []u8 {
	n := 0
	n += copy(buf[n:], coinb1)
	n += copy(buf[n:], en1)
	n += copy(buf[n:], en2)
	n += copy(buf[n:], coinb2)
	return buf[:n]
}

// merkle_root folds the coinbase and the notify merkle_branch into the root, in
// internal order. The running hash is ALWAYS the left input — Stratum branches are
// never sorted (CLAUDE.md § Coinbase and merkle).
merkle_root :: proc(coinbase: []u8, branches: [][32]u8) -> (root: [32]u8) {
	root = sha256d.sum256d(coinbase)
	pair: [64]u8
	for &br in branches {
		copy(pair[0:32], root[:])
		copy(pair[32:64], br[:])
		root = sha256d.sum256d(pair[:])
	}
	return
}

// Job — one unit of published work, everything a Menja thread needs to build its own
// header for its own extranonce2 stream. A value type with inline storage so it can
// be copied into a ring slot with no allocation (invariant #3).
//
// PROVISIONAL: field set and buffer sizes are derived from CLAUDE.md § mining.notify
// and will be confirmed against a real pool session before first connect. The lock-
// free publication mechanism (ring.odin) does not depend on this shape.
MAX_COINB1 :: 1024
MAX_COINB2 :: 1024
MAX_BRANCHES :: 20
MAX_EN1 :: 8
MAX_JOB_ID :: 32

Job :: struct {
	id:         [MAX_JOB_ID]u8, // job_id (opaque string from notify)
	id_len:     int,
	version:    u32,
	prev:       [32]u8, // internal order (word-swap + reverse already applied)
	ntime:      u32,
	nbits:      u32,
	coinb1:     [MAX_COINB1]u8,
	coinb1_len: int,
	coinb2:     [MAX_COINB2]u8,
	coinb2_len: int,
	en1:        [MAX_EN1]u8, // extranonce1 from subscribe
	en1_len:    int,
	en2_size:   int, // extranonce2 width the pool expects
	branches:   [MAX_BRANCHES][32]u8, // merkle branch, internal order
	n_branches: int,
	target:     [32]u8, // share target, from set_difficulty
	net_target: [32]u8, // network target, from nbits — a hit below this is a BLOCK
	clean:      bool,
}

// job_id returns the job's identifier as a string view into its inline buffer.
job_id :: proc(job: ^Job) -> string {
	return string(job.id[:job.id_len])
}

// job_build_header assembles the 80-byte header for this job and a chosen
// extranonce2: splice the coinbase, fold the merkle root, lay out the header (nonce
// zero — the stone fills it). coinbase_buf is caller-owned scratch (invariant #3).
job_build_header :: proc(job: ^Job, en2: []u8, coinbase_buf: []u8) -> Header {
	cb := build_coinbase(
		job.coinb1[:job.coinb1_len],
		job.en1[:job.en1_len],
		en2,
		job.coinb2[:job.coinb2_len],
		coinbase_buf,
	)
	root := merkle_root(cb, job.branches[:job.n_branches])
	return serialize_header(job.version, job.prev, root, job.ntime, job.nbits, 0)
}
