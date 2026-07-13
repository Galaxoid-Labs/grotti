#+build darwin
package metalbackend

// Host driver for the Metal compute hasher: create the system default device, compile the
// MSL kernel from an embedded source string, build a compute pipeline, and launch the scan.
// Self-contained — it takes raw header foldings and a target, so `grotti` depends on
// `metalbackend` and never the reverse. The governor stays ABOVE this, in grotti; this
// engine's only job is "scan this nonce range, report every hit" (CLAUDE.md § 2b). The
// public API mirrors cuda.Engine / vkbackend.Engine 1:1 so the worker glue in package grotti
// (metal_worker.odin) is a near-copy of vk_worker.odin.
//
// Memory model: buffers are MTLResourceStorageModeShared. Apple Silicon is unified memory
// (like the GB10), so a shared buffer is both host- and device-visible with no staging
// copies; command-buffer completion (waitUntilCompleted) is the host/device sync point, so
// no explicit barrier is needed (CLAUDE.md § macOS/Metal notes).
//
// Metal is a guaranteed macOS system framework, so it is linked directly rather than
// dlopen'd — the "dlopen, never foreign import" rule guards against OPTIONAL libraries that
// may be absent, and a macOS build is macOS-only (DEVELOPMENT.md § Phase 9). This whole
// package is #+build darwin; the non-darwin worker stub keeps package grotti portable.

import MTL "vendor:darwin/Metal"
import NS "core:sys/darwin/Foundation"
import "core:fmt"

// Params rides in a small constant buffer (setBytes at index 0): 22 u32 = 88 bytes. The
// field order and packing MUST match the `struct Params` in sha256d.metal (all u32 → tight
// 4-byte stride, no padding).
Params :: struct {
	midstate:    [8]u32, // sha256 state after header[0:64]
	w0:          u32, // }
	w1:          u32, // }  constant block-B words (be of header[64:76])
	w2:          u32, // }
	target:      [8]u32, // target as 8 big-endian words (display order)
	start_nonce: u32,
	count:       u32,
	max_hits:    u32,
}
#assert(size_of(Params) == 88)

Engine :: struct {
	device:    ^MTL.Device,
	queue:     ^MTL.CommandQueue,
	lib:       ^MTL.Library,
	fn:        ^MTL.Function,
	pipeline:  ^MTL.ComputePipelineState,
	hits_buf:  ^MTL.Buffer,
	count_buf: ^MTL.Buffer,
	hits_ptr:  [^]u32, // persistent pointer into the shared hits buffer
	count_ptr: ^u32, // persistent pointer into the shared atomic counter
	max_hits:  u32,
	tg_size:   u32, // threads per threadgroup (pipeline-reported, capped at 256)
	params:    Params,
}

// engine_init_source brings up the device and pipeline from the MSL source (the binary
// embeds it via #load, so there is no metallib to ship). Mirrors cuda/vkbackend
// engine_init_data. Returns false on any failure, leaving a destroyable Engine.
engine_init_source :: proc(e: ^Engine, msl: string, max_hits: u32 = 4096) -> bool {
	pool := NS.scoped_autoreleasepool()

	e.device = MTL.CreateSystemDefaultDevice()
	if e.device == nil {
		fmt.eprintln("metal: no system default device")
		return false
	}
	e.max_hits = max_hits

	// Compile the kernel from source. CompileOptions defaults are fine (fast-math off keeps
	// the differential test bit-exact against the scalar hasher).
	src := NS.String.alloc()->initWithOdinString(msl)
	opts := MTL.CompileOptions.alloc()->init()
	defer src->release()
	defer opts->release()

	lib, lib_err := e.device->newLibraryWithSource(src, opts)
	if lib == nil {
		if lib_err != nil {
			fmt.eprintfln("metal: kernel compile failed: %s", lib_err->localizedDescription()->odinString())
		} else {
			fmt.eprintln("metal: kernel compile failed")
		}
		return false
	}
	e.lib = lib

	name := NS.String.alloc()->initWithOdinString("scan")
	defer name->release()
	e.fn = lib->newFunctionWithName(name)
	if e.fn == nil {
		fmt.eprintln("metal: kernel function `scan` not found")
		return false
	}

	pipe, pipe_err := e.device->newComputePipelineStateWithFunction(e.fn)
	if pipe == nil {
		if pipe_err != nil {
			fmt.eprintfln("metal: pipeline creation failed: %s", pipe_err->localizedDescription()->odinString())
		} else {
			fmt.eprintln("metal: pipeline creation failed")
		}
		return false
	}
	e.pipeline = pipe

	e.queue = e.device->newCommandQueue()
	if e.queue == nil {
		fmt.eprintln("metal: command queue creation failed")
		return false
	}

	// Shared (unified-memory) buffers: hits[max_hits] + a single u32 counter.
	e.hits_buf = e.device->newBufferWithLength(NS.UInteger(max_hits) * 4, MTL.ResourceStorageModeShared)
	e.count_buf = e.device->newBufferWithLength(4, MTL.ResourceStorageModeShared)
	if e.hits_buf == nil || e.count_buf == nil {
		fmt.eprintln("metal: buffer allocation failed")
		return false
	}
	e.hits_ptr = cast([^]u32)e.hits_buf->contentsPointer()
	e.count_ptr = cast(^u32)e.count_buf->contentsPointer()

	// One thread per nonce; a threadgroup of up to 256, clamped to what the pipeline allows.
	tg := u32(e.pipeline->maxTotalThreadsPerThreadgroup())
	e.tg_size = min(tg, 256)
	if e.tg_size == 0 {
		e.tg_size = 1
	}
	return true
}

// engine_load_job stores the folded job in the params payload: the midstate over
// header[0:64], the three constant block-B words, and the target as 8 big-endian words.
// No GPU call — the payload is uploaded via setBytes at dispatch time. Mirrors
// cuda/vkbackend engine_load_job.
engine_load_job :: proc(e: ^Engine, midstate: [8]u32, w0, w1, w2: u32, target: [32]u8) -> bool {
	e.params.midstate = midstate
	e.params.w0 = w0
	e.params.w1 = w1
	e.params.w2 = w2
	for i in 0 ..< 8 {
		e.params.target[i] =
			u32(target[i * 4]) << 24 |
			u32(target[i * 4 + 1]) << 16 |
			u32(target[i * 4 + 2]) << 8 |
			u32(target[i * 4 + 3])
	}
	return true
}

// engine_scan launches the kernel over [start, start+count) and drains the hits. Returns
// the TOTAL hit count (which may exceed len(hits) — the kernel counts all, the host keeps
// up to len(hits)). Mirrors cuda/vkbackend engine_scan. Each scan runs in its own
// autorelease pool so the per-launch command buffer/encoder (both autoreleased) are freed.
engine_scan :: proc(e: ^Engine, start: u32, count: u32, hits: []u32) -> int {
	pool := NS.scoped_autoreleasepool()

	e.params.start_nonce = start
	e.params.count = count
	e.params.max_hits = e.max_hits

	// Reset the atomic counter through the shared buffer; unified memory makes this host
	// write visible to the GPU for this dispatch.
	e.count_ptr^ = 0

	cmd := e.queue->commandBuffer()
	enc := cmd->computeCommandEncoder()
	enc->setComputePipelineState(e.pipeline)
	pbytes := (cast([^]u8)&e.params)[:size_of(Params)]
	enc->setBytes(pbytes, 0)
	enc->setBuffer(e.hits_buf, 0, 1)
	enc->setBuffer(e.count_buf, 0, 2)

	tg := e.tg_size
	groups := (count + tg - 1) / tg
	enc->dispatchThreadgroups(
		MTL.Size{NS.Integer(groups), 1, 1},
		MTL.Size{NS.Integer(tg), 1, 1},
	)
	enc->endEncoding()
	cmd->commit()
	cmd->waitUntilCompleted()

	n := e.count_ptr^
	take := min(n, e.max_hits)
	if take > 0 && len(hits) > 0 {
		want := min(int(take), len(hits))
		for i in 0 ..< want {
			hits[i] = e.hits_ptr[i]
		}
	}
	return int(n)
}

engine_destroy :: proc(e: ^Engine) {
	if e.hits_buf != nil do e.hits_buf->release()
	if e.count_buf != nil do e.count_buf->release()
	if e.pipeline != nil do e.pipeline->release()
	if e.fn != nil do e.fn->release()
	if e.lib != nil do e.lib->release()
	if e.queue != nil do e.queue->release()
	if e.device != nil do e.device->release()
	e^ = {}
}
