# Grotti

A Stratum V1 miner in pure Odin — CPU (SIMD) and NVIDIA GPU (CUDA) backends in one
binary, with no build-time GPU or C dependency (the CUDA driver is loaded at runtime).
Connects to LayerTwo Labs' `simplepool` on the BIP300/301 drivechain test network.

> In *Grottasöngr*, King Fróði's mill **Grotti** grinds out gold, turned by two
> giantesses who are never allowed to rest. There is no better description of
> proof-of-work. **Fenja** is the stratum client that feeds the mill; **Menja** is
> the hasher that turns the stone.

**Status:** working, verified against a live pool session. It connects, authorizes,
receives real jobs, hashes them under a hashrate governor, submits shares, and flags a
found block. The CPU SIMD engine does ~8.4 MH/s per thread; the CUDA backend does
~2.6 GH/s on an NVIDIA GB10. 56 tests pass, including the optimized CPU and GPU hashers
differentially tested against `core:crypto/sha2`.

---

## Build

```sh
odin build cli -out:grotti -o:speed     # -o:speed is mandatory for hashrate
```

> Don't name the binary `grotti` if you also run `odin test .` in this directory —
> the test runner's temporary binary is named after the package and will clobber it.
> Use `-out:bin/grotti` or any other name.

## Quick start

```sh
./grotti                                 # gentle defaults: 4 threads, 500 KH/s cap
```

That's it — the defaults point at the drivechain pool and stay well under the
network hashrate. Press **Ctrl-C** to stop cleanly.

### Examples

```sh
# More threads, a higher (but still governed) cap
./grotti -threads:8 -cap:2000000

# Your own payout address and rig name
./grotti -user:<thunder-addr>.<rig>

# A different pool
./grotti -pool:pool.example.com:3334

# Force color on when piping to a file, or off entirely
./grotti -color:always
./grotti -color:never

# Full tilt CPU — all cores, uncapped
./grotti -threads:20 -cap:0

# GPU (NVIDIA, via runtime-loaded CUDA) — uncapped
./grotti -backend:cuda -cap:0

# Both CPU and GPU, one global cap split across them
./grotti -backend:cpu,cuda -cap:0
```

### Flags

| Flag | Default | Meaning |
|---|---|---|
| `-pool:host:port` | `pool.drivechain.info:3334` | stratum pool |
| `-user:addr.rig` | *(a demo address)* | `<thunder-addr>.<rig>` for `mining.authorize` |
| `-backend:LIST` | `cpu` | `cpu` \| `cuda` \| `cpu,cuda` — never auto-selects the GPU |
| `-threads:N` | `4` | CPU worker threads |
| `-cap:HPS` | `500000` | hashrate cap in H/s (`0` = uncapped) |
| `-color:MODE` | `auto` | `auto` \| `always` \| `never` |

**GPU backend:** the CUDA driver is `dlopen`'d at runtime — no build-time CUDA
dependency, and a GPU-less box runs fine. It's opt-in (`-backend:cuda`); a bare
`./grotti` is always CPU. The GB10 does ~2.6 GH/s (~300× a CPU thread). The kernel is
built to `cuda/kernel.cubin` (committed, embedded via `#load`); rebuild it only if you
edit `cuda/kernel.cu`:
```sh
cd cuda && nvcc -cubin -arch=sm_121 kernel.cu -o kernel.cubin
```

Need a Thunder address? Generate one offline (no node) with the helper added to
`thunder-rust`:

```sh
cd ../thunder-rust && cargo run -p thunder --example gen_address
```

---

## The cap

The governor paces every worker to a global cap (it does not reduce parallelism), so
CPU cost is roughly `cap ÷ 8.4 MH/s` in cores — 500 KH/s ≈ 0.06 of a core. The
default is low purely as a courtesy so a bare `./grotti` doesn't compete with other
work on the box; **raise `-cap` / `-threads` freely.** On this chain (network
difficulty ~133,000, shown live at startup) a CPU is a negligible fraction of the
network, so the cap is a resource knob, not a chain-safety limit.

The same global cap governs the GPU (`cap ÷ 2.6 GH/s` of the card), and when running
`-backend:cpu,cuda` it is split across both by their measured rate. See `CLAUDE.md` § 2.

## Will I see accepted shares? A block?

The pool sends share difficulty **1024**, so a share takes ~4.4×10¹² hashes:

| Backend | Rate | ~time per share |
|---|---|---|
| CPU (500 KH/s cap) | 0.5 MH/s | ~100 days |
| CPU (full, uncapped) | ~168 MH/s | ~7 hours |
| **GPU (GB10)** | ~2.6 GH/s | **~27 minutes** |

You appear on the pool dashboard once your first share is accepted. A **block** (the
hash also clears the ~133k network target) is far rarer — ~2.5 days of solo GPU time —
but Grotti checks every hit against the network target locally and prints a bold-green
`🎉 BLOCK FOUND` line if you land one.

---

## Tests

```sh
odin test .              # engine: target, job, governor, ring, fenja, stats, ...
odin test sha256d        # the optimized CPU hasher vs core:crypto/sha2
odin run cuda/kerneltest # GPU kernel: reproduces a known block, matches the CPU
```

## Layout

Odin: a directory is a package.

```
*.odin                 # package grotti — engine, governor, stratum, console
  target.odin          #   difficulty <-> 256-bit target (fractional-safe)
  job.odin             #   Job, header build + byte-order conversions
  menja.odin           #   the stone: scalar + SIMD nonce scan, block detection
  menja_worker.odin    #   CPU worker threads (per-thread extranonce2)
  gpu_worker.odin      #   CUDA worker: launches the kernel, rolls extranonce2
  governor.odin        #   the global hashrate cap (token-bucket pacer)
  ring.odin            #   lock-free job publication (generation counter)
  share_queue.odin     #   bounded MPSC share hand-off
  fenja.odin           #   stratum client: socket, framing, reconnect
  fenja_jsonrpc.odin   #   message decode/dispatch (tolerates id:null)
  stats.odin console.odin
sha256d/               # package sha256d — scalar + midstate + SIMD, isolated
cuda/                  # package cuda — CUDA driver (dlopen) + host engine
  kernel.cu            #   the only non-Odin file; built to kernel.cubin (committed)
  probe/ kerneltest/ bench/   #   FFI probe, correctness gate, throughput
cli/                   # package main -> the grotti binary
capture/               # throwaway: record a raw pool session
```

See `CLAUDE.md` for invariants and the wire protocol, `DEVELOPMENT.md` for the phase
plan and test plan.
