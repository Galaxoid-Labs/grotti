package grotti

import "core:testing"

// Replay the REAL captured pool session (2026-07-12) through the dispatcher and
// confirm it yields the right session state and the right Job on the ring. This is
// the whole Stratum decode path tested against live wire data.
@(test)
test_fenja_replays_real_session :: proc(t: ^testing.T) {
	ring: Job_Ring
	stats: Stats
	stats_init(&stats)
	f: Fenja
	f.ring = &ring
	f.stats = &stats

	feed :: proc(f: ^Fenja, s: string) {
		fenja_handle_line(f, transmute([]u8)s)
	}

	// subscribe reply: extranonce1 = 749b6aeb, extranonce2_size = 4
	feed(&f, `{"id":1,"result":[[["mining.set_difficulty","sd"],["mining.notify","sn"]],"749b6aeb",4],"error":null}`)
	testing.expect(t, f.subscribed, "subscribed")
	testing.expect_value(t, f.en1_len, 4)
	testing.expect_value(t, f.en1[0], u8(0x74))
	testing.expect_value(t, f.en1[3], u8(0xeb))
	testing.expect_value(t, f.en2_size, 4)

	// authorize reply
	feed(&f, `{"id":2,"result":true,"error":null}`)
	testing.expect(t, f.authorized, "authorized")

	// set_difficulty 1024 (INTEGER — the live pool is not fractional)
	feed(&f, `{"id":null,"method":"mining.set_difficulty","params":[1024]}`)
	testing.expect(t, f.have_diff, "have difficulty")
	testing.expect(t, f.difficulty == 1024, "difficulty is 1024")
	testing.expect_value(t, f.target, target_from_difficulty(1024))

	// the real mining.notify (id:null — must NOT choke a strict client)
	feed(
		&f,
		`{"id":null,"method":"mining.notify","params":["19f58498d20","c6a54c3bae51e5e4bc04197e3a60f30807ac10a7c2f2db6200001d6200000000","02000000010000000000000000000000000000000000000000000000000000000000000000ffffffff2402e359182f73696d706c65706f6f6c2d7070732d636c61737369632f","ffffffff050000000000000000276a25d16173680967af15bd3341164c3d698783c53de5ca5e3334dcf812ebdc01729c306165a2f700000000000000000f6a0dd77d177601ffffffffffffffff5e050b27010000001600143b5078906424e4f68a2d89af4b8d625754c297928af0fa02000000001600143b5078906424e4f68a2d89af4b8d625754c297920000000000000000266a24aa21a9ed35ce7c3be84450cf7edf502925bb48df5db198bccb668973f32c1735e51b927d00000000",["f5734a50e7482dfe2ca81d962ea93e0b907734ba4c7a1121fa77aecad786c90c"],"20000000","1a7e2500","6a540aa3",true]}`,
	)
	testing.expect_value(t, f.job_count, 1)

	job: Job
	g, ok := ring_load(&ring, &job)
	testing.expect(t, ok && g == 1, "job published to the ring")
	testing.expect(t, string(job.id[:job.id_len]) == "19f58498d20", "job id")
	testing.expect_value(t, job.version, u32(0x2000_0000))
	testing.expect_value(t, job.nbits, u32(0x1a7e_2500))
	testing.expect_value(t, job.ntime, u32(0x6a54_0aa3))
	testing.expect_value(t, job.n_branches, 1)
	testing.expect(t, job.clean, "clean_jobs true")
	testing.expect_value(t, job.target, target_from_difficulty(1024))
	// en1 propagated from the subscribe reply
	testing.expect_value(t, job.en1_len, 4)
	testing.expect_value(t, job.en1[0], u8(0x74))
	// prevhash was word-swapped to internal order: its display form is a block hash.
	display := reverse32(job.prev)
	for i in 0 ..< 6 {
		testing.expect_value(t, display[i], u8(0))
	}
}

// Submit replies update the accepted/rejected counters (id >= 3).
@(test)
test_fenja_submit_results :: proc(t: ^testing.T) {
	stats: Stats
	stats_init(&stats)
	f: Fenja
	f.stats = &stats

	fenja_handle_line(&f, transmute([]u8)string(`{"id":3,"result":true,"error":null}`))
	fenja_handle_line(&f, transmute([]u8)string(`{"id":4,"result":false,"error":null}`))
	fenja_handle_line(&f, transmute([]u8)string(`{"id":5,"result":null,"error":"unknown-work"}`))

	snap := stats_snapshot(&stats)
	testing.expect_value(t, snap.accepted, u64(1))
	testing.expect_value(t, snap.rejected, u64(2))
}
