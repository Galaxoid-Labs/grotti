package grotti

import "core:testing"
import "core:thread"

@(test)
test_stats_counters :: proc(t: ^testing.T) {
	s: Stats
	stats_init(&s)
	stats_add_hashes(&s, 1000)
	stats_add_hashes(&s, 500)
	stats_accepted(&s)
	stats_accepted(&s)
	stats_rejected(&s)

	snap := stats_snapshot(&s)
	testing.expect_value(t, snap.hashes, u64(1500))
	testing.expect_value(t, snap.accepted, u64(2))
	testing.expect_value(t, snap.rejected, u64(1))
}

@(test)
test_stats_acceptance_rate :: proc(t: ^testing.T) {
	snap := Snapshot{}
	testing.expect(t, stats_acceptance_rate(snap) == 1.0, "no shares yet => 1.0")
	snap.accepted = 3
	snap.rejected = 1
	testing.expect(t, stats_acceptance_rate(snap) == 0.75, "3 of 4 accepted")
}

// The stone runs across many threads; the hash counter must not lose an increment.
@(test)
test_stats_concurrent_hashes :: proc(t: ^testing.T) {
	s: Stats
	stats_init(&s)

	worker :: proc(th: ^thread.Thread) {
		st := cast(^Stats)th.data
		for _ in 0 ..< 100_000 {
			stats_add_hashes(st, 1)
		}
	}

	threads: [8]^thread.Thread
	for i in 0 ..< 8 {
		threads[i] = thread.create(worker)
		threads[i].data = &s
		thread.start(threads[i])
	}
	for i in 0 ..< 8 {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	snap := stats_snapshot(&s)
	testing.expect_value(t, snap.hashes, u64(800_000))
}
