package main

// Bring-up milestone: prove the Vulkan loader FFI works end to end — dlopen the loader,
// create a throwaway instance, and identify the GPU — WITHOUT any crypto yet. Mirrors
// cuda/probe.
//
//   odin run vulkan/probe

import vkb ".."
import "core:fmt"

main :: proc() {
	info := vkb.vulkan_probe()
	if !info.present {
		fmt.println("vulkan: unavailable (no loader / no device) — this is the graceful path")
		return
	}
	fmt.printfln(
		"vulkan: %s [%s]  ·  api %d.%d  ·  %s  ·  selected of %d device(s)",
		vkb.device_name(&info),
		vkb.vendor_name(info.vendor_id),
		info.api_major,
		info.api_minor,
		info.is_discrete ? "discrete" : "integrated/other",
		info.device_count,
	)
}
