package cuda

// Host driver for the CUDA hasher: create a context, load the cubin, and launch the
// scan. Self-contained — it takes raw header bytes and a target, so `grotti` depends
// on `cuda` and never the reverse (no import cycle). The governor stays ABOVE this,
// in grotti; this engine's only job is "scan this nonce range, report every hit".

import "core:fmt"
import "core:strings"

// JOB_WORDS: [0..7] midstate, [8..10] w0,w1,w2, [11..18] target (8 be words).
JOB_WORDS :: 19

Engine :: struct {
	api:      CUDA_API,
	ctx:      rawptr,
	module:   rawptr,
	fn:       rawptr, // the `scan` kernel
	d_job:    Device_Ptr, // JOB_WORDS * u32 — midstate + const words + target
	d_hits:   Device_Ptr, // max_hits * u32
	d_count:  Device_Ptr, // u32 atomic counter
	max_hits: u32,
}

@(private)
check :: proc(e: ^Engine, code: i32, what: string) -> bool {
	if code != CUDA_SUCCESS {
		fmt.eprintfln("cuda: %s failed: %s (%d)", what, err_string(&e.api, code), code)
		return false
	}
	return true
}

// engine_open loads the driver, inits, and creates a context on device 0. The
// context becomes current on the CALLING thread — so a worker that will launch must
// call engine_init on its own thread.
@(private)
engine_open :: proc(e: ^Engine) -> bool {
	if !cuda_available(&e.api) {
		fmt.eprintln("cuda: driver not available")
		return false
	}
	A := &e.api
	if !check(e, A.cuInit(0), "cuInit") {
		return false
	}
	dev: i32
	if !check(e, A.cuDeviceGet(&dev, 0), "cuDeviceGet") {
		return false
	}
	return check(e, A.cuCtxCreate_v2(&e.ctx, 0, dev), "cuCtxCreate")
}

@(private)
engine_finish :: proc(e: ^Engine, max_hits: u32) -> bool {
	A := &e.api
	if !check(e, A.cuModuleGetFunction(&e.fn, e.module, "scan"), "cuModuleGetFunction") {
		return false
	}
	e.max_hits = max_hits
	ok := true
	ok &= check(e, A.cuMemAlloc_v2(&e.d_job, JOB_WORDS * 4), "alloc job")
	ok &= check(e, A.cuMemAlloc_v2(&e.d_hits, uint(max_hits) * 4), "alloc hits")
	ok &= check(e, A.cuMemAlloc_v2(&e.d_count, 4), "alloc count")
	return ok
}

// engine_init loads the cubin from a file path (dev harnesses).
engine_init :: proc(e: ^Engine, cubin_path: string, max_hits: u32 = 4096) -> bool {
	if !engine_open(e) {
		return false
	}
	cpath := strings.clone_to_cstring(cubin_path, context.temp_allocator)
	if !check(e, e.api.cuModuleLoad(&e.module, cpath), "cuModuleLoad") {
		return false
	}
	return engine_finish(e, max_hits)
}

// engine_init_data loads the cubin from an in-memory image (the binary embeds it via
// #load, so there is no separate file to ship — DEVELOPMENT.md § The kernel).
engine_init_data :: proc(e: ^Engine, cubin: []u8, max_hits: u32 = 4096) -> bool {
	if !engine_open(e) {
		return false
	}
	img := cubin
	if !check(e, e.api.cuModuleLoadData(&e.module, raw_data(img)), "cuModuleLoadData") {
		return false
	}
	return engine_finish(e, max_hits)
}

// engine_load_job uploads the folded job: the midstate over header[0:64], the three
// constant block-B message words (w0,w1,w2 = big-endian header[64:76]), and the
// target as 8 big-endian words. Called once per job (never in the scan loop).
engine_load_job :: proc(e: ^Engine, midstate: [8]u32, w0, w1, w2: u32, target: [32]u8) -> bool {
	job: [JOB_WORDS]u32
	for i in 0 ..< 8 {
		job[i] = midstate[i]
	}
	job[8] = w0
	job[9] = w1
	job[10] = w2
	for i in 0 ..< 8 {
		job[11 + i] =
			u32(target[i * 4]) << 24 |
			u32(target[i * 4 + 1]) << 16 |
			u32(target[i * 4 + 2]) << 8 |
			u32(target[i * 4 + 3])
	}
	return check(e, e.api.cuMemcpyHtoD_v2(e.d_job, raw_data(job[:]), JOB_WORDS * 4), "copy job")
}

// engine_scan launches the kernel over [start, start+count) and drains the hits.
// Returns the TOTAL hit count (which may exceed len(hits) — the kernel counts all,
// the host keeps up to len(hits)).
engine_scan :: proc(e: ^Engine, start: u32, count: u32, hits: []u32) -> int {
	A := &e.api

	zero: u32 = 0
	if !check(e, A.cuMemcpyHtoD_v2(e.d_count, &zero, 4), "reset count") {
		return 0
	}

	// Kernel args are passed by address (cuLaunchKernel dereferences each).
	s := start
	c := count
	mh := e.max_hits
	args := [6]rawptr{&e.d_job, &s, &c, &e.d_hits, &e.d_count, &mh}

	BLOCK :: u32(256)
	grid := (count + BLOCK - 1) / BLOCK
	if !check(e, A.cuLaunchKernel(e.fn, grid, 1, 1, BLOCK, 1, 1, 0, nil, raw_data(args[:]), nil), "launch") {
		return 0
	}
	if !check(e, A.cuCtxSynchronize(), "sync") {
		return 0
	}

	n: u32 = 0
	if !check(e, A.cuMemcpyDtoH_v2(&n, e.d_count, 4), "read count") {
		return 0
	}
	take := min(n, e.max_hits)
	if take > 0 && len(hits) > 0 {
		want := min(int(take), len(hits))
		A.cuMemcpyDtoH_v2(raw_data(hits), e.d_hits, uint(want) * 4)
	}
	return int(n)
}

engine_destroy :: proc(e: ^Engine) {
	A := &e.api
	if A.cuMemFree_v2 != nil {
		A.cuMemFree_v2(e.d_job)
		A.cuMemFree_v2(e.d_hits)
		A.cuMemFree_v2(e.d_count)
	}
	if e.ctx != nil && A.cuCtxDestroy_v2 != nil {
		A.cuCtxDestroy_v2(e.ctx)
	}
}
