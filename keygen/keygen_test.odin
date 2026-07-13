package keygen

import "core:testing"

// blake3 known-answer: BLAKE3("") = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9...
@(test)
test_blake3_empty :: proc(t: ^testing.T) {
	got := blake3_20({})
	want := [20]u8 {
		0xaf, 0x13, 0x49, 0xb9, 0xf5, 0xf9, 0xa1, 0xa6, 0xa0, 0x40,
		0x4d, 0xea, 0x36, 0xdc, 0xc9, 0x49, 0x9b, 0xcb, 0x25, 0xc9,
	}
	testing.expect_value(t, got, want)
}

// The wordlist is the canonical BIP39 English list (abandon .. zoo).
@(test)
test_wordlist :: proc(t: ^testing.T) {
	wordlist_init()
	testing.expect(t, g_words[0] == "abandon", "first word is 'abandon'")
	testing.expect(t, g_words[2047] == "zoo", "last word is 'zoo'")
	testing.expect(t, g_words[1] == "ability", "index 1 is 'ability'")
	testing.expect(t, g_words[2] == "able", "index 2 is 'able'")
}

// THE proof: reproduce a real thunder-rust mnemonic -> address pair. If this matches,
// the whole derivation (BIP39 seed, SLIP-0010, ed25519, blake3, base58) equals
// thunder-rust's, wordlist included.
@(test)
test_known_address :: proc(t: ^testing.T) {
	addr := address_from_mnemonic(
		"slender manage siege cause chicken garbage sustain produce act kind wheel column",
	)
	defer delete(addr)
	testing.expect(t, addr == "29BXpnvBcd714SSA62xUy2tHWy8B", "matches thunder-rust gen_address")
}

// A freshly generated mnemonic recovers its own address, and is 12 words.
@(test)
test_generate_roundtrip :: proc(t: ^testing.T) {
	w := generate()
	defer delete(w.mnemonic)
	defer delete(w.address)

	recovered := address_from_mnemonic(w.mnemonic)
	defer delete(recovered)
	testing.expect(t, recovered == w.address, "generated mnemonic recovers its address")

	words := 1
	for c in w.mnemonic {
		if c == ' ' {
			words += 1
		}
	}
	testing.expect_value(t, words, 12)
}
