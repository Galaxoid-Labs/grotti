package grotti

// The global hashrate cap — chain safety as a runtime number (CLAUDE.md § 2, § 2b;
// DEVELOPMENT.md § The governor). This sits ABOVE the backend seam and is never
// reimplemented per-backend.
//
// It PACES, it does not de-thread: every worker runs at full width, and each owns a
// token bucket that gates how often it takes a turn. The global cap is divided into
// per-worker slices (proportional to measured throughput), so the sum of what the
// workers do converges to cap_hps with no shared atomic on the hot path.
//
// The token-bucket math (pacer_advance) is a pure function of state + clock + work,
// separated from the effect (the sleep) so it can be proven to cap deterministically
// (Test plan #5) without a real-time run.

import "base:intrinsics"
import "core:time"

// Governor holds the one global cap. cap_hps == 0 is UNCAPPED — a first-class mode
// (DEVELOPMENT.md: "--cap=0 is uncapped and fully supported"), not a sentinel hack.
Governor :: struct {
	cap_hps: f64,
}

// governor_slices divides the global cap among workers in proportion to their
// measured throughput, writing one rate slice per worker into `out`. Faster workers
// earn a larger share, so each worker pacing to its own slice makes the total land
// on cap_hps. This is the only place the cap is subdivided.
//
//   - cap_hps <= 0 (uncapped): every slice is 0 (a 0-rate pacer never sleeps).
//   - no measured throughput yet: split equally (the startup case).
governor_slices :: proc(cap_hps: f64, measured_hps: []f64, out: []f64) {
	n := len(measured_hps)
	assert(len(out) == n, "governor_slices: out must match measured_hps length")

	if cap_hps <= 0 {
		for i in 0 ..< n {
			out[i] = 0
		}
		return
	}

	total: f64
	for m in measured_hps {
		total += max(m, 0)
	}

	if total <= 0 {
		equal := cap_hps / f64(n)
		for i in 0 ..< n {
			out[i] = equal
		}
		return
	}

	for i in 0 ..< n {
		out[i] = cap_hps * max(measured_hps[i], 0) / total
	}
}

// ---------------------------------------------------------------------------
// Pacer — one per worker. A token bucket over a monotonic clock.
//
// tokens is a hash-credit balance, valid as of last_ns. Doing work subtracts
// credits; the balance may go negative — negative tokens ARE the record of owed
// sleep, and are repaid in real time by the next refill (no double counting).
// max_tokens caps only the positive side, bounding the burst a worker may take
// after an idle gap.
// ---------------------------------------------------------------------------

Pacer :: struct {
	rate_hps:   f64, // this worker's slice of the cap; 0 == uncapped
	max_tokens: f64, // burst ceiling, in hashes
	tokens:     f64,
	last_ns:    i64, // monotonic ns since `start`
	start:      time.Tick,
}

// BURST_SECONDS is how much idle-catchup a paced worker may accumulate. Small and
// crude on purpose (the governor "does not need to be precise").
@(private)
BURST_SECONDS :: 0.25

pacer_init :: proc(p: ^Pacer, rate_hps: f64) {
	p.rate_hps = rate_hps
	p.max_tokens = max(rate_hps, 0) * BURST_SECONDS
	p.tokens = 0 // start empty: no initial burst
	p.start = time.tick_now()
	p.last_ns = 0
}

// pacer_set_rate updates a worker's slice mid-run (a governor rebalance). Clamps the
// current balance to the new burst ceiling.
pacer_set_rate :: proc(p: ^Pacer, rate_hps: f64) {
	p.rate_hps = rate_hps
	p.max_tokens = max(rate_hps, 0) * BURST_SECONDS
	if p.tokens > p.max_tokens {
		p.tokens = p.max_tokens
	}
}

// pacer_advance is the pure token-bucket step: given the monotonic time `now_ns` and
// `n` hashes just completed, update the balance and return how long the caller must
// sleep (0 if none). Deterministic — no clock read, no sleep — so it is unit-tested
// against a synthetic clock.
pacer_advance :: proc(p: ^Pacer, now_ns: i64, n: u32) -> (sleep_ns: i64) {
	if p.rate_hps <= 0 {
		return 0 // uncapped: never sleep
	}

	dt := f64(now_ns - p.last_ns) / 1e9
	if dt < 0 {
		dt = 0
	}
	p.last_ns = now_ns

	p.tokens = min(p.max_tokens, p.tokens + dt * p.rate_hps)
	p.tokens -= f64(n)

	if p.tokens >= 0 {
		return 0
	}
	return i64(-p.tokens / p.rate_hps * 1e9)
}

// PACER_SLICE bounds a single sleep syscall so a set quit flag is noticed within one
// slice rather than after a whole throttle sleep. It matters because the owed sleep
// scales with the turn size: a GPU turn (millions of nonces) at a low cap can owe tens
// of SECONDS, and shutdown joins the worker thread — without slicing, Ctrl-C would hang
// for that long. 50 ms is well below human perception yet coarse enough to stay cheap.
@(private)
PACER_SLICE :: i64(50 * time.Millisecond)

// pacer_pace is the hot-loop wrapper: read the monotonic clock, run the pure step,
// and sleep the difference. Called once per turn (a batch of nonces), never inside
// the inner loop — its only syscall is the sleep, and only when actually throttling.
//
// The sleep is sliced and rechecks `quit` between slices so a shutdown request is
// honored promptly. Breaking early does not leak cap: the owed sleep is recorded as a
// negative token balance in pacer_advance, so any unpaid remainder is simply carried
// (and, on quit, irrelevant — the worker is exiting).
pacer_pace :: proc(p: ^Pacer, n: u32, quit: ^u32) {
	now_ns := i64(time.tick_diff(p.start, time.tick_now()))
	d := pacer_advance(p, now_ns, n)
	for d > 0 && intrinsics.atomic_load_explicit(quit, .Acquire) == 0 {
		chunk := min(d, PACER_SLICE)
		time.sleep(time.Duration(chunk))
		d -= chunk
	}
}
