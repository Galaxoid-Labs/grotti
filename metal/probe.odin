#+build darwin
package metalbackend

// The Metal backend's probe, mirroring cuda/vulkan. Metal is a guaranteed macOS framework
// (no dlopen, no loader to be absent), so "availability" is simply: does the system have a
// default GPU device? On Apple Silicon there is exactly one GPU, so there is no
// discrete/integrated selection question (unlike Vulkan) — MTLCreateSystemDefaultDevice
// picks it. The probe creates and releases a throwaway device, allocating no compute
// resources, so --list-backends can report availability without committing (invariant #2c).

import MTL "vendor:darwin/Metal"
import NS "core:sys/darwin/Foundation"

// Device_Info is what the probe reports: enough to identify the GPU without building a
// pipeline or allocating any buffers.
Device_Info :: struct {
	present:      bool,
	name:         [256]u8,
	name_len:     int,
	max_threads:  int, // maxThreadsPerThreadgroup.width — a rough capability signal
	unified:      bool, // Apple Silicon reports hasUnifiedMemory
}

device_name :: proc(d: ^Device_Info) -> string {
	return string(d.name[:d.name_len])
}

// metal_probe: create the system default device, read its name, release it. Returns
// present=false gracefully when no Metal device is available (e.g. a headless VM with no
// GPU). No pipeline, no buffers.
metal_probe :: proc() -> (info: Device_Info) {
	pool := NS.scoped_autoreleasepool()

	dev := MTL.CreateSystemDefaultDevice()
	if dev == nil {
		return
	}
	defer dev->release()

	name := dev->name()->odinString()
	n := min(len(name), len(info.name))
	copy(info.name[:], name[:n])
	info.name_len = n
	info.max_threads = int(dev->maxThreadsPerThreadgroup().width)
	info.unified = dev->hasUnifiedMemory()
	info.present = true
	return
}
