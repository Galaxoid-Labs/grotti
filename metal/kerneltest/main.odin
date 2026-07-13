#+build darwin
package main

// Correctness gate for the Metal compute hasher — the green light that de-risks the whole
// backend (CLAUDE.md invariant #4). Same two checks as cuda/kerneltest and vulkan/kerneltest:
//   1. Reproduce block 125552's winning nonce (real-data anchor).
//   2. Differential vs the CPU scan_simd over the same range on an easy target — Metal must
//      find EXACTLY the same hits. A fast-but-wrong kernel is worse than none. Do NOT wire
//      Metal into the miner until this PASSes on real hardware.
//
//   odin run metal/kerneltest

import metalbackend ".."
import grotti "../.."
import sha256d "../../sha256d"
import "core:encoding/endian"
import "core:fmt"
import "core:slice"

MSL :: #load("../sha256d.metal")

hex32 :: proc(s: string) -> (out: [32]u8) {
	nib :: proc(c: u8) -> u8 {
		switch {
		case c >= '0' && c <= '9':
			return c - '0'
		case c >= 'a' && c <= 'f':
			return c - 'a' + 10
		}
		return 0
	}
	b := transmute([]u8)s
	for i in 0 ..< 32 {
		out[i] = (nib(b[i * 2]) << 4) | nib(b[i * 2 + 1])
	}
	return
}

fold :: proc(h: ^grotti.Header) -> (mid: [8]u32, w0, w1, w2: u32) {
	mid = sha256d.midstate(h[0:64])
	w0 = endian.unchecked_get_u32be(h[64:68])
	w1 = endian.unchecked_get_u32be(h[68:72])
	w2 = endian.unchecked_get_u32be(h[72:76])
	return
}

main :: proc() {
	prev := grotti.reverse32(hex32("00000000000008a3a41b85b8b29ad444def299fee21793cd8b9e567eab02cd81"))
	merkle := grotti.reverse32(hex32("2b12fcf1b09288fcaff797d71e950e71ae42b91e8bdb2304758dfcffc2b620e3"))
	h := grotti.serialize_header(1, prev, merkle, 1305998791, 0x1a44b9f2, 0)

	e: metalbackend.Engine
	if !metalbackend.engine_init_source(&e, string(MSL)) {
		fmt.eprintln("metal engine init failed")
		return
	}
	defer metalbackend.engine_destroy(&e)

	mid, w0, w1, w2 := fold(&h)
	pass := true

	// 1. Block 125552 anchor.
	{
		WINNER :: u32(0x9546A142)
		target, _ := grotti.target_from_compact(0x1a44b9f2)
		metalbackend.engine_load_job(&e, mid, w0, w1, w2, target)
		hits: [16]u32
		n := metalbackend.engine_scan(&e, WINNER - 100, 4096, hits[:])
		found := n >= 1 && slice.contains(hits[:min(n, len(hits))], WINNER)
		fmt.printfln("anchor: block 125552 winner %s (%d hit)", found ? "REPRODUCED" : "MISSING", n)
		pass &= found
	}

	// 2. Differential vs CPU over the same range, easy target.
	{
		easy: [32]u8
		for i in 1 ..< 32 {
			easy[i] = 0xFF // top byte must be 0 (~1/256)
		}
		metalbackend.engine_load_job(&e, mid, w0, w1, w2, easy)

		gpu: [2048]u32
		cpu: [2048]u32
		gn := metalbackend.engine_scan(&e, 0, 65536, gpu[:])
		cn := grotti.scan_simd(&h, easy, 0, 65536, cpu[:])

		match := gn == cn
		if match {
			slice.sort(gpu[:min(gn, len(gpu))]) // hits arrive in atomic order
			for i in 0 ..< min(cn, len(cpu)) {
				if gpu[i] != cpu[i] {
					match = false
					break
				}
			}
		}
		fmt.printfln("differential: Metal %d hits vs CPU %d hits — %s", gn, cn, match ? "IDENTICAL" : "MISMATCH")
		pass &= match
	}

	fmt.println(pass ? "PASS: kernel is correct — safe to optimize / integrate." : "FAIL: do NOT proceed.")
}
