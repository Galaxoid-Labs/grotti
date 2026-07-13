package vkbackend

// Host driver for the Vulkan compute hasher: create a device with a compute queue, build
// a pipeline from the embedded SPIR-V, and launch the scan. Self-contained — it takes raw
// header foldings and a target, so `grotti` depends on `vkbackend` and never the reverse.
// The governor stays ABOVE this, in grotti; this engine's only job is "scan this nonce
// range, report every hit" (CLAUDE.md § 2b). The public API mirrors cuda.Engine 1:1 so
// the worker glue in package grotti can be a near-copy of gpu_worker.odin.
//
// Memory model: buffers are HOST_VISIBLE|HOST_COHERENT and persistently mapped. On the
// GB10 (a unified-memory SoC that reports as an integrated GPU) that is also device-local,
// so there are no staging copies. A COMPUTE_SHADER→HOST memory barrier after each dispatch
// makes the hits visible to the mapped pointer on any driver, not just a coherent one.

import vk "vendor:vulkan"

// Push constants carry the whole job + launch params: 22 u32 = 88 bytes, under the
// guaranteed 128-byte maxPushConstantsSize. The field order and packing MUST match the
// std430 `Push` block in sha256d.comp (all u32 → tight 4-byte stride, no padding).
Push_Constants :: struct {
	midstate:    [8]u32, // sha256 state after header[0:64]
	w0:          u32, // }
	w1:          u32, // }  constant block-B words (be of header[64:76])
	w2:          u32, // }
	target:      [8]u32, // target as 8 big-endian words (display order)
	start_nonce: u32,
	count:       u32,
	max_hits:    u32,
}
#assert(size_of(Push_Constants) == 88)

Engine :: struct {
	instance:     vk.Instance,
	phys:         vk.PhysicalDevice,
	device:       vk.Device,
	queue:        vk.Queue,
	queue_family: u32,
	cmd_pool:     vk.CommandPool,
	cmd:          vk.CommandBuffer,
	fence:        vk.Fence,
	desc_layout:  vk.DescriptorSetLayout,
	pipe_layout:  vk.PipelineLayout,
	pipeline:     vk.Pipeline,
	shader:       vk.ShaderModule,
	desc_pool:    vk.DescriptorPool,
	desc_set:     vk.DescriptorSet,
	hits_buf:     vk.Buffer,
	hits_mem:     vk.DeviceMemory,
	hits_ptr:     rawptr, // persistently mapped
	count_buf:    vk.Buffer,
	count_mem:    vk.DeviceMemory,
	count_ptr:    rawptr, // persistently mapped u32 atomic counter
	max_hits:     u32,
	push:         Push_Constants,
}

@(private)
find_mem_type :: proc(e: ^Engine, type_bits: u32, want: vk.MemoryPropertyFlags) -> (u32, bool) {
	mp: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(e.phys, &mp)
	for i in 0 ..< mp.memoryTypeCount {
		if type_bits & (1 << i) != 0 && (mp.memoryTypes[i].propertyFlags & want) == want {
			return i, true
		}
	}
	return 0, false
}

@(private)
make_buffer :: proc(
	e: ^Engine,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
) -> (
	buf: vk.Buffer,
	mem: vk.DeviceMemory,
	ptr: rawptr,
	ok: bool,
) {
	bci := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	if vk.CreateBuffer(e.device, &bci, nil, &buf) != .SUCCESS {
		return
	}
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(e.device, buf, &req)
	mt, found := find_mem_type(e, req.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT})
	if !found {
		return
	}
	mai := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = mt,
	}
	if vk.AllocateMemory(e.device, &mai, nil, &mem) != .SUCCESS {
		return
	}
	if vk.BindBufferMemory(e.device, buf, mem, 0) != .SUCCESS {
		return
	}
	if vk.MapMemory(e.device, mem, 0, size, {}, &ptr) != .SUCCESS {
		return
	}
	ok = true
	return
}

// engine_init_data brings up the device and pipeline from an in-memory SPIR-V image (the
// binary embeds it via #load, so there is no separate file to ship). Mirrors
// cuda.engine_init_data. Returns false on any failure, leaving a destroyable Engine.
engine_init_data :: proc(e: ^Engine, spv: []u8, max_hits: u32 = 4096) -> bool {
	if !vulkan_available() {
		return false
	}
	e.max_hits = max_hits

	// Instance (no layers/extensions — headless compute needs none).
	ici := vk.InstanceCreateInfo {
		sType = .INSTANCE_CREATE_INFO,
	}
	if vk.CreateInstance(&ici, nil, &e.instance) != .SUCCESS {
		return false
	}
	vk.load_proc_addresses_instance(e.instance)

	// Fastest available physical device (discrete > integrated > virtual > cpu), chosen by
	// the same selector the probe reports — so what --list-backends showed is what runs.
	best, _, ok_dev := select_device(e.instance)
	if !ok_dev {
		return false
	}
	e.phys = best

	// A compute-capable queue family.
	qf_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(e.phys, &qf_count, nil)
	qfs: [32]vk.QueueFamilyProperties
	if qf_count > len(qfs) {
		qf_count = len(qfs)
	}
	vk.GetPhysicalDeviceQueueFamilyProperties(e.phys, &qf_count, raw_data(qfs[:]))
	found_q := false
	for i in 0 ..< qf_count {
		if .COMPUTE in qfs[i].queueFlags {
			e.queue_family = i
			found_q = true
			break
		}
	}
	if !found_q {
		return false
	}

	// Logical device + queue.
	prio: f32 = 1.0
	qci := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = e.queue_family,
		queueCount       = 1,
		pQueuePriorities = &prio,
	}
	dci := vk.DeviceCreateInfo {
		sType                = .DEVICE_CREATE_INFO,
		queueCreateInfoCount = 1,
		pQueueCreateInfos    = &qci,
	}
	if vk.CreateDevice(e.phys, &dci, nil, &e.device) != .SUCCESS {
		return false
	}
	vk.load_proc_addresses_device(e.device)
	vk.GetDeviceQueue(e.device, e.queue_family, 0, &e.queue)

	// Buffers: hits[max_hits] + a single u32 counter.
	ok: bool
	e.hits_buf, e.hits_mem, e.hits_ptr, ok = make_buffer(e, vk.DeviceSize(max_hits) * 4, {.STORAGE_BUFFER})
	if !ok {
		return false
	}
	e.count_buf, e.count_mem, e.count_ptr, ok = make_buffer(e, 4, {.STORAGE_BUFFER})
	if !ok {
		return false
	}

	// Descriptor set layout: binding 0 = hits, binding 1 = count.
	bindings := [2]vk.DescriptorSetLayoutBinding {
		{binding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
		{binding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
	}
	dslci := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 2,
		pBindings    = raw_data(bindings[:]),
	}
	if vk.CreateDescriptorSetLayout(e.device, &dslci, nil, &e.desc_layout) != .SUCCESS {
		return false
	}

	// Pipeline layout: the descriptor set + the 88-byte push-constant range.
	pcr := vk.PushConstantRange {
		stageFlags = {.COMPUTE},
		offset     = 0,
		size       = size_of(Push_Constants),
	}
	plci := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &e.desc_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &pcr,
	}
	if vk.CreatePipelineLayout(e.device, &plci, nil, &e.pipe_layout) != .SUCCESS {
		return false
	}

	// Shader module + compute pipeline.
	smci := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spv),
		pCode    = cast(^u32)raw_data(spv),
	}
	if vk.CreateShaderModule(e.device, &smci, nil, &e.shader) != .SUCCESS {
		return false
	}
	cpci := vk.ComputePipelineCreateInfo {
		sType = .COMPUTE_PIPELINE_CREATE_INFO,
		stage = {
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.COMPUTE},
			module = e.shader,
			pName = "main",
		},
		layout = e.pipe_layout,
	}
	if vk.CreateComputePipelines(e.device, 0, 1, &cpci, nil, &e.pipeline) != .SUCCESS {
		return false
	}

	// Descriptor pool + set, wired to the two buffers (updated once).
	psize := vk.DescriptorPoolSize {
		type            = .STORAGE_BUFFER,
		descriptorCount = 2,
	}
	dpci := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = 1,
		pPoolSizes    = &psize,
	}
	if vk.CreateDescriptorPool(e.device, &dpci, nil, &e.desc_pool) != .SUCCESS {
		return false
	}
	dsai := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = e.desc_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &e.desc_layout,
	}
	if vk.AllocateDescriptorSets(e.device, &dsai, &e.desc_set) != .SUCCESS {
		return false
	}
	hits_info := vk.DescriptorBufferInfo {
		buffer = e.hits_buf,
		offset = 0,
		range  = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	count_info := vk.DescriptorBufferInfo {
		buffer = e.count_buf,
		offset = 0,
		range  = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	writes := [2]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = e.desc_set,
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &hits_info,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = e.desc_set,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &count_info,
		},
	}
	vk.UpdateDescriptorSets(e.device, 2, raw_data(writes[:]), 0, nil)

	// Command pool (resettable — we re-record per scan) + buffer + fence.
	cpci2 := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = e.queue_family,
	}
	if vk.CreateCommandPool(e.device, &cpci2, nil, &e.cmd_pool) != .SUCCESS {
		return false
	}
	cbai := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = e.cmd_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if vk.AllocateCommandBuffers(e.device, &cbai, &e.cmd) != .SUCCESS {
		return false
	}
	fci := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	if vk.CreateFence(e.device, &fci, nil, &e.fence) != .SUCCESS {
		return false
	}
	return true
}

// engine_load_job stores the folded job in the push-constant payload: the midstate over
// header[0:64], the three constant block-B words, and the target as 8 big-endian words.
// No GPU call — the payload is pushed at dispatch time. Mirrors cuda.engine_load_job.
engine_load_job :: proc(e: ^Engine, midstate: [8]u32, w0, w1, w2: u32, target: [32]u8) -> bool {
	e.push.midstate = midstate
	e.push.w0 = w0
	e.push.w1 = w1
	e.push.w2 = w2
	for i in 0 ..< 8 {
		e.push.target[i] =
			u32(target[i * 4]) << 24 |
			u32(target[i * 4 + 1]) << 16 |
			u32(target[i * 4 + 2]) << 8 |
			u32(target[i * 4 + 3])
	}
	return true
}

// engine_scan launches the kernel over [start, start+count) and drains the hits. Returns
// the TOTAL hit count (which may exceed len(hits) — the kernel counts all, the host keeps
// up to len(hits)). Mirrors cuda.engine_scan.
engine_scan :: proc(e: ^Engine, start: u32, count: u32, hits: []u32) -> int {
	e.push.start_nonce = start
	e.push.count = count
	e.push.max_hits = e.max_hits

	// Reset the counter via the mapped coherent buffer; queue submission makes this host
	// write visible to the device for this batch.
	(cast(^u32)e.count_ptr)^ = 0

	vk.ResetCommandBuffer(e.cmd, {})
	bi := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(e.cmd, &bi)
	vk.CmdBindPipeline(e.cmd, .COMPUTE, e.pipeline)
	vk.CmdBindDescriptorSets(e.cmd, .COMPUTE, e.pipe_layout, 0, 1, &e.desc_set, 0, nil)
	vk.CmdPushConstants(e.cmd, e.pipe_layout, {.COMPUTE}, 0, size_of(Push_Constants), &e.push)
	groups := (count + 255) / 256
	vk.CmdDispatch(e.cmd, groups, 1, 1)

	// Make the shader's writes to hits/count available and visible to a host read.
	mb := vk.MemoryBarrier {
		sType         = .MEMORY_BARRIER,
		srcAccessMask = {.SHADER_WRITE},
		dstAccessMask = {.HOST_READ},
	}
	vk.CmdPipelineBarrier(e.cmd, {.COMPUTE_SHADER}, {.HOST}, {}, 1, &mb, 0, nil, 0, nil)
	vk.EndCommandBuffer(e.cmd)

	si := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &e.cmd,
	}
	if vk.QueueSubmit(e.queue, 1, &si, e.fence) != .SUCCESS {
		return 0
	}
	vk.WaitForFences(e.device, 1, &e.fence, true, ~u64(0))
	vk.ResetFences(e.device, 1, &e.fence)

	n := (cast(^u32)e.count_ptr)^
	take := min(n, e.max_hits)
	if take > 0 && len(hits) > 0 {
		want := min(int(take), len(hits))
		src := cast([^]u32)e.hits_ptr
		for i in 0 ..< want {
			hits[i] = src[i]
		}
	}
	return int(n)
}

engine_destroy :: proc(e: ^Engine) {
	if e.device != nil {
		vk.DeviceWaitIdle(e.device)
		if e.fence != 0 do vk.DestroyFence(e.device, e.fence, nil)
		if e.cmd_pool != 0 do vk.DestroyCommandPool(e.device, e.cmd_pool, nil)
		if e.desc_pool != 0 do vk.DestroyDescriptorPool(e.device, e.desc_pool, nil)
		if e.pipeline != 0 do vk.DestroyPipeline(e.device, e.pipeline, nil)
		if e.shader != 0 do vk.DestroyShaderModule(e.device, e.shader, nil)
		if e.pipe_layout != 0 do vk.DestroyPipelineLayout(e.device, e.pipe_layout, nil)
		if e.desc_layout != 0 do vk.DestroyDescriptorSetLayout(e.device, e.desc_layout, nil)
		if e.hits_mem != 0 do vk.FreeMemory(e.device, e.hits_mem, nil)
		if e.hits_buf != 0 do vk.DestroyBuffer(e.device, e.hits_buf, nil)
		if e.count_mem != 0 do vk.FreeMemory(e.device, e.count_mem, nil)
		if e.count_buf != 0 do vk.DestroyBuffer(e.device, e.count_buf, nil)
		vk.DestroyDevice(e.device, nil)
	}
	if e.instance != nil {
		vk.DestroyInstance(e.instance, nil)
	}
}
