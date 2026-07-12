package main

// GB10 throughput of the NAIVE kernel (no midstate/fold/early-exit yet — this is the
// floor, not the ceiling). Uses the block-125552 header at network difficulty so
// there are ~no hits: pure hashing throughput.
//
//   odin run cuda/bench -o:speed

import cuda ".."
import grotti "../.."
import sha256d "../../sha256d"
import "core:encoding/endian"
import "core:fmt"
import "core:time"

CUBIN :: "/home/jdavis/Development/grotti/cuda/kernel.cubin"

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

main :: proc() {
	prev := grotti.reverse32(hex32("00000000000008a3a41b85b8b29ad444def299fee21793cd8b9e567eab02cd81"))
	merkle := grotti.reverse32(hex32("2b12fcf1b09288fcaff797d71e950e71ae42b91e8bdb2304758dfcffc2b620e3"))
	h := grotti.serialize_header(1, prev, merkle, 1305998791, 0x1a44b9f2, 0)
	target, _ := grotti.target_from_compact(0x1a44b9f2)

	e: cuda.Engine
	if !cuda.engine_init(&e, CUBIN) {
		fmt.eprintln("engine init failed")
		return
	}
	defer cuda.engine_destroy(&e)
	mid := sha256d.midstate(h[0:64])
	w0 := endian.unchecked_get_u32be(h[64:68])
	w1 := endian.unchecked_get_u32be(h[68:72])
	w2 := endian.unchecked_get_u32be(h[72:76])
	cuda.engine_load_job(&e, mid, w0, w1, w2, target)

	hits: [16]u32
	PER :: u32(1) << 24 // 16.7M nonces per launch
	LAUNCHES :: 128

	cuda.engine_scan(&e, 0, PER, hits[:]) // warmup

	start := time.tick_now()
	total: u64 = 0
	nonce: u32 = 0
	for _ in 0 ..< LAUNCHES {
		cuda.engine_scan(&e, nonce, PER, hits[:])
		nonce += PER
		total += u64(PER)
	}
	elapsed := time.duration_seconds(time.tick_diff(start, time.tick_now()))
	ghs := f64(total) / elapsed / 1e9

	fmt.printfln("GB10 kernel: %.2f GH/s   (%d hashes in %.3fs)", ghs, total, elapsed)
	fmt.printfln("  vs one CPU SIMD thread (8.41 MH/s): ~%.0fx", ghs * 1e9 / 8.41e6)
	fmt.printfln("  a diff-1024 share every ~%.1f s at this rate", 4.4e12 / (ghs * 1e9))
}
