package grotti

// Menja — the CPU backend's hasher. The stone is its inner nonce loop.
//
// Stage 1: scalar, obviously correct (DEVELOPMENT.md § The hasher). No midstate, no
// early exit, no SIMD — those are Phase 5, each landing only once it is proven
// bit-identical to this. This is already ~5x the whole network on one thread, so it
// is a shippable miner; the optimizations are for the engine's sake, not the chain's.
//
// The loop obeys invariant #3: it allocates nothing, locks nothing, and syscalls
// nothing. The header buffer is owned by the caller (per-thread, preallocated); the
// loop mutates only its nonce field in place.

import "core:encoding/endian"
import "core:simd"
import "sha256d"

// bswap_lane byte-reverses each lane. The header stores the nonce little-endian, but
// SHA reads block B big-endian, so the message word SHA sees is byteswap(nonce). The
// stone iterates header nonces; this converts a lane of header nonces into the nonce
// message words sum256d_8x expects. Keeping the swap here (not in sha256d) leaves the
// hasher pure.
@(private)
bswap_lane :: proc "contextless" (x: sha256d.Lane) -> sha256d.Lane {
	L :: sha256d.Lane
	return(
		simd.shl(x & L(0x0000_00FF), L(24)) |
		simd.shl(x & L(0x0000_FF00), L(8)) |
		simd.shr(x & L(0x00FF_0000), L(8)) |
		simd.shr(x & L(0xFF00_0000), L(24)) \
	)
}

// is_block_nonce reports whether the header at `nonce` clears the NETWORK target —
// i.e. this share is actually a block. Cheap and called only on the rare hit.
is_block_nonce :: proc(header: Header, nonce: u32, net_target: [32]u8) -> bool {
	h := header
	endian.unchecked_put_u32le(h[76:80], nonce)
	return hash_meets_target(block_hash(h), net_target)
}

// scan_scalar sweeps `count` nonces starting at `start`, writing every nonce whose
// header hashes below `target` into `hits`. It returns the TOTAL number of hits —
// which may exceed len(hits): on this chain a single scan routinely finds several
// shares (DEVELOPMENT.md § v2), so a caller that only reads hits[:min(n,len)] must
// size the buffer for the expected yield. A return > len(hits) signals lost hits.
//
// header is the thread's own 80-byte buffer; only bytes [76:80] (the nonce) are
// written. The nonce counter wraps naturally at 2^32.
scan_scalar :: proc(header: ^Header, target: [32]u8, start: u32, count: u32, hits: []u32) -> (n: int) {
	nonce := start
	for _ in 0 ..< count {
		endian.unchecked_put_u32le(header[76:80], nonce)
		hash_be := reverse32(sha256d.sum256d(header[:]))
		if hash_meets_target(hash_be, target) {
			if n < len(hits) {
				hits[n] = nonce
			}
			n += 1
		}
		nonce += 1
	}
	return
}

// scan_simd is the stage-3 stone: 8 nonces per step via #simd lanes, with the
// early-exit skip. `count` must be a multiple of LANES and the range must not wrap
// 2^32 (the caller's per-thread partition guarantees both). Identical hits to
// scan_scalar over the same range — proven in menja_test.
scan_simd :: proc(header: ^Header, target: [32]u8, start: u32, count: u32, hits: []u32) -> (n: int) {
	// Constant job inputs, computed once: the midstate over header[0:64] and the
	// three constant block-B message words (header[64:76], read big-endian).
	mid := sha256d.midstate(header[0:64])
	w0 := endian.unchecked_get_u32be(header[64:68])
	w1 := endian.unchecked_get_u32be(header[68:72])
	w2 := endian.unchecked_get_u32be(header[72:76])

	// Early-exit threshold: the target's leading big-endian word. A lane whose hash
	// leads with a larger word cannot be below target and is skipped without
	// unpacking. NOTE: this is a target-relative compare, NOT "== 0" — on this chain
	// difficulty < 1 makes the target's top word NONZERO, and the zero-shortcut would
	// silently discard valid shares.
	tgt := target // shadow: params are not addressable, can't slice directly
	target_top := endian.unchecked_get_u32be(tgt[0:4])

	offsets := simd.from_array([8]u32{0, 1, 2, 3, 4, 5, 6, 7})
	batches := count / sha256d.LANES
	base := start
	for _ in 0 ..< batches {
		w3 := bswap_lane(sha256d.Lane(base) + offsets)
		out := sha256d.sum256d_8x(mid, w0, w1, w2, w3)
		// out[7] is s2[7]; the hash's leading big-endian word is byteswap(s2[7]).
		tops := simd.to_array(bswap_lane(out[7]))
		for j in 0 ..< sha256d.LANES {
			if tops[j] > target_top {
				continue
			}
			if hash_meets_target(reverse32(sha256d.digest_of_lane(out, j)), target) {
				if n < len(hits) {
					hits[n] = base + u32(j)
				}
				n += 1
			}
		}
		base += sha256d.LANES
	}
	return
}
