#+build !darwin
package grotti

// Portability stub for the Metal backend. Metal is a macOS-only framework, so the real
// worker (metal_worker.odin, #+build darwin) imports vendor:darwin/Metal, which does not
// compile off darwin. This file provides the same public symbols as no-ops so package
// grotti — and the CLI that references these — builds unchanged on Linux/Windows, where
// metal_available() simply reports false and `-backend:metal` errors cleanly (invariant #2c:
// a GPU backend is never auto-selected, and here it is not even present).

import "core:thread"

Metal_Info :: struct {
	present:     bool,
	name:        [256]u8,
	name_len:    int,
	unified:     bool,
	max_threads: int,
}

METAL_EN2_BASE :: int(1) << 29

METAL_Miner :: struct {
	worker: rawptr,
	thread: ^thread.Thread,
}

metal_device_name :: proc(i: ^Metal_Info) -> string {
	return string(i.name[:i.name_len])
}

metal_probe :: proc() -> (out: Metal_Info) {
	return
}

metal_available :: proc() -> bool {
	return false
}

metal_mine_start :: proc(ring: ^Job_Ring, shares: ^Share_Queue, st: ^Stats, id: int, cap_hps: f64, quit: ^u32) -> ^METAL_Miner {
	return nil
}

metal_mine_stop :: proc(m: ^METAL_Miner) {
}
