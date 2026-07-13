package vkbackend

// The Vulkan compute backend's loader + probe, mirroring cuda/dynlib.odin. The Vulkan
// loader (libvulkan.so.1 on Linux, vulkan-1.dll on Windows) is opened at RUNTIME via
// core:dynlib and its entry points are bound through vendor:vulkan's proc-pointer
// tables — never `foreign import`, which would make the whole binary refuse to start on
// a box with no Vulkan. If the loader is absent, the probe simply reports the backend
// unavailable (CLAUDE.md § backends, invariant #2c).
//
// vendor:vulkan exposes every entry point as a mutable proc-pointer *variable*, so
// load_proc_addresses_global(vkGetInstanceProcAddr) is all it takes to bind the loader —
// exactly the dlopen-friendly shape the invariant requires.

import "core:dynlib"
import vk "vendor:vulkan"

// Per-OS loader name. Only linux_{arm64,amd64} and windows_amd64 are supported targets.
@(private)
VULKAN_LIB :: "vulkan-1.dll" when ODIN_OS == .Windows else "libvulkan.so.1"

// Known PCI vendor IDs, for --list-backends readability.
VENDOR_AMD :: 0x1002
VENDOR_NVIDIA :: 0x10de
VENDOR_INTEL :: 0x8086

@(private)
g_lib: dynlib.Library
@(private)
g_loaded: bool

// vulkan_available loads the loader and binds the global-level entry points
// (vkCreateInstance, vkEnumerate*). Returns false gracefully when the loader is missing
// — the whole point of dlopen. Idempotent; the loader is bound once per process.
vulkan_available :: proc() -> bool {
	if g_loaded {
		return true
	}
	lib, ok := dynlib.load_library(VULKAN_LIB)
	if !ok {
		return false
	}
	gipa, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	if !found {
		return false
	}
	vk.load_proc_addresses_global(gipa)
	if vk.CreateInstance == nil {
		return false
	}
	g_lib = lib
	g_loaded = true
	return true
}

// Device_Info is what the probe reports: enough to identify the GPU without creating a
// logical device or allocating any memory (invariant #2c: "--list-backends must report
// availability without committing to a device").
Device_Info :: struct {
	present:      bool,
	name:         [256]u8,
	name_len:     int,
	vendor_id:    u32,
	is_discrete:  bool,
	device_count: int, // total Vulkan devices present (for "selected X of N" reporting)
	api_major:    int,
	api_minor:    int,
}

// device_type_score ranks physical devices so selection favors the fastest: a discrete
// GPU beats an integrated one beats a virtual one beats a CPU (lavapipe) beats unknown.
// Device type is the reliable "is this the fast one" signal across every real machine.
@(private)
device_type_score :: proc(t: vk.PhysicalDeviceType) -> int {
	#partial switch t {
	case .DISCRETE_GPU:
		return 4
	case .INTEGRATED_GPU:
		return 3
	case .VIRTUAL_GPU:
		return 2
	case .CPU:
		return 1
	}
	return 0
}

// select_device enumerates physical devices and returns the highest-scoring one (see
// device_type_score) plus the total count for reporting. The caller owns `inst`. This is
// the SINGLE selection point — the probe and the engine both call it, so what
// --list-backends reports is exactly what the engine will run on. Returns ok=false if no
// device is present. No logical device, no allocation.
@(private)
select_device :: proc(inst: vk.Instance) -> (best: vk.PhysicalDevice, count: u32, ok: bool) {
	if vk.EnumeratePhysicalDevices(inst, &count, nil) != .SUCCESS || count == 0 {
		return
	}
	devs: [16]vk.PhysicalDevice
	n := count
	if n > len(devs) {
		n = len(devs)
	}
	vk.EnumeratePhysicalDevices(inst, &n, raw_data(devs[:]))

	best_score := -1
	for i in 0 ..< n {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(devs[i], &props)
		if sc := device_type_score(props.deviceType); sc > best_score {
			best_score = sc
			best = devs[i]
		}
	}
	ok = true
	return
}

device_name :: proc(d: ^Device_Info) -> string {
	return string(d.name[:d.name_len])
}

vendor_name :: proc(vendor_id: u32) -> string {
	switch vendor_id {
	case VENDOR_AMD:
		return "AMD"
	case VENDOR_NVIDIA:
		return "NVIDIA"
	case VENDOR_INTEL:
		return "Intel"
	}
	return "GPU"
}

// vulkan_probe: load loader → create a throwaway instance → read device 0's properties →
// destroy the instance. No logical device, no VRAM. Returns present=false on any failure,
// gracefully. The instance is created only to enumerate; pApplicationInfo is nil (the
// loader treats that as Vulkan 1.0, which is all enumeration needs).
vulkan_probe :: proc() -> (info: Device_Info) {
	if !vulkan_available() {
		return
	}

	ci := vk.InstanceCreateInfo {
		sType = .INSTANCE_CREATE_INFO,
	}
	inst: vk.Instance
	if vk.CreateInstance(&ci, nil, &inst) != .SUCCESS {
		return
	}
	defer vk.DestroyInstance(inst, nil)
	vk.load_proc_addresses_instance(inst)

	// Report the device the engine would actually select (fastest by type), and how many
	// are present — so the operator sees the choice, never a silent pick.
	best, count, ok := select_device(inst)
	if !ok {
		return
	}
	info.device_count = int(count)
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(best, &props)

	n := 0
	for n < len(props.deviceName) && props.deviceName[n] != 0 {
		n += 1
	}
	copy(info.name[:], props.deviceName[:n])
	info.name_len = n
	info.vendor_id = props.vendorID
	info.is_discrete = props.deviceType == .DISCRETE_GPU
	info.api_major = int(props.apiVersion >> 22)
	info.api_minor = int((props.apiVersion >> 12) & 0x3ff)
	info.present = true
	return
}
