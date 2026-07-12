package sha256d

import "core:crypto"
import "core:testing"

// Stage 2 must be bit-identical to stage 1 (DEVELOPMENT.md § Test plan). 100k random
// 80-byte headers: the midstate path reproduces the straight sum256d exactly.
@(test)
test_midstate_matches_sum256d :: proc(t: ^testing.T) {
	buf: [80]u8
	for _ in 0 ..< 100_000 {
		crypto.rand_bytes(buf[:])
		mid := midstate(buf[0:64])
		got := sum256d_from_midstate(mid, buf[64:80])
		testing.expect_value(t, got, sum256d(buf[:]))
	}
}

// The midstate is genuinely reused across nonces: one midstate, many differing tails,
// each still matching the full hash. (Mutating only the nonce bytes is the hot-loop
// access pattern.)
@(test)
test_midstate_reused_across_nonces :: proc(t: ^testing.T) {
	buf: [80]u8
	crypto.rand_bytes(buf[:])
	mid := midstate(buf[0:64])

	for nonce in u32(0) ..< 4096 {
		buf[76] = u8(nonce)
		buf[77] = u8(nonce >> 8)
		buf[78] = u8(nonce >> 16)
		buf[79] = u8(nonce >> 24)
		got := sum256d_from_midstate(mid, buf[64:80])
		testing.expect_value(t, got, sum256d(buf[:]))
	}
}
