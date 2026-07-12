package grotti

// Lock-free job publication: a generation counter over a ring of slots
// (DEVELOPMENT.md § Job publication). Jobs are immutable once published — publishing
// is a store, consuming is a load, no mutex.
//
// Fenja publishes: fill slot (gen+1)%N, then release-store gen+1. Menja consumes:
// acquire-load gen, copy slot gen%N. The release/acquire pair makes the slot's
// contents visible before the generation bump is — do NOT weaken it to Relaxed. A
// slot is not reused until N generations later, by which time no reader is on it, so
// there is no seqlock/ABA retry. N=8 is enormous: jobs arrive ~2/min.

import "base:intrinsics"

JOB_RING_SLOTS :: 8

Job_Ring :: struct {
	slots: [JOB_RING_SLOTS]Job,
	gen:   u64, // atomic. gen == 0 means "no job yet"; live slot is gen % N.
}

// ring_publish installs a new job. Single-publisher (Fenja) only — the relaxed load
// of gen is safe because nothing else writes it.
ring_publish :: proc(r: ^Job_Ring, job: Job) {
	g := intrinsics.atomic_load_explicit(&r.gen, .Relaxed)
	r.slots[(g + 1) % JOB_RING_SLOTS] = job
	intrinsics.atomic_store_explicit(&r.gen, g + 1, .Release)
}

// ring_load copies the current job into `out`. Returns the generation and whether a
// job exists yet. A worker calls this at the top of each turn and, if gen changed,
// rebuilds its header from the copy — the copy is why a slow scan can't be torn by a
// later publish (invariant: N slots >> in-flight readers).
ring_load :: proc(r: ^Job_Ring, out: ^Job) -> (gen: u64, ok: bool) {
	g := intrinsics.atomic_load_explicit(&r.gen, .Acquire)
	if g == 0 {
		return 0, false
	}
	out^ = r.slots[g % JOB_RING_SLOTS] // value copy under the acquire
	return g, true
}
