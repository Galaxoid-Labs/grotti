package sha256d

// The optimized CPU hasher, ISOLATED from consensus code (CLAUDE.md invariant #1).
//
// This is Grotti's own SHA-256, not core:crypto/sha2. It exists so we can own the
// midstate (stage 2) and SIMD (stage 3) paths the hot loop needs. core:crypto/sha2
// is the differential ORACLE only (see sha256d_test.odin) — never imported here,
// never in the hot loop.
//
// Stage 1: a plain scalar transform, obviously correct, mirroring the structure of
// core's generic transform so stage 3 can transliterate it lane-for-lane. The K
// table and IV below are the standard SHA-256 constants; any transcription error is
// caught immediately by the randomized differential test, which is the point.

import "core:encoding/endian"
import "core:math/bits"

// Initial hash value: fractional parts of the square roots of the first 8 primes.
@(private)
IV := [8]u32{
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

// Round constants: fractional parts of the cube roots of the first 64 primes.
@(private)
K := [64]u32{
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

@(private)
ch :: #force_inline proc "contextless" (x, y, z: u32) -> u32 {
	return (x & y) ~ (~x & z)
}

@(private)
maj :: #force_inline proc "contextless" (x, y, z: u32) -> u32 {
	return (x & y) ~ (x & z) ~ (y & z)
}

// Upper-case sigma0 (applied to a in the round).
@(private)
big_s0 :: #force_inline proc "contextless" (x: u32) -> u32 {
	return bits.rotate_left32(x, 30) ~ bits.rotate_left32(x, 19) ~ bits.rotate_left32(x, 10)
}

// Upper-case sigma1 (applied to e in the round).
@(private)
big_s1 :: #force_inline proc "contextless" (x: u32) -> u32 {
	return bits.rotate_left32(x, 26) ~ bits.rotate_left32(x, 21) ~ bits.rotate_left32(x, 7)
}

// Lower-case sigma0 (message schedule, on w[i-15]).
@(private)
small_s0 :: #force_inline proc "contextless" (x: u32) -> u32 {
	return bits.rotate_left32(x, 25) ~ bits.rotate_left32(x, 14) ~ (x >> 3)
}

// Lower-case sigma1 (message schedule, on w[i-2]).
@(private)
small_s1 :: #force_inline proc "contextless" (x: u32) -> u32 {
	return bits.rotate_left32(x, 15) ~ bits.rotate_left32(x, 13) ~ (x >> 10)
}

// compress folds one 64-byte block into state. u32 addition wraps (Odin unsigned
// overflow is defined), which is exactly what SHA-256 requires.
@(private)
compress :: proc "contextless" (state: ^[8]u32, block: []u8) #no_bounds_check {
	w: [64]u32
	for i in 0 ..< 16 {
		w[i] = endian.unchecked_get_u32be(block[i * 4:])
	}
	for i in 16 ..< 64 {
		w[i] = small_s1(w[i - 2]) + w[i - 7] + small_s0(w[i - 15]) + w[i - 16]
	}

	v := state^ // value copy: {a,b,c,d,e,f,g,h}
	for i in 0 ..< 64 {
		t1 := v[7] + big_s1(v[4]) + ch(v[4], v[5], v[6]) + K[i] + w[i]
		t2 := big_s0(v[0]) + maj(v[0], v[1], v[2])
		v[7] = v[6]
		v[6] = v[5]
		v[5] = v[4]
		v[4] = v[3] + t1
		v[3] = v[2]
		v[2] = v[1]
		v[1] = v[0]
		v[0] = t1 + t2
	}

	for i in 0 ..< 8 {
		state[i] += v[i]
	}
}

// sum256 is a one-shot SHA-256 over data of any length. Allocation-free: full
// blocks are consumed in place, and the final partial block plus padding lands in
// a stack buffer (padding spills into at most one extra block).
sum256 :: proc(data: []u8) -> (digest: [32]u8) #no_bounds_check {
	state := IV

	full := len(data) &~ 63 // bytes covered by whole blocks
	i := 0
	for i < full {
		compress(&state, data[i:i + 64])
		i += 64
	}

	tail: [128]u8 // zero-initialized
	rem := len(data) - full
	copy(tail[:], data[full:])
	tail[rem] = 0x80

	// If the 0x80 leaves <8 bytes of room, the length spills into a second block.
	n_blocks := 1 if rem < 56 else 2
	total := n_blocks * 64
	endian.unchecked_put_u64be(tail[total - 8:], u64(len(data)) * 8)

	for b := 0; b < n_blocks; b += 1 {
		compress(&state, tail[b * 64:b * 64 + 64])
	}

	for k in 0 ..< 8 {
		endian.unchecked_put_u32be(digest[k * 4:], state[k])
	}
	return
}

// sum256d is SHA-256(SHA-256(data)) — Bitcoin's "sha256d". This is the operation
// the miner performs over the 80-byte header; the target check compares against
// its (reversed) output. See CLAUDE.md § Target check.
sum256d :: proc(data: []u8) -> [32]u8 {
	first := sum256(data)
	return sum256(first[:])
}
