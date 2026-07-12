package sha256d

// Stage 3: SIMD. SHA-256 over independent nonces has no cross-nonce data
// dependency, so 8 nonces run at once in #simd[8]u32 lanes. Every ROTR/XOR/ADD/Ch/Maj
// is lane-wise — a mechanical transliteration of the scalar compress. This is where
// "fast" comes from (DEVELOPMENT.md § Stage 3).
//
// This operates in MESSAGE-WORD space: the caller passes the block-B words SHA
// actually sees (w0,w1,w2 constant, w3 the per-lane nonce word). The nonce
// little-endian/​big-endian swap lives at the scan layer, not here, so this file is
// pure SHA. Validated lane-for-lane against the scalar path in simd_test.odin.

import "core:encoding/endian"
import "core:simd"

LANES :: 8
Lane :: #simd[8]u32

@(private)
ror :: #force_inline proc "contextless" (x: Lane, n: u32) -> Lane {
	return simd.shr(x, Lane(n)) | simd.shl(x, Lane(32 - n))
}

@(private)
lch :: #force_inline proc "contextless" (x, y, z: Lane) -> Lane {
	return (x & y) ~ (simd.bit_not(x) & z)
}

@(private)
lmaj :: #force_inline proc "contextless" (x, y, z: Lane) -> Lane {
	return (x & y) ~ (x & z) ~ (y & z)
}

@(private)
lbig_s0 :: #force_inline proc "contextless" (x: Lane) -> Lane {
	return ror(x, 2) ~ ror(x, 13) ~ ror(x, 22)
}

@(private)
lbig_s1 :: #force_inline proc "contextless" (x: Lane) -> Lane {
	return ror(x, 6) ~ ror(x, 11) ~ ror(x, 25)
}

@(private)
lsmall_s0 :: #force_inline proc "contextless" (x: Lane) -> Lane {
	return ror(x, 7) ~ ror(x, 18) ~ simd.shr(x, Lane(3))
}

@(private)
lsmall_s1 :: #force_inline proc "contextless" (x: Lane) -> Lane {
	return ror(x, 17) ~ ror(x, 19) ~ simd.shr(x, Lane(10))
}

// compress_8x is the lane-wise twin of compress: same rounds, Lane in place of u32.
@(private)
compress_8x :: proc "contextless" (state: ^[8]Lane, w_in: [16]Lane) {
	w: [64]Lane
	#no_bounds_check for i in 0 ..< 16 {
		w[i] = w_in[i]
	}
	#no_bounds_check for i in 16 ..< 64 {
		w[i] = lsmall_s1(w[i - 2]) + w[i - 7] + lsmall_s0(w[i - 15]) + w[i - 16]
	}

	v := state^
	#no_bounds_check for i in 0 ..< 64 {
		t1 := v[7] + lbig_s1(v[4]) + lch(v[4], v[5], v[6]) + Lane(K[i]) + w[i]
		t2 := lbig_s0(v[0]) + lmaj(v[0], v[1], v[2])
		v[7] = v[6]
		v[6] = v[5]
		v[5] = v[4]
		v[4] = v[3] + t1
		v[3] = v[2]
		v[2] = v[1]
		v[1] = v[0]
		v[0] = t1 + t2
	}

	#no_bounds_check for i in 0 ..< 8 {
		state[i] = state[i] + v[i]
	}
}

// sum256d_8x hashes 8 nonces at once. mid is the job's midstate (over header[0:64]);
// w0,w1,w2 are the constant block-B message words (be words of header[64:76]); w3 is
// the per-lane nonce message word. Returns the 8 output words of the second hash,
// each a Lane across the 8 nonces: out[k] holds word k of every lane's digest.
sum256d_8x :: proc "contextless" (mid: Midstate, w0, w1, w2: u32, w3: Lane) -> (out: [8]Lane) {
	// First hash: block B from the midstate. Padding for an 80-byte (640-bit)
	// message: word 4 = 0x80000000, words 5..14 = 0, word 15 = 640.
	wb: [16]Lane
	wb[0] = Lane(w0)
	wb[1] = Lane(w1)
	wb[2] = Lane(w2)
	wb[3] = w3
	wb[4] = Lane(0x8000_0000)
	for i in 5 ..< 15 {
		wb[i] = Lane(0)
	}
	wb[15] = Lane(640)

	s1: [8]Lane
	for i in 0 ..< 8 {
		s1[i] = Lane(mid[i])
	}
	compress_8x(&s1, wb)

	// Second hash: the 32-byte first digest (8 words) + padding for a 256-bit message.
	wc: [16]Lane
	for i in 0 ..< 8 {
		wc[i] = s1[i]
	}
	wc[8] = Lane(0x8000_0000)
	for i in 9 ..< 15 {
		wc[i] = Lane(0)
	}
	wc[15] = Lane(256)

	out = {Lane(IV[0]), Lane(IV[1]), Lane(IV[2]), Lane(IV[3]), Lane(IV[4]), Lane(IV[5]), Lane(IV[6]), Lane(IV[7])}
	compress_8x(&out, wc)
	return
}

// early_exit_word returns the final output word (word 7) of every lane. For any
// non-degenerate target the top word of the reversed hash must be zero, so a lane
// whose word 7 is nonzero cannot be a share — the caller skips it without unpacking
// (DEVELOPMENT.md § Stage 3 early-exit).
early_exit_word :: proc "contextless" (out: [8]Lane) -> [8]u32 {
	return simd.to_array(out[7])
}

// digest_of_lane unpacks one lane's full 32-byte digest (big-endian, internal order)
// from the packed output. Called only for lanes that survive the early-exit test.
digest_of_lane :: proc(out: [8]Lane, lane: int) -> (d: [32]u8) #no_bounds_check {
	for k in 0 ..< 8 {
		word := simd.to_array(out[k])[lane]
		endian.unchecked_put_u32be(d[k * 4:], word)
	}
	return
}
