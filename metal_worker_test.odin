#+build darwin
package grotti

import "core:encoding/endian"
import "core:strings"
import "core:testing"
import "core:time"

// End-to-end Metal engine test, the GPU twin of test_threaded_miner: publish one job, run
// the threaded Metal worker for a short window, then confirm it hashed and that EVERY share
// it produced is genuinely valid. This exercises the real backend on a spawned thread —
// device/pipeline bring-up, the per-scan autorelease pool, and the shared-buffer drain —
// which the on-main-thread kerneltest does not.
//
// Skips gracefully when there is no usable GPU: no Metal device at all (headless), OR a
// VIRTUALIZED device that reports present but can't run real compute. GitHub's hosted macOS
// runners expose an "Apple Paravirtual device" — MTLCreateSystemDefaultDevice() succeeds, but
// no dispatch completes in the window, so we detect that class of device by name and skip.
// On real Apple hardware (dev machines, self-hosted runners) the full test runs.
@(test)
test_metal_worker :: proc(t: ^testing.T) {
	info := metal_probe()
	if !info.present {
		return // headless CI with no GPU — nothing to prove here
	}
	name := metal_device_name(&info)
	if strings.contains(name, "Paravirtual") || strings.contains(name, "software") || strings.contains(name, "llvmpipe") {
		return // virtualized/software GPU (e.g. hosted macOS CI): present but can't mine
	}

	ring: Job_Ring
	shares: Share_Queue
	share_queue_init(&shares)
	st: Stats
	stats_init(&st)

	// Synthetic job off the block-125552 prefix, easy target (top byte zero, ~1/256) so
	// shares appear immediately — same fixture as the CPU worker test.
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
	m := metal_mine_start(&ring, &shares, &st, METAL_EN2_BASE, 0, &quit) // uncapped
	time.sleep(300 * time.Millisecond)
	metal_mine_stop(m)

	snap := stats_snapshot(&st)
	testing.expect(t, snap.hashes > 0, "Metal worker hashed")

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
	testing.expect(t, count > 0, "the Metal worker found at least one share")
}
