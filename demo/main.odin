package main

// Live demo of the real threaded engine: the ring, N Menja workers, the governor,
// the share queue and the console — actually mining a synthetic job, governed to a
// cap, with a live status line.  odin run demo
//
// Status output is TTY-aware (per CLAUDE.md § Console output): a repainting line on a
// terminal, plain heartbeat lines when piped.

import grotti ".."
import "core:fmt"
import "core:strings"
import "core:time"

hex32 :: proc(s: string) -> (out: [32]u8) {
	nib :: proc(c: u8) -> u8 {
		switch {
		case c >= '0' && c <= '9':
			return c - '0'
		case c >= 'a' && c <= 'f':
			return c - 'a' + 10
		}
		return 0
	}
	b := transmute([]u8)s
	for i in 0 ..< 32 {
		out[i] = (nib(b[i * 2]) << 4) | nib(b[i * 2 + 1])
	}
	return
}

main :: proc() {
	c := grotti.console_init(.Auto)

	NET :: 800_000.0
	CAP :: 500_000.0 // 0.62x network — governed, safe
	WORKERS :: 4

	fmt.println("grotti 0.1.0  ·  backend=cpu  ·  (demo: synthetic job, no pool)")
	fmt.println()
	sb := strings.builder_make();defer strings.builder_destroy(&sb)
	grotti.format_safety_block(&sb, c, NET, 0.56, CAP, 8.41e6 * WORKERS)
	fmt.print(strings.to_string(sb))
	fmt.println()

	// Wiring.
	ring: grotti.Job_Ring
	shares: grotti.Share_Queue
	grotti.share_queue_init(&shares)
	st: grotti.Stats
	grotti.stats_init(&st)

	// A synthetic job with a moderate target (top 2 bytes zero) so shares trickle in.
	job: grotti.Job
	job.version = 1
	job.prev = grotti.reverse32(hex32("00000000000008a3a41b85b8b29ad444def299fee21793cd8b9e567eab02cd81"))
	job.ntime = 1305998791
	job.nbits = 0x1A44B9F2
	job.coinb1[0] = 0x01;job.coinb1_len = 1
	job.en1[0] = 0xAB;job.en1_len = 1
	job.coinb2[0] = 0xEF;job.coinb2_len = 1
	job.en2_size = 4
	for i in 2 ..< 32 {
		job.target[i] = 0xFF
	}
	grotti.ring_publish(&ring, job)

	quit: u32
	m := grotti.mine_start(&ring, &shares, &st, WORKERS, CAP, &quit)

	sampler: grotti.Rate_Sampler
	grotti.rate_sampler_init(&sampler, &st)

	for tick in 0 ..< 12 { // ~3 seconds
		time.sleep(250 * time.Millisecond)
		hps := grotti.rate_sample(&sampler, &st)
		snap := grotti.stats_snapshot(&st)

		line := strings.builder_make();defer strings.builder_destroy(&line)
		grotti.format_status(&line, c, snap, hps, grotti.job_id(&job))
		if c.tty {
			fmt.print("\r", strings.to_string(line))
		} else {
			fmt.println(strings.to_string(line))
		}
	}
	fmt.println()

	grotti.mine_stop(m)

	// Drain whatever shares the queue still holds and report.
	found := 0
	for {
		_, ok := grotti.share_dequeue(&shares)
		if !ok {
			break
		}
		found += 1
	}
	snap := grotti.stats_snapshot(&st)
	fmt.printf(
		"\nstopped — %.0f total hashes, avg %.0f H/s, %d shares queued (%d dropped when full)\n",
		f64(snap.hashes),
		snap.avg_hps,
		found,
		snap.stale,
	)
}
