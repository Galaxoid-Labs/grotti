#+build darwin
package main

// Bring-up milestone: prove the Metal FFI works end to end — create the system default
// device and identify the GPU — WITHOUT any crypto yet. Mirrors cuda/probe and
// vulkan/probe.
//
//   odin run metal/probe

import mtl ".."
import "core:fmt"

main :: proc() {
	info := mtl.metal_probe()
	if !info.present {
		fmt.println("metal: unavailable (no default device) — this is the graceful path")
		return
	}
	fmt.printfln(
		"metal: %s  ·  %s memory  ·  %d threads/group",
		mtl.device_name(&info),
		info.unified ? "unified" : "discrete",
		info.max_threads,
	)
}
