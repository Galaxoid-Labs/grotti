package sha256d

// Differential correctness (CLAUDE.md invariant #4, DEVELOPMENT.md § Test plan #1):
// our hasher is validated against core:crypto/sha2 on randomized input, in a loop —
// not spot-checked. core is imported HERE ONLY, never by the hasher itself.

import "core:crypto"
import "core:crypto/sha2"
import "core:testing"

// oracle_sum256 is the reference: a single SHA-256 via the standard library.
@(private = "file")
oracle_sum256 :: proc(data: []u8) -> (out: [32]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, out[:])
	return
}

// A few burned-in known-answer vectors catch gross errors before the fuzz loop.
@(test)
test_sum256_known_answers :: proc(t: ^testing.T) {
	// SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
	empty := sum256({})
	testing.expect_value(t, empty[0], 0xe3)
	testing.expect_value(t, empty[31], 0x55)

	// SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
	abc := sum256({'a', 'b', 'c'})
	testing.expect_value(t, abc[0], 0xba)
	testing.expect_value(t, abc[31], 0xad)
}

// The main gate: 100k random 80-byte (header-sized) inputs, ours == core.
@(test)
test_sum256_matches_oracle_header :: proc(t: ^testing.T) {
	buf: [80]u8
	for _ in 0 ..< 100_000 {
		crypto.rand_bytes(buf[:])
		testing.expect_value(t, sum256(buf[:]), oracle_sum256(buf[:]))
	}
}

// Sweep every length across the padding-block boundaries (55/56/64/119/120), where
// naive padding logic breaks. Random content at each length.
@(test)
test_sum256_matches_oracle_all_lengths :: proc(t: ^testing.T) {
	buf: [200]u8
	for n in 0 ..= 200 {
		for _ in 0 ..< 50 {
			crypto.rand_bytes(buf[:n])
			testing.expect_value(t, sum256(buf[:n]), oracle_sum256(buf[:n]))
		}
	}
}

// sha256d == core-over-core, on random header-sized input.
@(test)
test_sum256d_matches_oracle :: proc(t: ^testing.T) {
	buf: [80]u8
	for _ in 0 ..< 50_000 {
		crypto.rand_bytes(buf[:])
		first := oracle_sum256(buf[:])
		want := oracle_sum256(first[:])
		testing.expect_value(t, sum256d(buf[:]), want)
	}
}
