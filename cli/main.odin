package main

// grotti — the CLI. Wires Fenja (the stratum client), the threaded CPU engine, the
// governor, and the console together into the `grotti` binary.
//
// Defaults are deliberately gentle: a modest thread count and a cap well below the
// (conservatively estimated) network hashrate, so a bare `grotti` cannot peg the
// machine or overwhelm the chain. Uncapping, or a cap above network, requires an
// explicit opt-in (CLAUDE.md invariant #2, #2c).

import grotti ".."
import cuda "../cuda"
import vkb "../vulkan"
import keygen "../keygen"
import "base:intrinsics"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// VERSION is the single source of truth. CI stamps the git tag at build time via
// `-define:GROTTI_VERSION=...`; otherwise it defaults here.
VERSION :: #config(GROTTI_VERSION, "0.1.0")

Options :: struct {
	pool:    string `usage:"pool host:port (required)"`,
	user:    string `usage:"stratum username: <thunder-addr>.<rig> (required)"`,
	backend: string `usage:"cpu | cuda | vulkan | comma-combo (default cpu — never auto-selects GPU)"`,
	threads: int    `usage:"number of CPU worker threads"`,
	cap:     f64    `usage:"cap: 0=uncapped, 1-100=percent of max (e.g. 25), >100=raw H/s"`,
	color:   string `usage:"color output: auto | always | never"`,
}

CUDA_EST_HPS :: 2.56e9 // measured GB10 rate (CUDA); used for the cap split when running both

// VK_EST_HPS is the MEASURED GB10-via-Vulkan rate (vulkan/bench at VK_LAUNCH), used only to
// resolve a percentage -cap and split a global cap across backends; a raw-H/s cap is
// unaffected. ~70% of the CUDA path (2.56 GH/s) after the shader's SHA schedule was made
// register-resident (see vulkan/sha256d.comp PERF note).
VK_EST_HPS :: 1.78e9

PER_THREAD_HPS :: 8.41e6 // measured single-thread SIMD rate; used only for a CPU estimate

g_quit: u32 // atomic; SIGINT sets it, stopping Fenja and every worker
g_console: grotti.Console
g_print: sync.Mutex // serialize stdout across the Fenja and main threads
g_net_logged: bool // log the real network difficulty once, on the first job

main :: proc() {
	// `core:flags` only knows the flag struct, not our subcommands, so we handle help
	// ourselves to make `keygen` discoverable.
	if wants_version(os.args) {
		fmt.printfln("grotti %s", VERSION)
		return
	}
	if wants_help(os.args) {
		print_help()
		return
	}

	// Subcommand: `grotti keygen` mints a Thunder wallet; `grotti keygen "<12 words>"`
	// recovers its first address. Offline — no node, no pool.
	if len(os.args) >= 2 && os.args[1] == "keygen" {
		run_keygen(os.args[2:])
		return
	}

	opts := Options {
		pool    = "", // required — no default; must come from -pool or grotti.conf
		user    = "", // required — no default; must come from -user or grotti.conf
		backend = "cpu",
		threads = 4,
		cap     = 500_000,
		color   = "auto",
	}
	conf_path, conf_loaded := load_conf(&opts) // grotti.conf overrides defaults...
	flags.parse_or_exit(&opts, os.args) // ...and CLI flags override the conf
	if opts.pool == "" {
		fmt.eprintln("no pool endpoint set.")
		fmt.eprintln("pass -pool:<host:port> (or stratum+tcp://host:port), or set `pool` in grotti.conf.")
		return
	}
	pool_addr := normalize_pool(opts.pool)

	run_cpu := strings.contains(opts.backend, "cpu")
	run_cuda := strings.contains(opts.backend, "cuda")
	run_vulkan := strings.contains(opts.backend, "vulkan")
	if !run_cpu && !run_cuda && !run_vulkan {
		fmt.eprintln("no backend selected (use -backend:cpu|cuda|vulkan or a comma-combo)")
		return
	}
	if run_cuda && !grotti.cuda_available() {
		fmt.eprintln("cuda backend requested but no CUDA device is available")
		return
	}
	if run_vulkan && !grotti.vk_available() {
		fmt.eprintln("vulkan backend requested but no Vulkan device is available")
		return
	}
	if opts.user == "" {
		fmt.eprintln("no stratum username set.")
		fmt.eprintln("pass -user:<thunder-addr>.<rig>, or set `user` in grotti.conf.")
		fmt.eprintln("no address? generate one with:  grotti keygen")
		return
	}

	mode := grotti.Color_Mode.Auto
	switch opts.color {
	case "always":
		mode = .Always
	case "never":
		mode = .Never
	}
	g_console = grotti.console_init(mode)

	fmt.printfln("grotti %s  ·  backend=%s  ·  pool=%s", VERSION, opts.backend, pool_addr)
	if conf_loaded {
		fmt.printfln("config: %s", conf_path)
	}
	if run_cuda {
		info := cuda.cuda_probe()
		fmt.printfln("cuda: %s  ·  compute %d.%d  ·  %d SMs", cuda.device_name(&info), info.cc_major, info.cc_minor, info.mp_count)
	}
	if run_vulkan {
		vinfo := vkb.vulkan_probe()
		fmt.printfln(
			"vulkan: %s [%s]  ·  api %d.%d  ·  selected of %d device(s)",
			vkb.device_name(&vinfo),
			vkb.vendor_name(vinfo.vendor_id),
			vinfo.api_major,
			vinfo.api_minor,
			vinfo.device_count,
		)
	}

	// Estimated max hashrate of the selected backends — used to resolve a percentage
	// -cap and to split a global cap across backends.
	cpu_max := run_cpu ? f64(opts.threads) * PER_THREAD_HPS : 0
	cuda_max := run_cuda ? CUDA_EST_HPS : 0
	vk_max := run_vulkan ? VK_EST_HPS : 0
	total_max := cpu_max + cuda_max + vk_max

	// -cap: 0 = uncapped; 1..100 = percent of the estimated max; >100 = raw H/s.
	cap_hps: f64
	switch {
	case opts.cap <= 0:
		cap_hps = 0
	case opts.cap <= 100:
		cap_hps = opts.cap / 100 * total_max
	case:
		cap_hps = opts.cap
	}

	// The cap is a resource throttle, not a chain-safety gate — on this chain
	// (difficulty ~133k) even the GPU is a small fraction of the network.
	if cap_hps <= 0 {
		fmt.println("cap: uncapped")
	} else {
		rate := strings.builder_make(context.temp_allocator)
		grotti.human_hps(&rate, cap_hps)
		if opts.cap <= 100 {
			fmt.printfln("cap: %.0f%% ≈ %s  ·  adjust with -cap", opts.cap, strings.to_string(rate))
		} else {
			fmt.printfln("cap: %s  ·  adjust with -cap", strings.to_string(rate))
		}
	}
	fmt.println()

	install_interrupt_handler()

	// Wiring.
	ring := new(grotti.Job_Ring)
	shares := new(grotti.Share_Queue)
	grotti.share_queue_init(shares)
	st := new(grotti.Stats)
	grotti.stats_init(st)

	fenja := new(grotti.Fenja)
	fenja.ring = ring
	fenja.shares = shares
	fenja.stats = st
	fenja.quit = &g_quit
	fenja.pool_addr = pool_addr
	fenja.auth_user = opts.user
	fenja.on_event = on_event
	fenja.on_difficulty = on_difficulty
	fenja.on_job = on_job
	fenja.on_authorized = on_authorized
	fenja.on_share_result = on_share_result
	fenja.on_block = on_block

	ft := thread.create(fenja_thread_proc)
	ft.data = fenja
	thread.start(ft)

	// Split the global cap across the selected backends by their estimated rate, so
	// the total lands on cap_hps. Uncapped (cap_hps<=0) passes through to both.
	cpu_cap := cap_hps
	cuda_cap := cap_hps
	vk_cap := cap_hps
	if cap_hps > 0 && total_max > 0 {
		cpu_cap = cap_hps * cpu_max / total_max
		cuda_cap = cap_hps * cuda_max / total_max
		vk_cap = cap_hps * vk_max / total_max
	}

	miner: ^grotti.Miner
	cuda_miner: ^grotti.CUDA_Miner
	vk_miner: ^grotti.VK_Miner
	if run_cpu {
		miner = grotti.mine_start(ring, shares, st, opts.threads, cpu_cap, &g_quit)
	}
	if run_cuda {
		// CUDA en2 id starts past the CPU worker ids so the two never collide.
		cuda_miner = grotti.cuda_mine_start(ring, shares, st, opts.threads, cuda_cap, &g_quit)
	}
	if run_vulkan {
		// Vulkan uses a widely-separated en2 base (grotti.VK_EN2_BASE) so it never
		// overlaps the CPU workers or a concurrent CUDA backend.
		vk_miner = grotti.vk_mine_start(ring, shares, st, grotti.VK_EN2_BASE, vk_cap, &g_quit)
	}

	// Live status until Ctrl-C.
	sampler: grotti.Rate_Sampler
	grotti.rate_sampler_init(&sampler, st)
	say("mining — press Ctrl-C to stop")
	for intrinsics.atomic_load_explicit(&g_quit, .Acquire) == 0 {
		time.sleep(2 * time.Second)
		if intrinsics.atomic_load_explicit(&g_quit, .Acquire) != 0 {
			break
		}
		hps := grotti.rate_sample(&sampler, st)
		snap := grotti.stats_snapshot(st)

		// Expected time to a share/block from the live rate: diff * 2^32 / hps.
		// (Reading fenja's difficulty fields across threads is a benign display race.)
		eta := strings.builder_make(context.temp_allocator)
		if hps > 0 && fenja.difficulty > 0 {
			strings.write_string(&eta, "share ~")
			grotti.human_duration(&eta, fenja.difficulty * 4.294967296e9 / hps)
			if fenja.net_difficulty > 0 {
				strings.write_string(&eta, "  ·  block ~")
				grotti.human_duration(&eta, fenja.net_difficulty * 4.294967296e9 / hps)
			}
		}

		line := strings.builder_make(context.temp_allocator)
		grotti.format_status(&line, g_console, snap, hps, "", strings.to_string(eta))
		say(strings.to_string(line))
		free_all(context.temp_allocator)
	}

	fmt.println("\nstopping ...")
	if miner != nil {
		grotti.mine_stop(miner)
	}
	if cuda_miner != nil {
		grotti.cuda_mine_stop(cuda_miner)
	}
	if vk_miner != nil {
		grotti.vk_mine_stop(vk_miner)
	}
	thread.join(ft)
	snap := grotti.stats_snapshot(st)
	fmt.printfln(
		"done — %.0f hashes, %d accepted, %d rejected, up %.0fs",
		f64(snap.hashes),
		snap.accepted,
		snap.rejected,
		snap.uptime_s,
	)
	grotti.console_restore() // put the console code page back (Windows); no-op elsewhere
}

fenja_thread_proc :: proc(t: ^thread.Thread) {
	grotti.fenja_run(cast(^grotti.Fenja)t.data)
}

wants_help :: proc(args: []string) -> bool {
	for a in args[1:] {
		switch a {
		case "-help", "--help", "-h", "help":
			return true
		}
	}
	return false
}

wants_version :: proc(args: []string) -> bool {
	for a in args[1:] {
		switch a {
		case "-version", "--version", "version":
			return true
		}
	}
	return false
}

print_help :: proc() {
	fmt.printfln("grotti %s — a Stratum V1 CPU/GPU miner (drivechain / simplepool)", VERSION)
	fmt.println()
	fmt.println("USAGE")
	fmt.println("  grotti [flags]                 mine (requires -pool and -user, or set in grotti.conf)")
	fmt.println("  grotti keygen                  generate a new Thunder wallet (mnemonic + address)")
	fmt.println("  grotti keygen \"<12 words>\"     recover the address for a mnemonic")
	fmt.println("  grotti version                 print the version")
	fmt.println("  grotti -help                   show this help")
	fmt.println()
	fmt.println("FLAGS")
	fmt.println("  -pool:ENDPOINT   host:port or stratum+tcp://host:port   (required)")
	fmt.println("  -user:ADDR.RIG   stratum username <thunder-addr>.<rig>  (required)")
	fmt.println("  -backend:LIST    cpu | cuda | vulkan | comma-combo        (default cpu; never auto-selects GPU)")
	fmt.println("  -threads:N       CPU worker threads                     (default 4)")
	fmt.println("  -cap:N           0=uncapped · 1-100=percent · >100=H/s   (default 500000)")
	fmt.println("  -color:MODE      auto | always | never                  (default auto)")
	fmt.println()
	fmt.println("CONFIG")
	fmt.println("  grotti.conf (INI, next to the binary) sets defaults; flags override it.")
}

// run_keygen: with words, recover an address; without, generate a new wallet.
run_keygen :: proc(args: []string) {
	if len(args) > 0 {
		mnemonic := strings.join(args, " ", context.temp_allocator)
		fmt.printfln("mnemonic: %s", mnemonic)
		fmt.printfln("address:  %s", keygen.address_from_mnemonic(mnemonic))
		return
	}
	w := keygen.generate()
	fmt.println("=== NEW Thunder wallet — save the mnemonic; it is the ONLY backup ===")
	fmt.printfln("mnemonic: %s", w.mnemonic)
	fmt.printfln("address:  %s", w.address)
}

// say prints one already-built line, serialized so the Fenja and main threads never
// interleave mid-line.
say :: proc(line: string) {
	sync.lock(&g_print)
	fmt.println(line)
	sync.unlock(&g_print)
}

log_line :: proc(code, tag, msg: string) {
	h, m, s := grotti.wall_clock()
	b := strings.builder_make(context.temp_allocator)
	grotti.format_event(&b, g_console, h, m, s, code, tag, msg)
	say(strings.to_string(b))
}

// --- Fenja logging hooks (run on the Fenja thread) --------------------------

on_event :: proc(f: ^grotti.Fenja, msg: string) {
	log_line(grotti.CYAN, "song", msg)
}
on_difficulty :: proc(f: ^grotti.Fenja, diff: f64) {
	log_line(grotti.YELLOW, "diff", fmt.tprintf("set %.0f", diff))
}
on_job :: proc(f: ^grotti.Fenja, job: ^grotti.Job) {
	if !g_net_logged {
		g_net_logged = true
		log_line(
			grotti.DIM,
			"net",
			fmt.tprintf("network difficulty %.0f  (nbits %08x)", grotti.difficulty_from_nbits(job.nbits), job.nbits),
		)
	}
	log_line(grotti.DIM, "job", fmt.tprintf("%s%s", grotti.job_id(job), job.clean ? "  clean" : ""))
}
on_authorized :: proc(f: ^grotti.Fenja, ok: bool) {
	log_line(ok ? grotti.GREEN : grotti.BOLD_RED, "song", ok ? "authorized" : "authorize FAILED")
}
on_share_result :: proc(f: ^grotti.Fenja, id: int, accepted: bool) {
	log_line(accepted ? grotti.GREEN : grotti.RED, "share", accepted ? "✔ accepted" : "✘ rejected")
}
on_block :: proc(f: ^grotti.Fenja, sh: ^grotti.Share) {
	log_line(grotti.BOLD_GREEN, "BLOCK", fmt.tprintf("🎉 BLOCK FOUND — nonce %08x (submitting)", sh.nonce))
}
