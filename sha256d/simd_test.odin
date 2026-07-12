package sha256d

import "core:crypto"
import "core:encoding/endian"
import "core:simd"
import "core:testing"

// Build the message-word inputs for sum256d_8x from a full 80-byte header, mirroring
// how SHA reads block B big-endian.
@(private = "file")
words_of :: proc(header: []u8) -> (mid: Midstate, w0, w1, w2, w3: u32) {
	mid = midstate(header[0:64])
	w0 = endian.unchecked_get_u32be(header[64:68])
	w1 = endian.unchecked_get_u32be(header[68:72])
	w2 = endian.unchecked_get_u32be(header[72:76])
	w3 = endian.unchecked_get_u32be(header[76:80])
	return
}

// Stage 3 must be bit-identical to stage 1, on random inputs, in a loop — a SIMD
// hasher that is fast and wrong is worse than useless (DEVELOPMENT.md § Stage 3).
// Here all 8 lanes share the same nonce word, so every lane's digest must equal the
// scalar sum256d of the same header.
@(test)
test_simd_matches_scalar_broadcast :: proc(t: ^testing.T) {
	buf: [80]u8
	for _ in 0 ..< 50_000 {
		crypto.rand_bytes(buf[:])
		mid, w0, w1, w2, w3 := words_of(buf[:])
		out := sum256d_8x(mid, w0, w1, w2, Lane(w3))
		want := sum256d(buf[:])
		for lane in 0 ..< LANES {
			testing.expect_value(t, digest_of_lane(out, lane), want)
		}
	}
}

// Distinct nonce word per lane: each lane must match the scalar hash of the header
// carrying that lane's nonce word. This is the real hot-loop shape — 8 different
// nonces in flight.
@(test)
test_simd_matches_scalar_distinct_lanes :: proc(t: ^testing.T) {
	buf: [80]u8
	for _ in 0 ..< 20_000 {
		crypto.rand_bytes(buf[:])
		mid, w0, w1, w2, _ := words_of(buf[:])

		base := endian.unchecked_get_u32be(buf[76:80])
		lanes: [LANES]u32
		for j in 0 ..< LANES {
			lanes[j] = base + u32(j) * 0x9E3779B1 // spread the lanes apart
		}
		w3 := simd.from_array(lanes)
		out := sum256d_8x(mid, w0, w1, w2, w3)

		for j in 0 ..< LANES {
			endian.unchecked_put_u32be(buf[76:80], lanes[j]) // header word = big-endian of w3
			testing.expect_value(t, digest_of_lane(out, j), sum256d(buf[:]))
		}
	}
}

// The early-exit word is genuinely word 7 of each lane's digest.
@(test)
test_simd_early_exit_word :: proc(t: ^testing.T) {
	buf: [80]u8
	crypto.rand_bytes(buf[:])
	mid, w0, w1, w2, w3 := words_of(buf[:])
	out := sum256d_8x(mid, w0, w1, w2, Lane(w3))
	ee := early_exit_word(out)
	want := sum256d(buf[:])
	want_word := endian.unchecked_get_u32be(want[28:32])
	for lane in 0 ..< LANES {
		testing.expect_value(t, ee[lane], want_word)
	}
}
