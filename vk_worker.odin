package grotti

// The Vulkan backend as a worker, peer to the CPU Menja workers and the CUDA GPU worker:
// it pulls jobs from the ring, launches the compute pipeline governed by its pacer, and
// drains hits into the same share queue. Fenja never knows which backend found a share.
//
// This is the near-twin of cuda_worker.odin (CUDA) — the two differ only in the engine
// they drive (vkbackend.Engine vs cuda.Engine). The SPIR-V is embedded (#load) so the
// binary is self-contained; the Vulkan loader itself is still dlopen'd at runtime
// (vulkan/dynlib.odin), so a box with no Vulkan runs fine.
//
// Like the CUDA worker, a fast GPU sweeps the whole 2^32 nonce space long before jobs
// change, so after each full sweep it ROLLS extranonce2 to a fresh coinbase rather than
// re-scanning the same space (which would resubmit duplicate shares).

import vkbackend "vulkan"
import "sha256d"
import "base:intrinsics"
import "core:encoding/endian"
import "core:fmt"
import "core:thread"
import "core:time"

@(private)
SPV := #load("vulkan/sha256d.spv")

// ~16.8M nonces per launch (~9 ms of GB10 work). Larger than CUDA's 2^22 because Vulkan's
// per-submit cost (record + fence round-trip) is heavier, so a bigger launch amortizes it —
// a launch-size sweep in vulkan/bench shows throughput climbing from ~1.68 to ~1.9 GH/s as
// the launch grows, plateauing here. Still small enough to stay responsive to new jobs/quit.
VK_LAUNCH :: u32(1) << 24

// VK_EN2_BASE keeps the Vulkan backend's extranonce2 stream disjoint from the CPU workers
// (ids 0..threads-1) AND the CUDA worker (id = threads). A wide separation means that even
// if a CUDA and a Vulkan backend run concurrently on different GPUs against the same job,
// their (en2, nonce) coverage never overlaps and no duplicate shares are submitted.
VK_EN2_BASE :: int(1) << 28

VK_Worker :: struct {
	id:     int, // extranonce2 base, disjoint from the CPU + CUDA workers
	ring:   ^Job_Ring,
	shares: ^Share_Queue,
	stats:  ^Stats,
	quit:   ^u32,
	pacer:  Pacer,
}

VK_Miner :: struct {
	worker: ^VK_Worker,
	thread: ^thread.Thread,
}

// vk_available reports whether a usable Vulkan device is present, without committing.
vk_available :: proc() -> bool {
	return vkbackend.vulkan_probe().present
}

// vk_mine_start spawns the Vulkan worker on its own thread (the device/queue are created
// on the launching thread). Shares the global quit.
vk_mine_start :: proc(ring: ^Job_Ring, shares: ^Share_Queue, st: ^Stats, id: int, cap_hps: f64, quit: ^u32) -> ^VK_Miner {
	m := new(VK_Miner)
	w := new(VK_Worker)
	w.id = id
	w.ring = ring
	w.shares = shares
	w.stats = st
	w.quit = quit
	pacer_init(&w.pacer, cap_hps)
	m.worker = w
	m.thread = thread.create(vk_thread_proc)
	m.thread.data = w
	thread.start(m.thread)
	return m
}

vk_mine_stop :: proc(m: ^VK_Miner) {
	intrinsics.atomic_store_explicit(m.worker.quit, 1, .Release)
	thread.join(m.thread)
	thread.destroy(m.thread)
	free(m.worker)
	free(m)
}

@(private)
vk_thread_proc :: proc(t: ^thread.Thread) {
	vk_worker_run(cast(^VK_Worker)t.data)
}

// vk_load_en2 encodes an extranonce2 value, rebuilds the header for it, folds the
// midstate, and uploads the job to the device.
@(private)
vk_load_en2 :: proc(e: ^vkbackend.Engine, job: ^Job, ctr: u32, en2: []u8, cb: []u8) -> Header {
	n := len(en2)
	for i in 0 ..< n {
		en2[i] = u8(ctr >> uint(8 * (n - 1 - i))) // big-endian
	}
	header := job_build_header(job, en2, cb)
	mid := sha256d.midstate(header[0:64])
	w0 := endian.unchecked_get_u32be(header[64:68])
	w1 := endian.unchecked_get_u32be(header[68:72])
	w2 := endian.unchecked_get_u32be(header[72:76])
	vkbackend.engine_load_job(e, mid, w0, w1, w2, job.target)
	return header
}

vk_worker_run :: proc(w: ^VK_Worker) {
	e: vkbackend.Engine
	if !vkbackend.engine_init_data(&e, SPV) {
		fmt.eprintln("vulkan: engine init failed; Vulkan worker exiting")
		return
	}
	defer vkbackend.engine_destroy(&e)

	coinbase_buf: [MAX_COINB1 + MAX_EN1 + MAX_EN2 + MAX_COINB2]u8
	hits: [4096]u32
	job: Job
	header: Header
	en2: [MAX_EN2]u8
	en2_len := 0
	en2_ctr: u32
	local_gen: u64 = 0
	nonce_base: u32 = 0
	have_work := false

	for intrinsics.atomic_load_explicit(w.quit, .Acquire) == 0 {
		g, ok := ring_load(w.ring, &job)
		if !ok {
			time.sleep(time.Millisecond)
			continue
		}

		if g != local_gen {
			local_gen = g
			en2_len = min(job.en2_size, MAX_EN2)
			en2_ctr = u32(w.id) // start this backend's en2 stream
			header = vk_load_en2(&e, &job, en2_ctr, en2[:en2_len], coinbase_buf[:])
			nonce_base = 0
			have_work = true
		}
		if !have_work {
			continue
		}

		n := vkbackend.engine_scan(&e, nonce_base, VK_LAUNCH, hits[:])
		for i in 0 ..< min(n, len(hits)) {
			sh: Share
			sh.gen = local_gen
			sh.ntime = job.ntime
			sh.nonce = hits[i]
			sh.is_block = is_block_nonce(header, hits[i], job.net_target)
			copy(sh.en2[:], en2[:en2_len])
			sh.en2_len = en2_len
			sh.id_len = job.id_len
			copy(sh.id[:], job.id[:job.id_len])
			if !share_enqueue(w.shares, sh) {
				stats_stale(w.stats)
			}
		}

		stats_add_hashes(w.stats, u64(VK_LAUNCH))

		old := nonce_base
		nonce_base += VK_LAUNCH
		if nonce_base < old { // swept the full 2^32 for this en2 → roll to a fresh coinbase
			en2_ctr += 1
			header = vk_load_en2(&e, &job, en2_ctr, en2[:en2_len], coinbase_buf[:])
			nonce_base = 0
		}

		pacer_pace(&w.pacer, VK_LAUNCH)
	}
}
