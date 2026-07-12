package grotti

import "core:testing"

// The strongest end-to-end proof available offline: scan for block 125552's ACTUAL
// winning nonce against its REAL network target, and confirm the stone finds it.
// This exercises the whole pipeline — header assembly, sha256d, reverse, target
// compare — on real chain data, the way it will run against the live pool.
@(test)
test_scan_finds_real_block_nonce :: proc(t: ^testing.T) {
	prev := reverse32(hex32(B125552_PREV))
	merkle := reverse32(hex32(B125552_MERKLE))
	h := serialize_header(B125552_VERSION, prev, merkle, B125552_NTIME, B125552_NBITS, 0)
	target, _ := target_from_compact(B125552_NBITS)

	hits: [4]u32
	// Exactly at the winning nonce: one hit.
	n := scan_scalar(&h, target, B125552_NONCE, 1, hits[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, hits[0], B125552_NONCE)

	// One nonce earlier does NOT satisfy the strict network target: zero hits.
	// (Proves the compare is exact, not merely "close".)
	n2 := scan_scalar(&h, target, B125552_NONCE - 1, 1, hits[:])
	testing.expect_value(t, n2, 0)
}

// Multi-hit semantics (the inversion that breaks reference miners): with an easy
// target, a single scan finds MANY shares, and scan_scalar must report every one.
// Here the target requires the top byte of the big-endian hash to be zero (~1/256),
// so ~256 hits are expected over 65536 nonces. Every reported hit is independently
// re-verified against the target.
@(test)
test_scan_multi_hit :: proc(t: ^testing.T) {
	prev := reverse32(hex32(B125552_PREV))
	merkle := reverse32(hex32(B125552_MERKLE))
	h := serialize_header(B125552_VERSION, prev, merkle, B125552_NTIME, B125552_NBITS, 0)

	// target = 0x00FFFF...FF : first byte must be 0.
	target: [32]u8
	target[0] = 0x00
	for i in 1 ..< 32 {
		target[i] = 0xFF
	}

	hits: [1024]u32
	n := scan_scalar(&h, target, 0, 65536, hits[:])
	testing.expect(t, n > 0, "an easy target must yield hits")

	// Re-verify each recorded hit independently: build its header, hash, compare.
	for i in 0 ..< min(n, len(hits)) {
		hh := serialize_header(B125552_VERSION, prev, merkle, B125552_NTIME, B125552_NBITS, hits[i])
		testing.expect(t, hash_meets_target(block_hash(hh), target), "every reported hit meets the target")
	}
}

// The fast path must find exactly the same shares as the scalar path over the same
// nonce range — the whole point of the differential discipline.
@(test)
test_scan_simd_matches_scalar :: proc(t: ^testing.T) {
	prev := reverse32(hex32(B125552_PREV))
	merkle := reverse32(hex32(B125552_MERKLE))
	h := serialize_header(B125552_VERSION, prev, merkle, B125552_NTIME, B125552_NBITS, 0)

	target: [32]u8
	for i in 1 ..< 32 {
		target[i] = 0xFF // first byte must be 0 (~1/256)
	}

	scalar_hits: [1024]u32
	simd_hits: [1024]u32
	ns := scan_scalar(&h, target, 0, 65536, scalar_hits[:])
	nv := scan_simd(&h, target, 0, 65536, simd_hits[:])

	testing.expect_value(t, nv, ns)
	testing.expect(t, ns > 0, "expected some hits")
	for i in 0 ..< min(ns, len(scalar_hits)) {
		testing.expect_value(t, simd_hits[i], scalar_hits[i])
	}
}

// And the fast path finds block 125552's real winning nonce at network difficulty.
@(test)
test_scan_simd_finds_real_block_nonce :: proc(t: ^testing.T) {
	prev := reverse32(hex32(B125552_PREV))
	merkle := reverse32(hex32(B125552_MERKLE))
	h := serialize_header(B125552_VERSION, prev, merkle, B125552_NTIME, B125552_NBITS, 0)
	target, _ := target_from_compact(B125552_NBITS)

	// 8-aligned window containing 0x9546A142.
	base := B125552_NONCE & ~u32(7)
	hits: [8]u32
	n := scan_simd(&h, target, base, 8, hits[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, hits[0], B125552_NONCE)
}
