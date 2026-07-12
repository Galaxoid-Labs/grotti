package grotti

import "core:testing"
import "sha256d"

// hex32 decodes 64 hex chars into a [32]u8 (display order, as an RPC/explorer hash
// string reads). Test helper only.
@(private)
hex32 :: proc(s: string) -> (out: [32]u8) {
	nib :: proc(c: u8) -> u8 {
		switch {
		case c >= '0' && c <= '9':
			return c - '0'
		case c >= 'a' && c <= 'f':
			return c - 'a' + 10
		case c >= 'A' && c <= 'F':
			return c - 'A' + 10
		}
		return 0
	}
	b := transmute([]u8)s
	for i in 0 ..< 32 {
		out[i] = (nib(b[i * 2]) << 4) | nib(b[i * 2 + 1])
	}
	return
}

// Real block 125552 (the canonical Bitcoin "Block hashing algorithm" vector,
// fetched from a node — not transcribed from memory). Fields in RPC/display form:
@(private)
B125552_VERSION :: u32(1)
@(private)
B125552_PREV :: "00000000000008a3a41b85b8b29ad444def299fee21793cd8b9e567eab02cd81"
@(private)
B125552_MERKLE :: "2b12fcf1b09288fcaff797d71e950e71ae42b91e8bdb2304758dfcffc2b620e3"
@(private)
B125552_NTIME :: u32(1305998791) // 0x4DD7F5C7
@(private)
B125552_NBITS :: u32(0x1A44B9F2) // 440711666
@(private)
B125552_NONCE :: u32(2504433986) // 0x9546A142
@(private)
B125552_HASH :: "00000000000000001e8d6829a8a21adc5d38d0a473b144b6765798e61f98bd1d"

// THE anchor (Test plan #2): assemble the header from real fields and reproduce the
// exact block hash. Catches any header-layout or endianness error the SHA tests
// cannot. prev/merkle are display order in the string, so reverse to internal.
@(test)
test_header_125552 :: proc(t: ^testing.T) {
	prev := reverse32(hex32(B125552_PREV))
	merkle := reverse32(hex32(B125552_MERKLE))
	h := serialize_header(B125552_VERSION, prev, merkle, B125552_NTIME, B125552_NBITS, B125552_NONCE)
	testing.expect_value(t, block_hash(h), hex32(B125552_HASH))
}

// The prevhash word-swap is its own inverse.
@(test)
test_prevhash_wordswap_involution :: proc(t: ^testing.T) {
	s: [32]u8
	for i in 0 ..< 32 {
		s[i] = u8(i * 7 + 1)
	}
	testing.expect_value(t, prevhash_stratum_to_internal(prevhash_stratum_to_internal(s)), s)
}

// The word-swap, end to end: derive what Stratum WOULD send for block 125552's
// prevhash (its 8 display words in reverse order), run it through the conversion,
// and confirm the resulting header reproduces the block hash. This validates the
// conversion against real data; the live wire encoding is reconfirmed on the trace.
@(test)
test_prevhash_wordswap_reproduces_block :: proc(t: ^testing.T) {
	disp := hex32(B125552_PREV) // display order, 8 words d0..d7
	// Stratum prevhash = display words in reverse order, bytes within each word kept.
	stratum: [32]u8
	for w in 0 ..< 8 {
		src := (7 - w) * 4
		copy(stratum[w * 4:w * 4 + 4], disp[src:src + 4])
	}
	prev := prevhash_stratum_to_internal(stratum)
	merkle := reverse32(hex32(B125552_MERKLE))
	h := serialize_header(B125552_VERSION, prev, merkle, B125552_NTIME, B125552_NBITS, B125552_NONCE)
	testing.expect_value(t, block_hash(h), hex32(B125552_HASH))
}

@(test)
test_parse_u32_be_hex :: proc(t: ^testing.T) {
	v, ok := parse_u32_be_hex("1a44b9f2")
	testing.expect(t, ok, "valid hex parses")
	testing.expect_value(t, v, u32(0x1A44B9F2))

	v2, ok2 := parse_u32_be_hex("1")
	testing.expect(t, ok2 && v2 == 1, "short hex ok")

	_, ok3 := parse_u32_be_hex("1g")
	testing.expect(t, !ok3, "non-hex rejected")

	_, ok4 := parse_u32_be_hex("123456789")
	testing.expect(t, !ok4, "over 8 digits rejected")
}

// job_build_header splices the coinbase for a given en2, folds the merkle root, and
// lays out the header — the per-thread work each Menja does before scanning.
@(test)
test_job_build_header :: proc(t: ^testing.T) {
	job: Job
	job.version = B125552_VERSION
	job.prev = reverse32(hex32(B125552_PREV))
	job.ntime = B125552_NTIME
	job.nbits = B125552_NBITS
	job.coinb1[0] = 0xAA;job.coinb1[1] = 0xBB;job.coinb1_len = 2
	job.en1[0] = 0x01;job.en1_len = 1
	job.coinb2[0] = 0xCC;job.coinb2_len = 1
	// no branches

	en2 := []u8{0xDD, 0xEE}
	buf: [64]u8
	got := job_build_header(&job, en2, buf[:])

	// Independently: coinbase = AA BB 01 DD EE CC, root = sha256d(coinbase).
	expected_cb := []u8{0xAA, 0xBB, 0x01, 0xDD, 0xEE, 0xCC}
	root := sha256d.sum256d(expected_cb)
	want := serialize_header(job.version, job.prev, root, job.ntime, job.nbits, 0)
	testing.expect_value(t, got, want)
}

// Merkle folding: order matters and the running hash is always on the left.
@(test)
test_merkle_fold :: proc(t: ^testing.T) {
	coinbase := []u8{0xde, 0xad, 0xbe, 0xef}
	branch := [32]u8{}
	for i in 0 ..< 32 {
		branch[i] = u8(i)
	}

	// No branches: root is just sha256d(coinbase).
	testing.expect_value(t, merkle_root(coinbase, {}), sha256d.sum256d(coinbase))

	// One branch: root = sha256d(sha256d(coinbase) || branch), current on the LEFT.
	cb := sha256d.sum256d(coinbase)
	pair: [64]u8
	copy(pair[0:32], cb[:])
	copy(pair[32:64], branch[:])
	want := sha256d.sum256d(pair[:])
	testing.expect_value(t, merkle_root(coinbase, {branch}), want)

	// Left vs right is not symmetric: branch-on-left differs from branch-on-right.
	copy(pair[0:32], branch[:])
	copy(pair[32:64], cb[:])
	branch_left := sha256d.sum256d(pair[:])
	testing.expect(t, want != branch_left, "left/right ordering must matter")
}

// build_coinbase splices in the exact wire order coinb1||en1||en2||coinb2.
@(test)
test_build_coinbase :: proc(t: ^testing.T) {
	buf: [16]u8
	got := build_coinbase({0x01, 0x02}, {0xAA}, {0xBB, 0xCC}, {0x03}, buf[:])
	want := []u8{0x01, 0x02, 0xAA, 0xBB, 0xCC, 0x03}
	testing.expect_value(t, len(got), len(want))
	for i in 0 ..< len(want) {
		testing.expect_value(t, got[i], want[i])
	}
}
