package grotti

// Runtime metrics: hashrate estimate, accepted/rejected shares, uptime.
//
// The counters are plain atomics — the stone reports hashes with one relaxed
// atomic_add per turn (never per nonce, never a lock: invariant #3), and Fenja
// records share results as it drains the queue. Reads (for the status line) are
// relaxed loads; nothing here orders anything else, so Relaxed is correct and cheap.

import "base:intrinsics"
import "core:time"

Stats :: struct {
	start:    time.Tick,
	hashes:   u64, // atomic — total nonces hashed
	accepted: u64, // atomic
	rejected: u64, // atomic
	stale:    u64, // atomic — submitted-but-stale / dropped
}

stats_init :: proc(s: ^Stats) {
	s^ = {}
	s.start = time.tick_now()
}

// Hot-path-adjacent: called once per turn with the batch size.
stats_add_hashes :: proc(s: ^Stats, n: u64) {
	intrinsics.atomic_add_explicit(&s.hashes, n, .Relaxed)
}

stats_accepted :: proc(s: ^Stats) {
	intrinsics.atomic_add_explicit(&s.accepted, 1, .Relaxed)
}

stats_rejected :: proc(s: ^Stats) {
	intrinsics.atomic_add_explicit(&s.rejected, 1, .Relaxed)
}

stats_stale :: proc(s: ^Stats) {
	intrinsics.atomic_add_explicit(&s.stale, 1, .Relaxed)
}

Snapshot :: struct {
	hashes, accepted, rejected, stale: u64,
	uptime_s:                          f64,
	avg_hps:                           f64,
}

stats_snapshot :: proc(s: ^Stats) -> (snap: Snapshot) {
	snap.hashes = intrinsics.atomic_load_explicit(&s.hashes, .Relaxed)
	snap.accepted = intrinsics.atomic_load_explicit(&s.accepted, .Relaxed)
	snap.rejected = intrinsics.atomic_load_explicit(&s.rejected, .Relaxed)
	snap.stale = intrinsics.atomic_load_explicit(&s.stale, .Relaxed)
	snap.uptime_s = time.duration_seconds(time.tick_diff(s.start, time.tick_now()))
	snap.avg_hps = snap.uptime_s > 0 ? f64(snap.hashes) / snap.uptime_s : 0
	return
}

// acceptance_rate returns accepted / (accepted + rejected), or 1.0 before any share.
// A run silently rejecting everything (the word-swap bug) drives this toward 0.
stats_acceptance_rate :: proc(snap: Snapshot) -> f64 {
	total := snap.accepted + snap.rejected
	return total == 0 ? 1.0 : f64(snap.accepted) / f64(total)
}

// Rate_Sampler yields the instantaneous hashrate between successive samples — what
// the live status line shows, as opposed to the whole-run average.
Rate_Sampler :: struct {
	last_hashes: u64,
	last_tick:   time.Tick,
}

rate_sampler_init :: proc(rs: ^Rate_Sampler, s: ^Stats) {
	rs.last_hashes = intrinsics.atomic_load_explicit(&s.hashes, .Relaxed)
	rs.last_tick = time.tick_now()
}

rate_sample :: proc(rs: ^Rate_Sampler, s: ^Stats) -> f64 {
	now := time.tick_now()
	h := intrinsics.atomic_load_explicit(&s.hashes, .Relaxed)
	dt := time.duration_seconds(time.tick_diff(rs.last_tick, now))
	dh := h - rs.last_hashes
	rs.last_hashes = h
	rs.last_tick = now
	return dt > 0 ? f64(dh) / dt : 0
}
