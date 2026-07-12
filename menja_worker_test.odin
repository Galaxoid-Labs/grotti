package grotti

import "core:encoding/endian"
import "core:testing"
import "core:time"

// End-to-end engine test: publish one job, run the threaded miner for a short window,
// then confirm it hashed and that EVERY share it produced is genuinely valid — the
// right nonce/en2 really does hash below the target. This exercises the whole stack
// concurrently: ring → per-worker en2 → header build → SIMD scan → share queue.
@(test)
test_threaded_miner :: proc(t: ^testing.T) {
	ring: Job_Ring
	shares: Share_Queue
	share_queue_init(&shares)
	st: Stats
	stats_init(&st)

	// Synthetic job off the block-125552 prefix, with an easy target (top byte zero,
	// ~1/256) so shares appear quickly.
	job: Job
	job.version = B125552_VERSION
	job.prev = reverse32(hex32(B125552_PREV))
	job.ntime = B125552_NTIME
	job.nbits = B125552_NBITS
	job.coinb1[0] = 0x01;job.coinb1[1] = 0x02;job.coinb1_len = 2
	job.en1[0] = 0xAB;job.en1[1] = 0xCD;job.en1_len = 2
	job.coinb2[0] = 0xEF;job.coinb2_len = 1
	job.en2_size = 4
	job.n_branches = 0
	for i in 1 ..< 32 {
		job.target[i] = 0xFF
	}
	ring_publish(&ring, job)

	quit: u32
	m := mine_start(&ring, &shares, &st, 2, 0, &quit) // 2 workers, uncapped
	time.sleep(300 * time.Millisecond)
	mine_stop(m)

	snap := stats_snapshot(&st)
	testing.expect(t, snap.hashes > 0, "workers hashed")

	// Every queued share must reconstruct to a header that beats the target.
	count := 0
	for {
		sh, ok := share_dequeue(&shares)
		if !ok {
			break
		}
		count += 1
		buf: [64]u8
		h := job_build_header(&job, sh.en2[:sh.en2_len], buf[:])
		endian.unchecked_put_u32le(h[76:80], sh.nonce)
		testing.expect(t, hash_meets_target(block_hash(h), job.target), "each produced share is valid")
	}
	testing.expect(t, count > 0, "the miner found at least one share")

	// The two workers own distinct en2 streams (0 and 1) — no overlapping search.
	testing.expect(t, snap.hashes >= 2 * BATCH, "both workers took at least one turn")
}
