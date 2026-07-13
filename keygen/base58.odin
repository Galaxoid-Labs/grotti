package keygen

// Base58 encoding (Bitcoin alphabet, no checksum) — Thunder addresses are
// bitcoin::base58::encode of 20 raw bytes. Not in core:encoding, so it's here.

base58_encode :: proc(input: []u8, allocator := context.allocator) -> string {
	ALPHA := "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
	zeros := 0
	for zeros < len(input) && input[zeros] == 0 {
		zeros += 1
	}

	// Upper bound on the base58 length: log(256)/log(58) ≈ 1.365 per byte.
	size := (len(input) - zeros) * 138 / 100 + 1
	b58 := make([]u8, size, context.temp_allocator) // zero-initialized
	length := 0

	for i in zeros ..< len(input) {
		carry := int(input[i])
		k := 0
		for j := size - 1; j >= 0 && (carry != 0 || k < length); j -= 1 {
			carry += 256 * int(b58[j])
			b58[j] = u8(carry % 58)
			carry /= 58
			k += 1
		}
		length = k
	}

	start := size - length
	out := make([]u8, zeros + (size - start), allocator)
	idx := 0
	for _ in 0 ..< zeros {
		out[idx] = '1' // leading zero bytes → leading '1's
		idx += 1
	}
	for j := start; j < size; j += 1 {
		out[idx] = ALPHA[b58[j]]
		idx += 1
	}
	return string(out)
}
