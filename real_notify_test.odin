package grotti

import "core:testing"

// Fixture from a REAL pool.drivechain.info session (captured 2026-07-12), so the
// byte-order code is validated against the live wire, not an imagined protocol.
@(private = "file")
RN_PREVHASH :: "c6a54c3bae51e5e4bc04197e3a60f30807ac10a7c2f2db6200001d6200000000"
@(private = "file")
RN_COINB1 :: "02000000010000000000000000000000000000000000000000000000000000000000000000ffffffff2402e359182f73696d706c65706f6f6c2d7070732d636c61737369632f"
@(private = "file")
RN_COINB2 :: "ffffffff050000000000000000276a25d16173680967af15bd3341164c3d698783c53de5ca5e3334dcf812ebdc01729c306165a2f700000000000000000f6a0dd77d177601ffffffffffffffff5e050b27010000001600143b5078906424e4f68a2d89af4b8d625754c297928af0fa02000000001600143b5078906424e4f68a2d89af4b8d625754c297920000000000000000266a24aa21a9ed35ce7c3be84450cf7edf502925bb48df5db198bccb668973f32c1735e51b927d00000000"
@(private = "file")
RN_BRANCH0 :: "f5734a50e7482dfe2ca81d962ea93e0b907734ba4c7a1121fa77aecad786c90c"
@(private = "file")
RN_EN1 :: "749b6aeb"
@(private = "file")
RN_VERSION :: "20000000"
@(private = "file")
RN_NBITS :: "1a7e2500"
@(private = "file")
RN_NTIME :: "6a540aa3"

@(private = "file")
nib :: proc(c: u8) -> u8 {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	}
	return 0
}

@(private = "file")
decode_hex :: proc(s: string, buf: []u8) -> []u8 {
	b := transmute([]u8)s
	n := len(b) / 2
	for i in 0 ..< n {
		buf[i] = (nib(b[i * 2]) << 4) | nib(b[i * 2 + 1])
	}
	return buf[:n]
}

// THE live byte-order validation: applying the Stratum prevhash word-swap to real
// data must recover a header prevhash whose DISPLAY form is a genuine block hash —
// i.e. it leads with the zero bytes proof-of-work requires. A wrong word-swap would
// scatter those zeros. At this chain's difficulty the top ~49 bits are zero, so the
// first 6 bytes must be 0x00. This is the #1-bug tripwire, proven on the live wire.
@(test)
test_real_prevhash_word_swap :: proc(t: ^testing.T) {
	stratum := hex32(RN_PREVHASH)
	internal := prevhash_stratum_to_internal(stratum)
	display := reverse32(internal)
	for i in 0 ..< 6 {
		testing.expectf(t, display[i] == 0, "display prevhash byte %d must be zero (got %2x)", i, display[i])
	}
	// The 7th byte is where the hash becomes nonzero.
	testing.expect(t, display[6] != 0 || display[7] != 0, "prevhash is not all zeros")
}

// version / nbits / ntime parse from big-endian hex exactly as sent.
@(test)
test_real_notify_fields :: proc(t: ^testing.T) {
	v, ok1 := parse_u32_be_hex(RN_VERSION)
	testing.expect(t, ok1 && v == 0x2000_0000, "version")
	nb, ok2 := parse_u32_be_hex(RN_NBITS)
	testing.expect(t, ok2 && nb == 0x1a7e_2500, "nbits")
	nt, ok3 := parse_u32_be_hex(RN_NTIME)
	testing.expect(t, ok3 && nt == 0x6a54_0aa3, "ntime")
}

// The live share difficulty is 1024 — an INTEGER >= 1, not the fractional (<1)
// difficulty CLAUDE.md assumed. Its target must therefore be below diff1.
@(test)
test_real_share_difficulty_target :: proc(t: ^testing.T) {
	target := target_from_difficulty(1024)
	testing.expect(t, hash_meets_target(target, DIFF1), "diff-1024 target must be < diff1")
	// And the network nbits target is far smaller still (much higher difficulty).
	net_target, _ := target_from_compact(0x1a7e2500)
	testing.expect(t, hash_meets_target(net_target, target), "network target < share target")
}

// The full construction runs on real coinbase/branch sizes without overflowing the
// buffers, and produces an 80-byte header.
@(test)
test_real_notify_build :: proc(t: ^testing.T) {
	c1: [512]u8
	c2: [512]u8
	e1: [8]u8
	cb: [1200]u8
	coinb1 := decode_hex(RN_COINB1, c1[:])
	coinb2 := decode_hex(RN_COINB2, c2[:])
	en1 := decode_hex(RN_EN1, e1[:])
	en2 := []u8{0x00, 0x00, 0x00, 0x00} // en2_size = 4

	coinbase := build_coinbase(coinb1, en1, en2, coinb2, cb[:])
	testing.expect(t, len(coinbase) == len(coinb1) + len(en1) + 4 + len(coinb2), "coinbase spliced")

	branches := [1][32]u8{hex32(RN_BRANCH0)}
	root := merkle_root(coinbase, branches[:])

	prev := prevhash_stratum_to_internal(hex32(RN_PREVHASH))
	v, _ := parse_u32_be_hex(RN_VERSION)
	nb, _ := parse_u32_be_hex(RN_NBITS)
	nt, _ := parse_u32_be_hex(RN_NTIME)
	h := serialize_header(v, prev, root, nt, nb, 0)
	// Structural: the header carries the parsed fields little-endian.
	testing.expect_value(t, h[0], u8(0x00)) // version 0x20000000 LE -> 00 00 00 20
	testing.expect_value(t, h[3], u8(0x20))
	_ = h
}
