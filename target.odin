package grotti

import "core:math"

// Difficulty <-> 256-bit target, fractional-safe. See CLAUDE.md § Target check.
//
// The whole point of this file is invariant #4's warning: this chain sends
// difficulty < 1 (vardiff is clamped below network difficulty ~0.56), so
// `target = diff1 / difficulty` produces a target LARGER than diff1, and the
// naive `diff1 / u64(difficulty)` truncates a fractional difficulty to 0 and
// divides by zero. We never convert difficulty to an integer.
//
// Instead: decompose the f64 difficulty into an exact `mant * 2^e` (53-bit integer
// mantissa from the IEEE-754 bits), then compute diff1 / (mant * 2^e) entirely in
// big-integer arithmetic. No floating-point division anywhere.

// DIFF1 is the difficulty-1 target: 0xFFFF * 2^208, big-endian.
// 0x00000000FFFF0000000000000000000000000000000000000000000000000000
@(rodata)
DIFF1 := [32]u8 {
	0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
}

// ---------------------------------------------------------------------------
// Minimal fixed-width big integer. 512 bits, little-endian limbs
// (value = sum limb[i] << 64*i). 512 bits is comfortable headroom: diff1 (~2^224)
// shifted left far enough to represent the smallest difficulty this chain could
// plausibly send stays well under 2^512, and results above 2^256 are clamped.
// ---------------------------------------------------------------------------

@(private)
BN_LIMBS :: 8

@(private)
Bn :: [BN_LIMBS]u64

@(private)
DIFF1_BN :: Bn{0, 0, 0, 0x0000_0000_FFFF_0000, 0, 0, 0, 0}

@(private)
bn_shl :: proc(a: Bn, n: uint) -> (r: Bn) {
	ls := int(n / 64)
	bs := n % 64
	for i in 0 ..< BN_LIMBS {
		acc: u64
		j := i - ls
		if j >= 0 && j < BN_LIMBS {
			acc = a[j] << bs
		}
		if bs != 0 {
			j2 := i - ls - 1
			if j2 >= 0 && j2 < BN_LIMBS {
				acc |= a[j2] >> (64 - bs)
			}
		}
		r[i] = acc
	}
	return
}

@(private)
bn_shr :: proc(a: Bn, n: uint) -> (r: Bn) {
	ls := int(n / 64)
	bs := n % 64
	for i in 0 ..< BN_LIMBS {
		acc: u64
		j := i + ls
		if j >= 0 && j < BN_LIMBS {
			acc = a[j] >> bs
		}
		if bs != 0 {
			j2 := i + ls + 1
			if j2 >= 0 && j2 < BN_LIMBS {
				acc |= a[j2] << (64 - bs)
			}
		}
		r[i] = acc
	}
	return
}

// bn_divmod_u64 divides by any u64 >= 1. The running remainder invariant (rem < d)
// bounds each accumulator below d*2^64, so every quotient limb fits a u64 — the
// u128 intermediate never needs to be wider.
@(private)
bn_divmod_u64 :: proc(a: Bn, d: u64) -> (q: Bn, rem: u64) {
	for i := BN_LIMBS - 1; i >= 0; i -= 1 {
		acc := (u128(rem) << 64) | u128(a[i])
		q[i] = u64(acc / u128(d))
		rem = u64(acc % u128(d))
	}
	return
}

// bn_to_be serializes the low 256 bits (limbs 0..3) as a big-endian [32]u8.
@(private)
bn_to_be :: proc(b: Bn) -> (out: [32]u8) {
	for li in 0 ..< 4 {
		limb := b[3 - li] // limb 3 is most significant of the low 256 bits
		base := li * 8
		for k in 0 ..< 8 {
			out[base + k] = u8(limb >> uint(56 - 8 * k))
		}
	}
	return
}

// be_to_bn is the inverse: a big-endian [32]u8 into limbs 0..3 (4..7 stay zero).
@(private)
be_to_bn :: proc(b: [32]u8) -> (r: Bn) {
	for li in 0 ..< 4 {
		base := (3 - li) * 8 // li 0 -> bytes[24:32] -> least significant limb
		v: u64
		for k in 0 ..< 8 {
			v = (v << 8) | u64(b[base + k])
		}
		r[li] = v
	}
	return
}

@(private)
bn_high_bits_set :: proc(b: Bn) -> bool {
	return (b[4] | b[5] | b[6] | b[7]) != 0
}

// ---------------------------------------------------------------------------
// f64 decomposition: diff = mant * 2^e, mant a 53-bit integer, pulled from the
// IEEE-754 bit pattern so there is no float rounding in the mantissa.
// ---------------------------------------------------------------------------

@(private)
f64_decompose :: proc(d: f64) -> (mant: u64, e: int, ok: bool) {
	if d <= 0 {
		return 0, 0, false
	}
	bits := transmute(u64)d
	exp_field := (bits >> 52) & 0x7FF
	frac := bits & 0x000F_FFFF_FFFF_FFFF
	switch exp_field {
	case 0x7FF:
		return 0, 0, false // inf / nan
	case 0:
		// subnormal: value = frac * 2^-1074
		return frac, -1074, true
	case:
		// normal: value = (2^52 + frac) * 2^(exp_field - 1075)
		return frac | (1 << 52), int(exp_field) - 1075, true
	}
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// target_from_difficulty computes floor(diff1 / difficulty) as a big-endian target.
// difficulty may be < 1 (target > diff1), which this chain requires. A non-positive
// or non-finite difficulty falls back to DIFF1 (the hardest sane target) rather than
// an all-ones target that would accept every hash.
target_from_difficulty :: proc(difficulty: f64) -> (target: [32]u8) {
	mant, e, ok := f64_decompose(difficulty)
	if !ok {
		return DIFF1
	}

	// diff1 / (mant * 2^e) == (diff1 * 2^-e) / mant
	dividend: Bn
	if e <= 0 {
		dividend = bn_shl(DIFF1_BN, uint(-e))
	} else {
		dividend = bn_shr(DIFF1_BN, uint(e))
	}

	q, _ := bn_divmod_u64(dividend, mant)
	if bn_high_bits_set(q) {
		// Difficulty so small the target exceeds 2^256 - clamp to max.
		for i in 0 ..< 32 {
			target[i] = 0xFF
		}
		return
	}
	return bn_to_be(q)
}

// target_from_compact converts a compact-bits (nbits) field into a 256-bit target.
// Used to recognize a real block find from the header's nbits. overflow is set if
// the encoded value is negative or exceeds 256 bits.
target_from_compact :: proc(nbits: u32) -> (target: [32]u8, overflow: bool) {
	exp := int(nbits >> 24)
	mant := u64(nbits & 0x007F_FFFF)
	negative := (nbits & 0x0080_0000) != 0

	b: Bn
	b[0] = mant
	if exp <= 3 {
		b = bn_shr(b, uint(8 * (3 - exp)))
	} else {
		b = bn_shl(b, uint(8 * (exp - 3)))
	}

	overflow = (negative && mant != 0) || bn_high_bits_set(b)
	return bn_to_be(b), overflow
}

// hash_meets_target reports whether a reversed sha256d digest is strictly below the
// target. Both are big-endian 256-bit integers, so this is a memcmp (CLAUDE.md
// § Target check: "accept if mem.compare(hash, target) < 0"). Equality is a reject.
hash_meets_target :: proc(hash_be: [32]u8, target: [32]u8) -> bool {
	for i in 0 ..< 32 {
		if hash_be[i] != target[i] {
			return hash_be[i] < target[i]
		}
	}
	return false
}

// difficulty_from_nbits recovers the network difficulty (relative to diff-1) from a
// header's compact bits — the real number to show an operator, straight off the wire.
// difficulty-1 compact is 0x1d00ffff, so D = (0xffff / mantissa) * 256^(0x1d - exp).
difficulty_from_nbits :: proc(nbits: u32) -> f64 {
	exp := int(nbits >> 24)
	mant := f64(nbits & 0x007f_ffff)
	if mant == 0 {
		return 0
	}
	return (65535.0 / mant) * math.pow(256.0, f64(0x1d - exp))
}
