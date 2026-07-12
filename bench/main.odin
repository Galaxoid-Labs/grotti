package main

// Throughput benchmark for the CPU stone: stage 1 (scalar) vs stage 3 (SIMD).
// Build with -o:speed — a debug build is meaningless for hashrate (CLAUDE.md § Build).
//
//   odin build bench -out:bench -o:speed && ./bench

import grotti ".."
import "core:fmt"
import "core:time"

bench_one :: proc(
	name: string,
	scan: proc(^grotti.Header, [32]u8, u32, u32, []u32) -> int,
	h: ^grotti.Header,
	target: [32]u8,
	count: u32,
) {
	hits: [64]u32
	start := time.tick_now()
	n := scan(h, target, 0, count, hits[:])
	elapsed := time.duration_seconds(time.tick_diff(start, time.tick_now()))
	mhs := f64(count) / elapsed / 1e6
	fmt.printf("  %-8s %10.2f MH/s   (%d nonces in %.3fs, %d hits)\n", name, mhs, count, elapsed, n)
}

main :: proc() {
	// Real block 125552 header prefix; network target => effectively no hits, so the
	// scan measures pure hashing throughput.
	prev := grotti.reverse32(hex32("00000000000008a3a41b85b8b29ad444def299fee21793cd8b9e567eab02cd81"))
	merkle := grotti.reverse32(hex32("2b12fcf1b09288fcaff797d71e950e71ae42b91e8bdb2304758dfcffc2b620e3"))
	h := grotti.serialize_header(1, prev, merkle, 1305998791, 0x1A44B9F2, 0)
	target, _ := grotti.target_from_compact(0x1A44B9F2)

	fmt.println("Grotti CPU stone — single-thread throughput (-o:speed):")
	bench_one("scalar", grotti.scan_scalar, &h, target, 1 << 22)
	bench_one("simd", grotti.scan_simd, &h, target, 1 << 24)
}

hex32 :: proc(s: string) -> (out: [32]u8) {
	nib :: proc(c: u8) -> u8 {
		switch {
		case c >= '0' && c <= '9':
			return c - '0'
		case c >= 'a' && c <= 'f':
			return c - 'a' + 10
		}
		return 0
	}
	b := transmute([]u8)s
	for i in 0 ..< 32 {
		out[i] = (nib(b[i * 2]) << 4) | nib(b[i * 2 + 1])
	}
	return
}
