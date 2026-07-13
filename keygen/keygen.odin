package keygen

// Thunder wallet key generation, pure Odin, no external deps. Mirrors thunder-rust:
//   BIP39 mnemonic -> BIP39 seed (PBKDF2-HMAC-SHA512)
//   -> SLIP-0010 ed25519 HD at m/1'/0'/0'/1' (HMAC-SHA512 chain, hardened-only)
//   -> ed25519 public key
//   -> base58( blake3_xof(pubkey)[0:20] )
// The BIP39 seed, HMAC, PBKDF2 and ed25519 come from core:crypto; only blake3 and
// base58 are written here. Validated against a known mnemonic->address vector.

import "core:crypto"
import "core:crypto/ed25519"
import "core:crypto/hmac"
import "core:crypto/pbkdf2"
import "core:crypto/sha2"
import "core:strings"

@(private)
WORDLIST_TXT := string(#load("english.txt"))

@(private)
g_words: [2048]string
@(private)
g_words_ready: bool

@(private)
wordlist_init :: proc() {
	if g_words_ready {
		return
	}
	it := WORDLIST_TXT
	i := 0
	for line in strings.split_lines_iterator(&it) {
		w := strings.trim_space(line)
		if len(w) == 0 || i >= 2048 {
			continue
		}
		g_words[i] = w
		i += 1
	}
	g_words_ready = true
}

@(private)
sha256 :: proc(data: []u8) -> (out: [32]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, out[:])
	return
}

@(private)
hmac_sha512 :: proc(key, data: []u8) -> (out: [64]u8) {
	hmac.sum(.SHA512, out[:], data, key)
	return
}

// bip39_seed: PBKDF2-HMAC-SHA512, 2048 iterations, salt "mnemonic" + empty passphrase.
@(private)
bip39_seed :: proc(mnemonic: string) -> (seed: [64]u8) {
	pbkdf2.derive(.SHA512, transmute([]u8)mnemonic, transmute([]u8)string("mnemonic"), 2048, seed[:])
	return
}

// slip10_ed25519: derive the private key at m/1'/0'/0'/1' (all hardened).
@(private)
slip10_ed25519 :: proc(seed: []u8) -> (priv: [32]u8) {
	I := hmac_sha512(transmute([]u8)string("ed25519 seed"), seed)
	key, chain: [32]u8
	copy(key[:], I[0:32])
	copy(chain[:], I[32:64])

	for index in ([4]u32{1, 0, 0, 1}) {
		idx := index | 0x8000_0000 // hardened
		data: [37]u8
		data[0] = 0x00
		copy(data[1:33], key[:])
		data[33] = u8(idx >> 24)
		data[34] = u8(idx >> 16)
		data[35] = u8(idx >> 8)
		data[36] = u8(idx)
		I = hmac_sha512(chain[:], data[:])
		copy(key[:], I[0:32])
		copy(chain[:], I[32:64])
	}
	return key
}

@(private)
ed25519_public :: proc(priv_seed: []u8) -> (pub: [32]u8) {
	pk: ed25519.Private_Key
	ensure(ed25519.private_key_set_bytes(&pk, priv_seed), "ed25519: bad private key")
	ed25519.private_key_public_bytes(&pk, pub[:])
	return
}

// address_from_mnemonic derives the first Thunder address (index 1) for a mnemonic.
address_from_mnemonic :: proc(mnemonic: string, allocator := context.allocator) -> string {
	seed := bip39_seed(mnemonic)
	priv := slip10_ed25519(seed[:])
	pub := ed25519_public(priv[:])
	addr := blake3_20(pub[:])
	return base58_encode(addr[:], allocator)
}

// entropy_to_mnemonic turns 16 bytes (128 bits) of entropy into a 12-word phrase.
@(private)
entropy_to_mnemonic :: proc(entropy: []u8, allocator := context.allocator) -> string {
	wordlist_init()
	h := sha256(entropy)
	buf: [17]u8
	copy(buf[:16], entropy)
	buf[16] = h[0] // top 4 bits are the checksum

	b := strings.builder_make(allocator)
	for w in 0 ..< 12 {
		idx := 0
		for bit in 0 ..< 11 {
			pos := w * 11 + bit
			v := (buf[pos / 8] >> uint(7 - pos % 8)) & 1
			idx = (idx << 1) | int(v)
		}
		if w > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, g_words[idx])
	}
	return strings.to_string(b)
}

Wallet :: struct {
	mnemonic: string,
	address:  string,
}

// generate mints a fresh 12-word wallet (128-bit entropy) and its first address.
//
// SECURITY: this crypto.rand_bytes call is the ONLY source of randomness in the whole
// keygen path (everything after it is deterministic). It draws from the OS
// cryptographic entropy source (getrandom / /dev/urandom on Linux): it blocks until
// the pool is seeded and PANICS on any failure, so it can never silently fall back to
// a weak generator. It is NOT core:math/rand.
generate :: proc(allocator := context.allocator) -> Wallet {
	entropy: [16]u8
	crypto.rand_bytes(entropy[:]) // OS CSPRNG — see the security note above
	mnemonic := entropy_to_mnemonic(entropy[:], allocator)
	return Wallet{mnemonic = mnemonic, address = address_from_mnemonic(mnemonic, allocator)}
}
