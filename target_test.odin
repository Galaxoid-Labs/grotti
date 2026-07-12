package grotti

import "core:testing"

// be_less reports a < b for two big-endian 256-bit integers.
@(private = "file")
be_less :: proc(a, b: [32]u8) -> bool {
	for i in 0 ..< 32 {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// --- difficulty -> target ---------------------------------------------------

// The anchor: difficulty 1.0 must reproduce the diff1 constant exactly. This is
// independent of the bignum shift path (it exercises decompose + divide).
@(test)
test_target_diff1_identity :: proc(t: ^testing.T) {
	testing.expect_value(t, target_from_difficulty(1.0), DIFF1)
}

// Exact value for difficulty 2.0: diff1 / 2 = 0x000000007FFF8000...0. Hardcoded
// independently of our arithmetic so it cross-checks the divide path.
@(test)
test_target_diff_two_exact :: proc(t: ^testing.T) {
	want := [32]u8 {
		0x00, 0x00, 0x00, 0x00, 0x7F, 0xFF, 0x80, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	}
	testing.expect_value(t, target_from_difficulty(2.0), want)
	// And target(2.0) * 2 == diff1, via the (independent) shift path.
	doubled := bn_to_be(bn_shl(be_to_bn(target_from_difficulty(2.0)), 1))
	testing.expect_value(t, doubled, DIFF1)
}

// Fractional difficulty (< 1) must yield a target LARGER than diff1 — the case the
// naive integer-truncation implementation gets catastrophically wrong.
@(test)
test_target_fractional :: proc(t: ^testing.T) {
	t_0001 := target_from_difficulty(0.001)
	t_00001 := target_from_difficulty(0.0001)
	testing.expect(t, be_less(DIFF1, t_0001), "target(0.001) should exceed diff1")
	testing.expect(t, be_less(t_0001, t_00001), "smaller difficulty => larger target")
}

// Monotonic decreasing in difficulty, across and through 1.0.
@(test)
test_target_monotonic :: proc(t: ^testing.T) {
	diffs := []f64{0.0001, 0.001, 0.5, 1.0, 2.0, 4.0, 1000.0}
	for i in 1 ..< len(diffs) {
		hi := target_from_difficulty(diffs[i - 1]) // larger target
		lo := target_from_difficulty(diffs[i]) // smaller target
		testing.expectf(t, be_less(lo, hi), "target(%v) should be < target(%v)", diffs[i], diffs[i - 1])
	}
}

// --- nbits -> difficulty ----------------------------------------------------

@(test)
test_difficulty_from_nbits :: proc(t: ^testing.T) {
	// difficulty-1 compact
	testing.expect(t, difficulty_from_nbits(0x1d00ffff) == 1.0, "0x1d00ffff is difficulty 1")
	// block 125552: difficulty ~244,112
	d := difficulty_from_nbits(0x1a44b9f2)
	testing.expect(t, d > 243_000 && d < 245_000, "125552 difficulty ~244k")
	// live drivechain wire (2026-07-12): ~133,000
	dl := difficulty_from_nbits(0x1a7e2500)
	testing.expect(t, dl > 131_000 && dl < 135_000, "live difficulty ~133k")
}

// --- compact bits -> target -------------------------------------------------

// Real fixture: mainnet block 125552, nbits 0x1a44b9f2 (difficulty ~244,112).
// target = 0x00000000000044B9F2000000000000000000000000000000000000000000000000 >> ...
// = mantissa 0x44b9f2 * 256^(0x1a-3): 6 leading zero bytes, then 44 B9 F2, then 23 zeros.
@(test)
test_compact_block_125552 :: proc(t: ^testing.T) {
	want := [32]u8 {
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x44, 0xB9,
		0xF2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	}
	got, overflow := target_from_compact(0x1a44b9f2)
	testing.expect(t, !overflow, "125552 nbits should not overflow")
	testing.expect_value(t, got, want)
}

// Real fixture: the regtest pow limit, nbits 0x207fffff.
// target = 0x7FFFFF0000...0 (mantissa 0x7fffff, then 29 zero bytes).
@(test)
test_compact_regtest_limit :: proc(t: ^testing.T) {
	want := [32]u8 {
		0x7F, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	}
	got, overflow := target_from_compact(0x207fffff)
	testing.expect(t, !overflow, "regtest limit should not overflow")
	testing.expect_value(t, got, want)
}

// A compact value whose exponent pushes past 256 bits must flag overflow.
@(test)
test_compact_overflow :: proc(t: ^testing.T) {
	_, overflow := target_from_compact(0x25000001) // 1 * 256^(0x25-3) = 2^272
	testing.expect(t, overflow, "exponent past 256 bits should overflow")
}

// --- comparison -------------------------------------------------------------

@(test)
test_hash_meets_target :: proc(t: ^testing.T) {
	zero: [32]u8
	testing.expect(t, hash_meets_target(zero, DIFF1), "zero hash meets any nonzero target")
	testing.expect(t, !hash_meets_target(DIFF1, DIFF1), "equal is a reject")

	tgt: [32]u8
	tgt[31] = 0x02
	below := tgt; below[31] = 0x01
	above := tgt; above[31] = 0x03
	testing.expect(t, hash_meets_target(below, tgt), "strictly below meets")
	testing.expect(t, !hash_meets_target(above, tgt), "above does not meet")

	// A difference in a high byte dominates low bytes.
	hi: [32]u8; hi[0] = 0x01
	lo: [32]u8; lo[0] = 0x00; lo[31] = 0xFF
	testing.expect(t, hash_meets_target(lo, hi), "high byte dominates comparison")
}
