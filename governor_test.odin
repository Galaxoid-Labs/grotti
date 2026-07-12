package grotti

import "core:math"
import "core:testing"
import "core:time"

// --- slice allocation -------------------------------------------------------

@(test)
test_governor_uncapped :: proc(t: ^testing.T) {
	measured := []f64{1000, 2000, 3000}
	out := make([]f64, 3)
	defer delete(out)
	governor_slices(0, measured, out)
	for s in out {
		testing.expect_value(t, s, f64(0))
	}
}

@(test)
test_governor_equal_split_when_unmeasured :: proc(t: ^testing.T) {
	measured := []f64{0, 0, 0, 0}
	out := make([]f64, 4)
	defer delete(out)
	governor_slices(1_000_000, measured, out)
	for s in out {
		testing.expect(t, math.abs(s - 250_000) < 1e-6, "equal split of the cap")
	}
}

@(test)
test_governor_proportional :: proc(t: ^testing.T) {
	measured := []f64{1000, 3000} // 1:3
	out := make([]f64, 2)
	defer delete(out)
	governor_slices(800_000, measured, out)
	testing.expect(t, math.abs(out[0] - 200_000) < 1e-6, "1/4 share")
	testing.expect(t, math.abs(out[1] - 600_000) < 1e-6, "3/4 share")
	// Slices must sum to exactly the cap.
	testing.expect(t, math.abs((out[0] + out[1]) - 800_000) < 1e-6, "slices sum to cap")
}

// --- token bucket (pure, synthetic clock) -----------------------------------

@(test)
test_pacer_uncapped_never_sleeps :: proc(t: ^testing.T) {
	p: Pacer
	pacer_init(&p, 0) // uncapped
	testing.expect_value(t, pacer_advance(&p, 0, 1_000_000), i64(0))
	testing.expect_value(t, pacer_advance(&p, 1, 1_000_000), i64(0))
}

@(test)
test_pacer_steady_state :: proc(t: ^testing.T) {
	p: Pacer
	pacer_init(&p, 1000) // 1000 hashes/sec

	// First batch of 500 with no elapsed time: must sleep 0.5s (500/1000).
	sleep0 := pacer_advance(&p, 0, 500)
	testing.expect_value(t, sleep0, i64(500_000_000))

	// After sleeping to t=0.5s, the next identical batch sleeps another 0.5s.
	// Steady state: 500 hashes per 0.5s == exactly the 1000 h/s cap.
	sleep1 := pacer_advance(&p, 500_000_000, 500)
	testing.expect_value(t, sleep1, i64(500_000_000))
}

@(test)
test_pacer_burst_is_bounded :: proc(t: ^testing.T) {
	p: Pacer
	pacer_init(&p, 1000) // max_tokens = 1000 * 0.25 = 250

	// Prime last_ns at t=0.
	pacer_advance(&p, 0, 0)
	// Idle for 10s, then a small batch. Refill is capped at 250 tokens (not 10000),
	// so a 100-hash batch is covered with credit to spare and sleeps 0.
	sleep := pacer_advance(&p, 10_000_000_000, 100)
	testing.expect_value(t, sleep, i64(0))
	testing.expect(t, p.tokens <= 250 + 1e-6, "burst credit is capped at max_tokens")
}

// --- real-time: it actually caps (Test plan #5) -----------------------------

// Faithful to the spirit of the doc's 60s/5% test, compressed to keep CI fast:
// pace a stream of fake work at a fixed cap for ~1s and assert the achieved rate
// does not exceed the cap (the safety direction) and lands near it.
@(test)
test_pacer_caps_in_real_time :: proc(t: ^testing.T) {
	CAP :: f64(500_000) // hashes/sec
	BATCH :: u32(5_000) // ~10ms of sleep per batch at CAP: well above OS jitter

	p: Pacer
	pacer_init(&p, CAP)

	start := time.tick_now()
	total: u64
	for {
		pacer_pace(&p, BATCH)
		total += u64(BATCH)
		if time.duration_seconds(time.tick_diff(start, time.tick_now())) >= 1.0 {
			break
		}
	}
	elapsed := time.duration_seconds(time.tick_diff(start, time.tick_now()))
	rate := f64(total) / elapsed

	testing.expectf(t, rate <= CAP * 1.10, "must not exceed cap: %.0f h/s vs cap %.0f", rate, CAP)
	testing.expectf(t, rate >= CAP * 0.80, "should approach cap: %.0f h/s vs cap %.0f", rate, CAP)
}
