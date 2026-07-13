package grotti

// The threaded CPU engine: N Menja workers, each turning the stone on its own share
// of the nonce space, all fed by the job ring and all draining into one share queue
// (DEVELOPMENT.md § The shape). This is the Phase-4 concurrency the governor sits
// above — the cap is applied per-worker via each worker's pacer, never inside the
// scan.

import "base:intrinsics"
import "core:thread"
import "core:time"

// BATCH — one turn's worth of nonces between generation checks. Multiple of LANES.
// ~16k nonces is a few ms of work; the generation check is amortized to nothing.
BATCH :: 1 << 14

// Worker is one Menja thread's context. Its extranonce2 stream is its own id
// (en2 ≡ id, the disjoint partition), so no two workers ever hash the same header.
Worker :: struct {
	id:     int,
	ring:   ^Job_Ring,
	shares: ^Share_Queue,
	stats:  ^Stats,
	quit:   ^u32, // atomic, shared across workers
	pacer:  Pacer, // this worker's slice of the global cap
}

Miner :: struct {
	quit:    ^u32, // atomic, shared with Fenja so one flag stops the whole process
	workers: []Worker,
	threads: []^thread.Thread,
}

// mine_start spawns n_workers Menja threads at once, dividing the global cap equally
// among them (CPU workers are identical, so an equal split lands the total on
// cap_hps; cap_hps <= 0 is uncapped). `quit` is an external atomic flag shared with
// Fenja. Returns a handle to stop them.
mine_start :: proc(ring: ^Job_Ring, shares: ^Share_Queue, st: ^Stats, n_workers: int, cap_hps: f64, quit: ^u32) -> ^Miner {
	m := new(Miner)
	m.quit = quit
	m.workers = make([]Worker, n_workers)
	m.threads = make([]^thread.Thread, n_workers)
	slice := cap_hps <= 0 ? 0 : cap_hps / f64(n_workers)

	for i in 0 ..< n_workers {
		w := &m.workers[i]
		w.id = i
		w.ring = ring
		w.shares = shares
		w.stats = st
		w.quit = quit
		pacer_init(&w.pacer, slice)

		th := thread.create(worker_thread_proc)
		th.data = w
		m.threads[i] = th
		thread.start(th)
	}
	return m
}

// mine_stop signals shutdown and joins every worker. A worker checks the quit flag at
// the top of each turn, so it exits within one batch (~ms).
mine_stop :: proc(m: ^Miner) {
	intrinsics.atomic_store_explicit(m.quit, 1, .Release)
	for th in m.threads {
		thread.join(th)
		thread.destroy(th)
	}
	delete(m.threads)
	delete(m.workers)
	free(m)
}

@(private)
worker_thread_proc :: proc(th: ^thread.Thread) {
	menja_worker_run(cast(^Worker)th.data)
}

// menja_worker_run is the per-thread loop. All buffers are stack-local and reused —
// no allocation in the loop (invariant #3). Its only syscalls are the pacer's sleep
// (when throttling) and a short sleep while waiting for the first job.
menja_worker_run :: proc(w: ^Worker) {
	coinbase_buf: [MAX_COINB1 + MAX_EN1 + MAX_EN2 + MAX_COINB2]u8
	hits: [256]u32
	job: Job
	header: Header
	en2: [MAX_EN2]u8
	en2_len := 0
	local_gen: u64 = 0
	nonce_base: u32 = 0
	have_work := false

	for intrinsics.atomic_load_explicit(w.quit, .Acquire) == 0 {
		g, ok := ring_load(w.ring, &job)
		if !ok {
			time.sleep(time.Millisecond) // no job published yet
			continue
		}

		if g != local_gen {
			// New job: claim this worker's en2 (its id, big-endian) and rebuild the
			// header template. The nonce space per en2 is never exhausted before the
			// next job, so one en2 per job is enough (en2 rolling is a backstop).
			local_gen = g
			en2_len = min(job.en2_size, MAX_EN2)
			for i in 0 ..< en2_len {
				en2[i] = u8(u32(w.id) >> uint(8 * (en2_len - 1 - i)))
			}
			header = job_build_header(&job, en2[:en2_len], coinbase_buf[:])
			nonce_base = 0
			have_work = true
		}
		if !have_work {
			continue
		}

		n := scan_simd(&header, job.target, nonce_base, BATCH, hits[:])
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
				stats_stale(w.stats) // queue full: drop and count, never block
			}
			// accepted/rejected is Fenja's to record on the pool's response, not here.
		}

		stats_add_hashes(w.stats, u64(BATCH))
		nonce_base += BATCH // wraps at 2^32; batches tile it exactly
		pacer_pace(&w.pacer, BATCH, w.quit)
	}
}
