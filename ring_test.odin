package grotti

import "base:intrinsics"
import "core:testing"
import "core:thread"

@(test)
test_ring_basic :: proc(t: ^testing.T) {
	ring: Job_Ring
	j: Job

	_, ok := ring_load(&ring, &j)
	testing.expect(t, !ok, "no job before first publish")

	a: Job
	a.version = 100
	ring_publish(&ring, a)
	g, ok2 := ring_load(&ring, &j)
	testing.expect(t, ok2, "job available after publish")
	testing.expect_value(t, g, u64(1))
	testing.expect_value(t, j.version, u32(100))

	// Publish past a full wrap (>8) and confirm the latest is what's read.
	for k in 0 ..< 10 {
		c: Job
		c.version = u32(300 + k)
		ring_publish(&ring, c)
	}
	g2, _ := ring_load(&ring, &j)
	testing.expect_value(t, g2, u64(11))
	testing.expect_value(t, j.version, u32(309))
}

@(private = "file")
Ring_Ctx :: struct {
	ring:       Job_Ring,
	done:       u32, // atomic
	mismatches: u64, // atomic — a torn/inconsistent read (must stay 0)
	seen:       u64, // atomic — the consumer's most-recently-read generation
}

// No-tear, deterministically. A published Job is stamped so its fields cross-check
// (version == ntime, and prev[0:4] == version). The publisher is BOUNDED to stay
// within the ring's slot count of the consumer's progress (it waits until the
// consumer has read to within a couple of generations), so the slot being reused is
// never one a reader is still copying — regardless of how long the OS preempts a
// thread. This is exactly the ring's contract (DEVELOPMENT.md: a slot is not reused
// until N generations later, by which time no reader is on it), tested without
// depending on wall-clock timing.
@(test)
test_ring_concurrent_no_tear :: proc(t: ^testing.T) {
	ctx := new(Ring_Ctx)
	defer free(ctx)

	consumer :: proc(th: ^thread.Thread) {
		c := cast(^Ring_Ctx)th.data
		j: Job
		for intrinsics.atomic_load_explicit(&c.done, .Acquire) == 0 {
			g, ok := ring_load(&c.ring, &j)
			if !ok {
				continue
			}
			v := u32(j.prev[0]) | u32(j.prev[1]) << 8 | u32(j.prev[2]) << 16 | u32(j.prev[3]) << 24
			if j.version != j.ntime || v != j.version {
				intrinsics.atomic_add_explicit(&c.mismatches, 1, .Relaxed)
			}
			intrinsics.atomic_store_explicit(&c.seen, g, .Release)
		}
	}

	con := thread.create(consumer)
	con.data = ctx
	thread.start(con)

	for seq in u32(1) ..= 300_000 {
		// Stay within (SLOTS-1) generations of the consumer's last completed read, so
		// the slot we are about to overwrite (last written SLOTS generations ago) is
		// provably no longer being copied.
		for u64(seq) - intrinsics.atomic_load_explicit(&ctx.seen, .Acquire) >= JOB_RING_SLOTS - 1 {
			// spin: let the consumer catch up
		}
		job: Job
		job.version = seq
		job.ntime = seq
		job.prev[0] = u8(seq)
		job.prev[1] = u8(seq >> 8)
		job.prev[2] = u8(seq >> 16)
		job.prev[3] = u8(seq >> 24)
		ring_publish(&ctx.ring, job)
	}
	intrinsics.atomic_store_explicit(&ctx.done, 1, .Release)

	thread.join(con)
	thread.destroy(con)

	testing.expect_value(t, intrinsics.atomic_load_explicit(&ctx.mismatches, .Relaxed), u64(0))
	testing.expect(t, intrinsics.atomic_load_explicit(&ctx.seen, .Relaxed) > 0, "consumer made progress")
}
