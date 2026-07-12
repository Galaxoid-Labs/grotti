package sha256d

// Stage 2: midstate. The 80-byte header splits across SHA-256's 64-byte blocks as
// block A = header[0:64] and block B = header[64:80] + padding. The nonce lives at
// header[76:80] — entirely inside block B — so block A is CONSTANT for a whole job.
//
// Compute compress(IV, blockA) once per job (the midstate); per nonce only block B
// and the second hash remain. Three compressions per nonce become two. This is
// nearly free in Odin because the state is a value type — no context surgery.
//
// Validated bit-for-bit against sum256d (stage 1, itself validated against
// core:crypto/sha2) in midstate_test.odin.

import "core:encoding/endian"

Midstate :: [8]u32

// midstate folds the constant first 64 bytes of a header into reusable state.
// Call once per job with header[0:64].
midstate :: proc(head64: []u8) -> (mid: Midstate) {
	mid = IV
	compress(&mid, head64)
	return
}

// sum256d_from_midstate finishes the sha256d given the precomputed midstate and the
// final 16 header bytes (header[64:80], nonce included). Equivalent to
// sum256d(full_header) but skips re-hashing the constant first block.
sum256d_from_midstate :: proc(mid: Midstate, tail16: []u8) -> (digest: [32]u8) #no_bounds_check {
	// First hash: continue from the midstate over block B.
	// Block B = header[64:80] || 0x80 || zeros || u64be(640) — the message is 80
	// bytes = 640 bits, and 16 + 1 + 8 <= 64 so it fits one block.
	s := mid
	block: [64]u8
	copy(block[0:16], tail16)
	block[16] = 0x80
	endian.unchecked_put_u64be(block[56:64], 640)
	compress(&s, block[:])

	d1: [32]u8
	for k in 0 ..< 8 {
		endian.unchecked_put_u32be(d1[k * 4:], s[k])
	}

	// Second hash: sha256(d1). Input is a fixed 32-byte digest -> one padded block.
	s2 := IV
	block = {}
	copy(block[0:32], d1[:])
	block[32] = 0x80
	endian.unchecked_put_u64be(block[56:64], 256) // 32 bytes = 256 bits
	compress(&s2, block[:])

	for k in 0 ..< 8 {
		endian.unchecked_put_u32be(digest[k * 4:], s2[k])
	}
	return
}
