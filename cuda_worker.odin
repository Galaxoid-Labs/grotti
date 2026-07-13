package grotti

// The CUDA backend as a worker, peer to the CPU Menja workers: it pulls jobs from the
// ring, launches the kernel governed by its pacer, and drains hits into the same
// share queue. Fenja never knows which backend found a share.
//
// The cubin is embedded (#load) so the binary is self-contained; the driver itself is
// still dlopen'd at runtime (cuda/dynlib.odin), so a GPU-less box runs fine.
//
// KEY DIFFERENCE from the CPU worker: the GB10 sweeps the whole 2^32 nonce space in
// ~1.7s — far faster than jobs change — so after each full sweep it must ROLL
// extranonce2 to a fresh coinbase. Re-scanning the same space would resubmit
// duplicate shares. (On the CPU, 2^32 takes minutes, so a job always changes first.)

import "cuda"
import "sha256d"
import "base:intrinsics"
import "core:encoding/endian"
import "core:fmt"
import "core:thread"
import "core:time"

@(private)
CUBIN := #load("cuda/kernel.cubin")

CUDA_LAUNCH :: u32(1) << 22 // ~4.2M nonces per launch; a few ms of GB10 work

CUDA_Worker :: struct {
	id:     int, // extranonce2 base, disjoint from the CPU workers
	ring:   ^Job_Ring,
	shares: ^Share_Queue,
	stats:  ^Stats,
	quit:   ^u32,
	pacer:  Pacer,
}

CUDA_Miner :: struct {
	worker: ^CUDA_Worker,
	thread: ^thread.Thread,
}

// cuda_available reports whether a usable CUDA device is present, without committing.
cuda_available :: proc() -> bool {
	return cuda.cuda_probe().present
}

// cuda_mine_start spawns the CUDA worker on its own thread (the CUDA context must be
// current on the launching thread, so init happens there). Shares the global quit.
cuda_mine_start :: proc(ring: ^Job_Ring, shares: ^Share_Queue, st: ^Stats, id: int, cap_hps: f64, quit: ^u32) -> ^CUDA_Miner {
	m := new(CUDA_Miner)
	w := new(CUDA_Worker)
	w.id = id
	w.ring = ring
	w.shares = shares
	w.stats = st
	w.quit = quit
	pacer_init(&w.pacer, cap_hps)
	m.worker = w
	m.thread = thread.create(cuda_thread_proc)
	m.thread.data = w
	thread.start(m.thread)
	return m
}

cuda_mine_stop :: proc(m: ^CUDA_Miner) {
	intrinsics.atomic_store_explicit(m.worker.quit, 1, .Release)
	thread.join(m.thread)
	thread.destroy(m.thread)
	free(m.worker)
	free(m)
}

@(private)
cuda_thread_proc :: proc(t: ^thread.Thread) {
	cuda_worker_run(cast(^CUDA_Worker)t.data)
}

// cuda_load_en2 encodes an extranonce2 value, rebuilds the header for it, folds the
// midstate, and uploads the job to the device.
@(private)
cuda_load_en2 :: proc(e: ^cuda.Engine, job: ^Job, ctr: u32, en2: []u8, cb: []u8) -> Header {
	n := len(en2)
	for i in 0 ..< n {
		en2[i] = u8(ctr >> uint(8 * (n - 1 - i))) // big-endian
	}
	header := job_build_header(job, en2, cb)
	mid := sha256d.midstate(header[0:64])
	w0 := endian.unchecked_get_u32be(header[64:68])
	w1 := endian.unchecked_get_u32be(header[68:72])
	w2 := endian.unchecked_get_u32be(header[72:76])
	cuda.engine_load_job(e, mid, w0, w1, w2, job.target)
	return header
}

cuda_worker_run :: proc(w: ^CUDA_Worker) {
	e: cuda.Engine
	if !cuda.engine_init_data(&e, CUBIN) {
		fmt.eprintln("cuda: engine init failed; CUDA worker exiting")
		return
	}
	defer cuda.engine_destroy(&e)

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
			header = cuda_load_en2(&e, &job, en2_ctr, en2[:en2_len], coinbase_buf[:])
			nonce_base = 0
			have_work = true
		}
		if !have_work {
			continue
		}

		n := cuda.engine_scan(&e, nonce_base, CUDA_LAUNCH, hits[:])
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

		stats_add_hashes(w.stats, u64(CUDA_LAUNCH))

		old := nonce_base
		nonce_base += CUDA_LAUNCH
		if nonce_base < old { // swept the full 2^32 for this en2 → roll to a fresh coinbase
			en2_ctr += 1
			header = cuda_load_en2(&e, &job, en2_ctr, en2[:en2_len], coinbase_buf[:])
			nonce_base = 0
		}

		pacer_pace(&w.pacer, CUDA_LAUNCH)
	}
}
