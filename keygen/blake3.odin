package keygen

// BLAKE3 — restricted to the single case Thunder's address needs: hash one input of
// <= 64 bytes (the 32-byte ed25519 pubkey) and take the first 20 output bytes. That
// is exactly ONE chunk of ONE block that is also the root, so it's a single
// compression with flags CHUNK_START|CHUNK_END|ROOT — no chunk tree, no XOF loop.
// core:crypto has blake2 but not blake3, so it's implemented here (pure Odin) and
// validated against a known vector in keygen_test.

import "core:encoding/endian"
import "core:math/bits"

@(private)
BLAKE3_IV := [8]u32 {
	0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
	0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
}

@(private)
CHUNK_START :: u32(1 << 0)
@(private)
CHUNK_END :: u32(1 << 1)
@(private)
ROOT :: u32(1 << 3)

@(private)
MSG_PERMUTATION := [16]int{2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8}

@(private)
g :: #force_inline proc(v: ^[16]u32, a, b, c, d: int, mx, my: u32) {
	v[a] = v[a] + v[b] + mx
	v[d] = bits.rotate_left32(v[d] ~ v[a], -16)
	v[c] = v[c] + v[d]
	v[b] = bits.rotate_left32(v[b] ~ v[c], -12)
	v[a] = v[a] + v[b] + my
	v[d] = bits.rotate_left32(v[d] ~ v[a], -8)
	v[c] = v[c] + v[d]
	v[b] = bits.rotate_left32(v[b] ~ v[c], -7)
}

@(private)
blake3_round :: proc(v: ^[16]u32, m: [16]u32) {
	g(v, 0, 4, 8, 12, m[0], m[1]) // columns
	g(v, 1, 5, 9, 13, m[2], m[3])
	g(v, 2, 6, 10, 14, m[4], m[5])
	g(v, 3, 7, 11, 15, m[6], m[7])
	g(v, 0, 5, 10, 15, m[8], m[9]) // diagonals
	g(v, 1, 6, 11, 12, m[10], m[11])
	g(v, 2, 7, 8, 13, m[12], m[13])
	g(v, 3, 4, 9, 14, m[14], m[15])
}

// blake3_20 hashes an input of at most 64 bytes and returns the first 20 output
// bytes — the Thunder address hash (base58 of this over the ed25519 pubkey).
blake3_20 :: proc(input: []u8) -> (out: [20]u8) {
	assert(len(input) <= 64, "blake3_20: single-block only")

	block: [64]u8
	copy(block[:], input)
	m: [16]u32
	for i in 0 ..< 16 {
		m[i] = endian.unchecked_get_u32le(block[i * 4:])
	}

	v: [16]u32 = {
		BLAKE3_IV[0], BLAKE3_IV[1], BLAKE3_IV[2], BLAKE3_IV[3],
		BLAKE3_IV[4], BLAKE3_IV[5], BLAKE3_IV[6], BLAKE3_IV[7],
		BLAKE3_IV[0], BLAKE3_IV[1], BLAKE3_IV[2], BLAKE3_IV[3],
		0, // counter low  (chunk 0)
		0, // counter high
		u32(len(input)), // block length
		CHUNK_START | CHUNK_END | ROOT, // single root block
	}

	mp := m
	for r in 0 ..< 7 {
		blake3_round(&v, mp)
		if r < 6 {
			np: [16]u32
			for i in 0 ..< 16 {
				np[i] = mp[MSG_PERMUTATION[i]]
			}
			mp = np
		}
	}

	// XOF/output: word i (i<8) = v[i] ^ v[i+8]. First 20 bytes = words 0..4.
	for i in 0 ..< 5 {
		endian.unchecked_put_u32le(out[i * 4:], v[i] ~ v[i + 8])
	}
	return
}
