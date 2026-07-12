package main

// Phase 7 step 1 milestone: prove the CUDA driver FFI works end to end — load the
// library at runtime, init, and identify the GPU — WITHOUT any crypto yet.
//
//   odin run cuda/probe

import cuda ".."
import "core:fmt"

main :: proc() {
	info := cuda.cuda_probe()
	if !info.present {
		fmt.println("cuda: unavailable (no driver / no device) — this is the graceful path")
		return
	}
	fmt.printfln(
		"cuda: %s  ·  compute %d.%d  ·  %d SMs  ·  %.2f GHz",
		cuda.device_name(&info),
		info.cc_major,
		info.cc_minor,
		info.mp_count,
		f64(info.clock_khz) / 1e6,
	)
}
