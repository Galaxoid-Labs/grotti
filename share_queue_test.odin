package grotti

import "base:intrinsics"
import "core:testing"
import "core:thread"

@(test)
test_share_queue_basic :: proc(t: ^testing.T) {
	q: Share_Queue
	share_queue_init(&q)

	_, ok := share_dequeue(&q)
	testing.expect(t, !ok, "empty queue yields nothing")

	// Fill to capacity, then confirm the next enqueue is refused (dropped).
	for i in 0 ..< SHARE_QUEUE_CAP {
		sh: Share
		sh.nonce = u32(i)
		testing.expect(t, share_enqueue(&q, sh), "enqueue within capacity")
	}
	extra: Share
	testing.expect(t, !share_enqueue(&q, extra), "full queue drops")

	// Drain in FIFO order.
	for i in 0 ..< SHARE_QUEUE_CAP {
		sh, got := share_dequeue(&q)
		testing.expect(t, got, "dequeue")
		testing.expect_value(t, sh.nonce, u32(i))
	}
	_, ok2 := share_dequeue(&q)
	testing.expect(t, !ok2, "empty again after drain")
}

@(private = "file")
Q_Ctx :: struct {
	q:              Share_Queue,
	producers_done: u32, // atomic
	enq_count:      [4]u64, // each written only by producer i
	enq_sum:        [4]u64,
	deq_count:      u64, // consumer only
	deq_sum:        u64,
}

@(private = "file")
Prod_Arg :: struct {
	ctx: ^Q_Ctx,
	id:  int,
}

// Many producers, one consumer, running concurrently. Each producer enqueues nonces
// 1..M and records its successful (non-dropped) enqueues. The consumer drains the
// whole time. At the end: dequeued count and nonce-sum must equal the successfully
// enqueued count and sum — no loss, no duplication, no field corruption.
@(test)
test_share_queue_mpsc :: proc(t: ^testing.T) {
	ctx := new(Q_Ctx)
	defer free(ctx)
	share_queue_init(&ctx.q)

	M :: 100_000

	producer :: proc(th: ^thread.Thread) {
		pa := cast(^Prod_Arg)th.data
		c := pa.ctx
		id := pa.id
		for seq in 1 ..= M {
			sh: Share
			sh.gen = u64(id)
			sh.nonce = u32(seq)
			if share_enqueue(&c.q, sh) {
				c.enq_count[id] += 1
				c.enq_sum[id] += u64(seq)
			}
		}
	}

	consumer :: proc(th: ^thread.Thread) {
		c := cast(^Q_Ctx)th.data
		for {
			sh, ok := share_dequeue(&c.q)
			if ok {
				c.deq_count += 1
				c.deq_sum += u64(sh.nonce)
				continue
			}
			// Empty. Producers set done only after they have all finished, so an
			// empty queue with done set means everything has been drained.
			if intrinsics.atomic_load_explicit(&c.producers_done, .Acquire) == 1 {
				break
			}
		}
	}

	con := thread.create(consumer)
	con.data = ctx
	thread.start(con)

	args: [4]Prod_Arg
	prods: [4]^thread.Thread
	for i in 0 ..< 4 {
		args[i] = Prod_Arg {
			ctx = ctx,
			id  = i,
		}
		prods[i] = thread.create(producer)
		prods[i].data = &args[i]
		thread.start(prods[i])
	}
	for i in 0 ..< 4 {
		thread.join(prods[i])
		thread.destroy(prods[i])
	}
	intrinsics.atomic_store_explicit(&ctx.producers_done, 1, .Release)
	thread.join(con)
	thread.destroy(con)

	total_count: u64
	total_sum: u64
	for i in 0 ..< 4 {
		total_count += ctx.enq_count[i]
		total_sum += ctx.enq_sum[i]
	}
	testing.expect_value(t, ctx.deq_count, total_count)
	testing.expect_value(t, ctx.deq_sum, total_sum)
	testing.expect(t, total_count > 0, "some enqueues succeeded")
}
