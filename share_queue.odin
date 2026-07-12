package grotti

// The share hand-off: Menja threads (many producers) find shares; Fenja (one
// consumer) drains and submits. Bounded and non-blocking — a hasher must NEVER block
// on the network, so a full queue drops the share and counts it (DEVELOPMENT.md
// § Share submission). On this chain most shares are blocks, so this path is not
// rare, but it still must not stall the stone.
//
// A Vyukov bounded MPMC ring: each cell carries a sequence number that gates
// producer/consumer access with no lock and no per-op allocation.

import "base:intrinsics"

MAX_EN2 :: 8

// Share is everything Fenja needs to submit — echoed byte-identically (the submit
// echo rule: the server rebuilds the coinbase from en2/ntime, any mismatch rejects).
Share :: struct {
	gen:     u64, // job generation this was found against
	id:      [MAX_JOB_ID]u8, // job_id to submit under
	id_len:  int,
	en2:      [MAX_EN2]u8,
	en2_len:  int,
	ntime:    u32,
	nonce:    u32,
	is_block: bool, // hash also cleared the network target — this is a block
}

SHARE_QUEUE_CAP :: 256 // power of two
@(private)
SHARE_QUEUE_MASK :: SHARE_QUEUE_CAP - 1

@(private)
Share_Cell :: struct {
	seq: u64, // atomic
	val: Share,
}

Share_Queue :: struct {
	buf:  [SHARE_QUEUE_CAP]Share_Cell,
	tail: u64, // atomic — producers claim here
	head: u64, // atomic — the single consumer advances here
}

share_queue_init :: proc(q: ^Share_Queue) {
	for i in 0 ..< SHARE_QUEUE_CAP {
		q.buf[i].seq = u64(i)
	}
	q.tail = 0
	q.head = 0
}

// share_enqueue is called by any Menja thread. Returns false if the queue is full
// (the caller counts the drop). Never blocks.
share_enqueue :: proc(q: ^Share_Queue, val: Share) -> bool {
	pos := intrinsics.atomic_load_explicit(&q.tail, .Relaxed)
	for {
		cell := &q.buf[pos & SHARE_QUEUE_MASK]
		seq := intrinsics.atomic_load_explicit(&cell.seq, .Acquire)
		dif := i64(seq) - i64(pos)
		if dif == 0 {
			_, ok := intrinsics.atomic_compare_exchange_weak_explicit(&q.tail, pos, pos + 1, .Relaxed, .Relaxed)
			if ok {
				cell.val = val
				intrinsics.atomic_store_explicit(&cell.seq, pos + 1, .Release)
				return true
			}
		} else if dif < 0 {
			return false // full
		} else {
			pos = intrinsics.atomic_load_explicit(&q.tail, .Relaxed)
		}
	}
}

// share_dequeue is called only by Fenja (single consumer). Returns the next share, or
// ok=false if empty.
share_dequeue :: proc(q: ^Share_Queue) -> (val: Share, ok: bool) {
	pos := intrinsics.atomic_load_explicit(&q.head, .Relaxed)
	for {
		cell := &q.buf[pos & SHARE_QUEUE_MASK]
		seq := intrinsics.atomic_load_explicit(&cell.seq, .Acquire)
		dif := i64(seq) - i64(pos + 1)
		if dif == 0 {
			_, won := intrinsics.atomic_compare_exchange_weak_explicit(&q.head, pos, pos + 1, .Relaxed, .Relaxed)
			if won {
				val = cell.val
				intrinsics.atomic_store_explicit(&cell.seq, pos + SHARE_QUEUE_MASK + 1, .Release)
				return val, true
			}
		} else if dif < 0 {
			return {}, false // empty
		} else {
			pos = intrinsics.atomic_load_explicit(&q.head, .Relaxed)
		}
	}
}
