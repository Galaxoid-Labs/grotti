package main

// Throughput benchmark for the Vulkan compute hasher — measures sustained hashrate on the
// selected device so VK_EST_HPS (the cap-split estimate in cli/main.odin) reflects reality.
//
//   odin run vulkan/bench -o:speed

import vkbackend ".."
import grotti "../.."
import sha256d "../../sha256d"
import "core:encoding/endian"
import "core:fmt"
import "core:time"

SPV :: #load("../sha256d.spv")

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

	e: vkbackend.Engine
	if !vkbackend.engine_init_data(&e, SPV) {
		fmt.eprintln("vulkan engine init failed")
		return
	}
	defer vkbackend.engine_destroy(&e)

	mid := sha256d.midstate(h[0:64])
	w0 := endian.unchecked_get_u32be(h[64:68])
	w1 := endian.unchecked_get_u32be(h[68:72])
	w2 := endian.unchecked_get_u32be(h[72:76])
	target, _ := grotti.target_from_compact(0x1a44b9f2) // real target → near-zero hits, minimal host overhead
	vkbackend.engine_load_job(&e, mid, w0, w1, w2, target)

	hits: [4096]u32

	// Sweep launch sizes to separate compute throughput from per-submit overhead.
	for shift in u32(22) ..= u32(27) {
		launch := u32(1) << shift
		iters := (u64(1) << 30) / u64(launch) // ~1B nonces total per size
		if iters < 4 {
			iters = 4
		}

		vkbackend.engine_scan(&e, 0, launch, hits[:]) // warmup

		start := time.now()
		total: u64
		for i in 0 ..< iters {
			vkbackend.engine_scan(&e, u32(i) * launch, launch, hits[:])
			total += u64(launch)
		}
		dt := time.duration_seconds(time.since(start))
		fmt.printfln(
			"launch 2^%d (%d nonces): %.3f GH/s  (%.2f ms/launch)",
			shift,
			launch,
			f64(total) / dt / 1e9,
			dt / f64(iters) * 1000,
		)
	}
}
