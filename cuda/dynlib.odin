package cuda

// The CUDA Driver API, loaded at RUNTIME via core:dynlib — never `foreign import`,
// which would make the whole binary refuse to start on a box with no libcuda
// (CLAUDE.md § backends, DEVELOPMENT.md § Runtime loading). If the driver is absent,
// the probe simply reports the backend unavailable.
//
// Phase 7 step 1: prove this FFI works (init → device → attributes) before writing a
// single line of crypto.

import "core:dynlib"

CUDA_SUCCESS :: 0

// CUdevice_attribute values we use (from cuda.h).
ATTR_COMPUTE_CAPABILITY_MAJOR :: 75
ATTR_COMPUTE_CAPABILITY_MINOR :: 76
ATTR_MULTIPROCESSOR_COUNT :: 16
ATTR_CLOCK_RATE :: 13 // kHz

// CUdeviceptr is a 64-bit integer handle to device memory; CUcontext/CUmodule/
// CUfunction/CUstream are opaque pointers.
Device_Ptr :: u64

// The subset of the driver API Grotti needs. Field names are the exported symbol
// names; versioned entry points use their real `_v2` symbol so we bind the ABI the
// headers actually resolve to.
CUDA_API :: struct {
	cuInit:                        proc "c" (flags: u32) -> i32,
	cuDeviceGetCount:              proc "c" (count: ^i32) -> i32,
	cuDeviceGet:                   proc "c" (device: ^i32, ordinal: i32) -> i32,
	cuDeviceGetName:               proc "c" (name: [^]u8, len: i32, dev: i32) -> i32,
	cuDeviceGetAttribute:          proc "c" (pi: ^i32, attrib: i32, dev: i32) -> i32,
	cuCtxCreate_v2:                proc "c" (pctx: ^rawptr, flags: u32, dev: i32) -> i32,
	cuCtxDestroy_v2:               proc "c" (ctx: rawptr) -> i32,
	cuCtxSetCurrent:               proc "c" (ctx: rawptr) -> i32,
	cuCtxSynchronize:              proc "c" () -> i32,
	cuModuleLoad:                  proc "c" (module: ^rawptr, fname: cstring) -> i32,
	cuModuleLoadData:              proc "c" (module: ^rawptr, image: rawptr) -> i32,
	cuModuleGetFunction:           proc "c" (hfunc: ^rawptr, hmod: rawptr, name: cstring) -> i32,
	cuLaunchKernel:                proc "c" (
		f: rawptr,
		gx, gy, gz: u32,
		bx, by, bz: u32,
		shmem: u32,
		stream: rawptr,
		params: [^]rawptr,
		extra: [^]rawptr,
	) -> i32,
	cuMemAlloc_v2:                 proc "c" (dptr: ^Device_Ptr, bytesize: uint) -> i32,
	cuMemFree_v2:                  proc "c" (dptr: Device_Ptr) -> i32,
	cuMemcpyHtoD_v2:               proc "c" (dst: Device_Ptr, src: rawptr, n: uint) -> i32,
	cuMemcpyDtoH_v2:               proc "c" (dst: rawptr, src: Device_Ptr, n: uint) -> i32,
	cuMemAllocHost_v2:             proc "c" (pp: ^rawptr, bytesize: uint) -> i32,
	cuMemFreeHost:                 proc "c" (p: rawptr) -> i32,
	cuMemHostGetDevicePointer_v2:  proc "c" (pdptr: ^Device_Ptr, p: rawptr, flags: u32) -> i32,
	cuGetErrorString:              proc "c" (error: i32, pStr: ^cstring) -> i32,
	__handle:                      dynlib.Library,
}

// The CUDA driver library is loaded by its per-OS name: nvcuda.dll on Windows, libcuda.so.1
// on Linux. Same Driver API and same exported symbols either way (cuInit, cuCtxCreate_v2, …),
// so only the filename differs. Only linux and windows are targets.
CUDA_LIB :: "nvcuda.dll" when ODIN_OS == .Windows else "libcuda.so.1"

// cuda_available loads the CUDA driver and binds the driver API. Returns false (rather
// than crashing) when the driver is not present — the whole point of dlopen.
cuda_available :: proc(api: ^CUDA_API) -> bool {
	count, ok := dynlib.initialize_symbols(api, CUDA_LIB)
	return ok && count > 0
}

// Device_Info is what the probe reports: enough to identify the GPU and estimate,
// without creating a context or allocating anything.
Device_Info :: struct {
	present:    bool,
	name:       [256]u8,
	name_len:   int,
	cc_major:   int,
	cc_minor:   int,
	mp_count:   int,
	clock_khz:  int,
}

device_name :: proc(d: ^Device_Info) -> string {
	return string(d.name[:d.name_len])
}

// cuda_probe: dlopen → cuInit → device 0 attributes. No context, no allocation
// (invariant #2c: "--list-backends must report availability without committing to a
// device"). Returns present=false on any failure, gracefully.
cuda_probe :: proc() -> (info: Device_Info) {
	api: CUDA_API
	if !cuda_available(&api) {
		return
	}
	if api.cuInit(0) != CUDA_SUCCESS {
		return
	}
	count: i32
	if api.cuDeviceGetCount(&count) != CUDA_SUCCESS || count == 0 {
		return
	}
	dev: i32
	if api.cuDeviceGet(&dev, 0) != CUDA_SUCCESS {
		return
	}

	api.cuDeviceGetName(raw_data(info.name[:]), i32(len(info.name)), dev)
	n := 0
	for n < len(info.name) && info.name[n] != 0 {
		n += 1
	}
	info.name_len = n

	major, minor, mps, clk: i32
	api.cuDeviceGetAttribute(&major, ATTR_COMPUTE_CAPABILITY_MAJOR, dev)
	api.cuDeviceGetAttribute(&minor, ATTR_COMPUTE_CAPABILITY_MINOR, dev)
	api.cuDeviceGetAttribute(&mps, ATTR_MULTIPROCESSOR_COUNT, dev)
	api.cuDeviceGetAttribute(&clk, ATTR_CLOCK_RATE, dev)

	info.cc_major = int(major)
	info.cc_minor = int(minor)
	info.mp_count = int(mps)
	info.clock_khz = int(clk)
	info.present = true
	return
}

// err_string resolves a CUresult to its human string via the driver.
err_string :: proc(api: ^CUDA_API, code: i32) -> string {
	if api.cuGetErrorString == nil {
		return "?"
	}
	s: cstring
	api.cuGetErrorString(code, &s)
	return string(s)
}
