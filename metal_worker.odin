#+build darwin
package grotti

// The Metal backend as a worker, peer to the CPU Menja workers and the CUDA/Vulkan GPU
// workers: it pulls jobs from the ring, launches the compute pipeline governed by its
// pacer, and drains hits into the same share queue. Fenja never knows which backend found
// a share.
//
// This is the near-twin of vk_worker.odin (Vulkan) and cuda_worker.odin (CUDA) — the three
// differ only in the engine they drive. The MSL source is embedded (#load) and compiled at
// runtime, so the binary is self-contained; Metal.framework is linked directly (it is a
// guaranteed macOS framework), so there is no loader to be absent. This file is
// #+build darwin; metal_worker_stub.odin provides the same symbols elsewhere so package
// grotti stays portable.
//
// Like the other GPU workers, a fast GPU sweeps the whole 2^32 nonce space long before jobs
// change, so after each full sweep it ROLLS extranonce2 to a fresh coinbase rather than
// re-scanning the same space (which would resubmit duplicate shares).

import metalbackend "metal"
import "sha256d"
import "base:intrinsics"
import "core:encoding/endian"
import "core:fmt"
import "core:thread"
import "core:time"

@(private)
MSL := #load("metal/sha256d.metal")

// ~4.2M nonces per launch (~19 ms on an M1 Max at ~0.22 GH/s). metal/bench shows throughput
// is FLAT from 2^22 up to 2^27 — the kernel is compute-bound, not dispatch-bound — so a
// smaller launch costs nothing and keeps the worker responsive to new jobs and quit.
METAL_LAUNCH :: u32(1) << 22

// METAL_EN2_BASE keeps the Metal backend's extranonce2 stream widely separated from the CPU
// workers (ids 0..threads-1), the CUDA worker (id = threads), and the Vulkan backend
// (VK_EN2_BASE = 1<<28). Metal never coexists with CUDA/Vulkan in one binary (different OS),
// but a disjoint base is consistent and harmless.
METAL_EN2_BASE :: int(1) << 29

// Metal_Info mirrors what --list-backends / the startup banner reports, so package main
// never imports the platform-specific metal package (which does not exist off darwin).
Metal_Info :: struct {
	present:     bool,
	name:        [256]u8,
	name_len:    int,
	unified:     bool,
	max_threads: int,
}

metal_device_name :: proc(i: ^Metal_Info) -> string {
	return string(i.name[:i.name_len])
}

// metal_probe reports the Apple GPU without committing any compute resources.
metal_probe :: proc() -> (out: Metal_Info) {
	info := metalbackend.metal_probe()
	if !info.present {
		return
	}
	out.present = true
	out.name_len = min(info.name_len, len(out.name))
	copy(out.name[:], info.name[:out.name_len])
	out.unified = info.unified
	out.max_threads = info.max_threads
	return
}

METAL_Worker :: struct {
	id:     int, // extranonce2 base, disjoint from the CPU + CUDA + Vulkan workers
	ring:   ^Job_Ring,
	shares: ^Share_Queue,
	stats:  ^Stats,
	quit:   ^u32,
	pacer:  Pacer,
}

METAL_Miner :: struct {
	worker: ^METAL_Worker,
	thread: ^thread.Thread,
}

// metal_available reports whether a usable Metal device is present, without committing.
metal_available :: proc() -> bool {
	return metalbackend.metal_probe().present
}

// metal_mine_start spawns the Metal worker on its own thread (the device/queue are created
// on the launching thread). Shares the global quit.
metal_mine_start :: proc(ring: ^Job_Ring, shares: ^Share_Queue, st: ^Stats, id: int, cap_hps: f64, quit: ^u32) -> ^METAL_Miner {
	m := new(METAL_Miner)
	w := new(METAL_Worker)
	w.id = id
	w.ring = ring
	w.shares = shares
	w.stats = st
	w.quit = quit
	pacer_init(&w.pacer, cap_hps)
	m.worker = w
	m.thread = thread.create(metal_thread_proc)
	m.thread.data = w
	thread.start(m.thread)
	return m
}

metal_mine_stop :: proc(m: ^METAL_Miner) {
	intrinsics.atomic_store_explicit(m.worker.quit, 1, .Release)
	thread.join(m.thread)
	thread.destroy(m.thread)
	free(m.worker)
	free(m)
}

@(private)
metal_thread_proc :: proc(t: ^thread.Thread) {
	metal_worker_run(cast(^METAL_Worker)t.data)
}

// metal_load_en2 encodes an extranonce2 value, rebuilds the header for it, folds the
// midstate, and uploads the job to the device.
@(private)
metal_load_en2 :: proc(e: ^metalbackend.Engine, job: ^Job, ctr: u32, en2: []u8, cb: []u8) -> Header {
	n := len(en2)
	for i in 0 ..< n {
		en2[i] = u8(ctr >> uint(8 * (n - 1 - i))) // big-endian
	}
	header := job_build_header(job, en2, cb)
	mid := sha256d.midstate(header[0:64])
	w0 := endian.unchecked_get_u32be(header[64:68])
	w1 := endian.unchecked_get_u32be(header[68:72])
	w2 := endian.unchecked_get_u32be(header[72:76])
	metalbackend.engine_load_job(e, mid, w0, w1, w2, job.target)
	return header
}

metal_worker_run :: proc(w: ^METAL_Worker) {
	e: metalbackend.Engine
	if !metalbackend.engine_init_source(&e, string(MSL)) {
		fmt.eprintln("metal: engine init failed; Metal worker exiting")
		return
	}
	defer metalbackend.engine_destroy(&e)

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
			header = metal_load_en2(&e, &job, en2_ctr, en2[:en2_len], coinbase_buf[:])
			nonce_base = 0
			have_work = true
		}
		if !have_work {
			continue
		}

		n := metalbackend.engine_scan(&e, nonce_base, METAL_LAUNCH, hits[:])
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

		stats_add_hashes(w.stats, u64(METAL_LAUNCH))

		old := nonce_base
		nonce_base += METAL_LAUNCH
		if nonce_base < old { // swept the full 2^32 for this en2 → roll to a fresh coinbase
			en2_ctr += 1
			header = metal_load_en2(&e, &job, en2_ctr, en2[:en2_len], coinbase_buf[:])
			nonce_base = 0
		}

		pacer_pace(&w.pacer, METAL_LAUNCH, w.quit)
	}
}
