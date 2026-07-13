<p align="center">
  <img src="grotti_icon.png" alt="Grotti" width="200">
</p>

# Grotti

A Stratum V1 miner in pure Odin — CPU (SIMD), NVIDIA GPU (CUDA), portable GPU (Vulkan),
and Apple-Silicon GPU (Metal) backends in one binary, with no build-time GPU or C
dependency (GPU drivers are loaded at runtime, and Metal's kernel is compiled at startup).
Connects to LayerTwo Labs' `simplepool` on the BIP300/301 drivechain test network.

> In *Grottasöngr*, King Fróði's mill **Grotti** grinds out gold, turned by two
> giantesses who are never allowed to rest. There is no better description of
> proof-of-work. **Fenja** is the stratum client that feeds the mill; **Menja** is
> the hasher that turns the stone.

**Status:** working, verified against a live pool session. It connects, authorizes,
receives real jobs, hashes them under a hashrate governor, submits shares, and flags a
found block. The CPU SIMD engine does ~8.4 MH/s per thread; the CUDA backend does
~2.6 GH/s on an NVIDIA GB10. A portable **Vulkan** backend (NVIDIA/AMD/Intel) is wired in
and correct — ~1.78 GH/s on the same GB10 (~70% of the CUDA path, after the shader's SHA
schedule was made register-resident). A **Metal** backend (macOS / Apple Silicon) is
correct and passes its on-hardware gate — ~0.22 GH/s on an M1 Max (see [Performance &
headroom](#performance--headroom)). 61 tests pass, and every hasher (CPU, CUDA, Vulkan,
Metal) is differentially tested against `core:crypto/sha2` / the CPU scan.

By default `-backend` is **`auto`**: a bare `./grotti` picks the fastest *available*
backend (`cuda > metal > vulkan > cpu`), prints the choice, and runs it **under the
governor** — so it is fast where a GPU is present but never uncapped without an explicit
`-cap:0`. Run `./grotti -list-backends` to see what's detected and what `auto` would pick.

---

## Disclaimer

**Use at your own risk.** Grotti is provided "as is", without warranty of any kind,
express or implied. Mining runs your CPU and/or GPU at sustained high load, which
generates heat and draws power; on inadequately cooled, powered, or maintained
hardware this can cause thermal throttling, instability, accelerated wear, or
failure. **You are solely responsible for your hardware, its cooling and power, and
for the settings you choose** (thread count, hashrate cap, and running uncapped in
particular). The authors and contributors accept **no liability** for any damage,
data loss, hardware failure, downtime, cost, or other harm arising from the use or
misuse of this software. By running Grotti you accept these risks. Start with the
gentle defaults, monitor temperatures, and raise the cap only if you understand the
thermal and electrical limits of your machine.

---

## Build

```sh
make                                    # builds ./grotti with -o:speed
# or directly:
odin build cli -out:grotti -o:speed     # -o:speed is mandatory for hashrate
```

The `Makefile` also has `make test` (runs the `.`, `sha256d`, and `keygen` suites),
`make check` (type-check only), and `make clean`. GPU backends need no build-time toolkit —
CUDA/Vulkan are `dlopen`'d at runtime and Metal is compiled from embedded source — so a
plain `make` produces a GPU-capable binary on any box.

> Don't name the binary `grotti` if you also run `odin test .` in this directory —
> the test runner's temporary binary is named after the package and will clobber it.
> Use `-out:bin/grotti` or any other name.

> **Windows: antivirus may quarantine the binary.** Grotti is a cryptocurrency miner,
> so Microsoft Defender (and other AV) can flag it as *riskware* / *CoinMiner* on
> heuristics and silently quarantine `grotti.exe` — often right after it's built, so it
> may seem to "disappear" or refuse to run. This is a heuristic match on what the program
> *is*, not a sign it's compromised; the source is here and the binary is what you built.
> If it happens, restore the file from Defender's protection history and add a
> **folder exclusion** for your build directory (Windows Security → Virus & threat
> protection → Manage settings → Exclusions), or build/run from an already-excluded path.
> Prefer a scoped exclusion over disabling real-time protection.

## Quick start

You need a **pool endpoint** for `-pool` and a Thunder address for `-user` (generate one
with `./grotti keygen` — see below). Then:

```sh
./grotti -pool:pool.drivechain.info:3334 -user:<thunder-addr>.<rig>   # auto backend, 500 KH/s cap
```

That uses the default **`auto`** backend — the fastest available (`cuda > metal > vulkan >
cpu`), printed as e.g. `backend=auto → metal`, and governed by the default 500 KH/s cap.
Pin a specific one with `-backend:` if you prefer.

Or put `pool` and `user` (and anything else) in a `grotti.conf` next to the binary and just
run `./grotti`. Grotti **refuses to start without both a pool and a username** — nothing is
baked in. Press **Ctrl-C** to stop cleanly. Run `./grotti -list-backends` to see what
hardware is detected.

### Examples

```sh
# These assume `pool` and `user` are set in grotti.conf; otherwise add -pool:… and -user:… too.

# Default: fastest available backend, governed — just run it
./grotti

# See what's detected and what `auto` would pick (connects to nothing)
./grotti -list-backends

# GPU at 25% — just give -cap a percentage
./grotti -backend:cuda -cap:25

# GPU at half speed
./grotti -backend:cuda -cap:50

# Full tilt (uncapped)
./grotti -backend:cuda -cap:0

# Portable GPU via Vulkan (NVIDIA / AMD / Intel) — picks the fastest device
./grotti -backend:vulkan -cap:25

# Apple-Silicon GPU via Metal (macOS)
./grotti -backend:metal -cap:25

# CPU: more threads at 50%
./grotti -threads:8 -cap:50

# An exact hashrate cap in H/s (anything >100 is treated as raw H/s)
./grotti -backend:cuda -cap:1000000000     # 1 GH/s

# Your own payout address / rig, or a different pool
./grotti -user:<thunder-addr>.<rig>
./grotti -pool:pool.example.com:3334

# Both CPU and GPU, one global cap split across them
./grotti -backend:cpu,cuda -cap:50

# Force color on when piping to a file, or off entirely
./grotti -color:always
./grotti -color:never
```

### Flags

| Flag | Default | Meaning |
|---|---|---|
| `-pool:ENDPOINT` | **required** | stratum pool — `host:port` or `stratum+tcp://host:port` (or set in `grotti.conf`) |
| `-user:addr.rig` | **required** | `<thunder-addr>.<rig>` for `mining.authorize` (or set in `grotti.conf`) |
| `-backend:LIST` | `auto` | `auto` \| `cpu` \| `cuda` \| `vulkan` \| `metal` \| comma-combo. `auto` picks the fastest available (`cuda > metal > vulkan > cpu`), always governed |
| `-threads:N` | `4` | CPU worker threads |
| `-cap:N` | `500000` | **`0`** = uncapped · **`1–100`** = percent of max (e.g. `-cap:25`) · **`>100`** = raw H/s |
| `-color:MODE` | `auto` | `auto` \| `always` \| `never` |
| `-list-backends` | — | print detected backends + what `auto` would pick, then exit |

### Config file

Grotti reads an INI-style **`grotti.conf`** from the directory containing the binary,
if present. Its keys match the flags, and precedence is
**built-in defaults < `grotti.conf` < command-line flags** — so the config sets your
usual setup and a flag overrides it for a one-off run. Copy
[`grotti.conf.example`](grotti.conf.example) to `grotti.conf` and edit:

```ini
# grotti.conf (next to the binary)
pool    = stratum+tcp://pool.drivechain.info:3334
user    = <thunder-addr>.<rig>
backend = cuda
threads = 4
cap     = 50        # 0=uncapped, 1-100=percent, >100=H/s
color   = auto
```

With that in place, a bare `./grotti` runs your configured setup; `./grotti -cap:100`
still overrides just the cap. (The startup banner prints `config: <path>` when a file
is loaded.)

**GPU backends:** the CUDA driver is `dlopen`'d at runtime — no build-time CUDA
dependency, and a GPU-less box runs fine. A bare `./grotti` uses `auto` (the fastest
available backend, governed); pin CUDA with `-backend:cuda`. The GB10 does ~2.6 GH/s
(~300× a CPU thread).

The kernel ships as a **committed, portable fatbin** at `cuda/kernel.cubin` (native
SASS for Turing→Blackwell + `compute_75` PTX for JIT), embedded via `#load`. So
`odin build` produces a GPU-capable binary **anywhere — no CUDA toolkit, no GPU** —
and the GPU backend then runs on any NVIDIA card ≥ compute 7.5. Rebuild the fatbin
only if you edit `cuda/kernel.cu` (needs CUDA 13 for `sm_121`, but no GPU):
```sh
cd cuda && nvcc -fatbin \
  -gencode arch=compute_75,code=sm_75  -gencode arch=compute_80,code=sm_80 \
  -gencode arch=compute_86,code=sm_86  -gencode arch=compute_89,code=sm_89 \
  -gencode arch=compute_90,code=sm_90  -gencode arch=compute_100,code=sm_100 \
  -gencode arch=compute_120,code=sm_120 -gencode arch=compute_121,code=sm_121 \
  -gencode arch=compute_75,code=compute_75 \
  kernel.cu -o kernel.cubin
```

**Vulkan backend:** portable across NVIDIA / AMD / Intel — one backend for every GPU
vendor. The loader (`libvulkan.so.1` / `vulkan-1.dll`) is `dlopen`'d at runtime like
CUDA, so a Vulkan-less box runs fine; it's opt-in (`-backend:vulkan`), and on a machine
with several GPUs it selects the fastest (discrete > integrated > virtual > CPU) and
*reports* the choice — it never silently picks. The compute shader ships as a committed,
portable **SPIR-V** blob at `vulkan/sha256d.spv`, embedded via `#load`, so `odin build`
produces a Vulkan-capable binary with no shader toolchain. Rebuild it only if you edit
`vulkan/sha256d.comp` (needs `glslangValidator` from `glslang-tools`):
```sh
cd vulkan && glslangValidator -V sha256d.comp -o sha256d.spv
```
The Vulkan path is correct (differentially tested) and runs at ~1.78 GH/s on the GB10 —
about 70% of the CUDA kernel. The remaining gap is the driver's SPIR-V→SASS compiler vs
nvcc plus the lack of hand-tuned `LOP3`; further gains would need subgroup/occupancy tuning.

**Metal backend (macOS / Apple Silicon):** native GPU mining on Apple hardware, built behind
the same seam. `Metal.framework` is a guaranteed system framework, so it is linked directly
(not `dlopen`'d) and the whole `metal/` package is compiled only on macOS; the rest of the
binary stays portable via a `#+build !darwin` stub. The kernel (`metal/sha256d.metal`, an MSL
port of the Vulkan shader) is **compiled at startup** from an embedded source string, so there
is no `metallib`, no Xcode step, and no per-GPU flags. It is correct — `metal/kerneltest`
reproduces a known block and matches the CPU scan bit-for-bit on real hardware — and runs at
~0.22 GH/s on an M1 Max. That is the honest ceiling for this GPU (see below), not a bug.
```sh
./grotti -backend:metal -cap:25   # or just `./grotti` on a Mac → auto picks Metal
```

**Portability / CI:** the CPU and Vulkan backends are cross-platform; Metal is macOS-only and
CUDA is NVIDIA-only, each behind a compile-time split so every target still builds. The only
other OS-specific code (TTY detection + color enabling, Ctrl-C) lives in per-OS files. The CUDA
loader picks its driver per-OS — `libcuda.so.1` on Linux, `nvcuda.dll` on Windows (the Windows
path is cross-checked, not yet run); Vulkan also drives the NVIDIA card on Windows. A native
Windows `.exe` links on a Windows host (Odin can't cross-link one from Linux, though it
type-checks the target), so CI builds it on a `windows-latest` runner. `.github/workflows/ci.yml`
tests and builds `grotti` for **`linux-x86_64`, `linux-arm64`, `windows-x86_64`, and
`macos-arm64`** on every push and publishes all four on a `v*` tag. See `CLAUDE.md` § Windows
and § macOS / Metal for first-run checklists.

---

## Generate a Thunder address

You need a Thunder address for `-user`. Grotti can mint one **offline** — no node, no
RPC, no external dependency (pure Odin, using `core:crypto`'s ed25519/SHA-512/HMAC/
PBKDF2 plus a small built-in blake3 and base58):

```sh
# New wallet: prints a 12-word BIP39 mnemonic and its first address
./grotti keygen

# Recover the address for an existing mnemonic
./grotti keygen "word1 word2 ... word12"
```

The derivation matches `thunder-rust` exactly — BIP39 → SLIP-0010 ed25519 at
`m/1'/0'/0'/1'` → `base58(blake3_xof(pubkey)[0:20])` — verified against a known
mnemonic→address vector in the tests, so the mnemonic works in a real Thunder wallet.

The 128-bit entropy comes from the **OS cryptographic RNG** (`crypto.rand_bytes`,
i.e. `getrandom`/`/dev/urandom`), which blocks until seeded and panics on failure —
never a weak PRNG. That single call is the only randomness in the path.

> **Save the mnemonic.** It is the only backup for the address; anyone with it controls
> the funds. The address itself is public and safe to share.

---

## The cap

The governor paces every worker to a global cap (it does not reduce parallelism), and
it takes `-cap` three ways:

- **`-cap:0`** — uncapped, full speed.
- **`-cap:25`** — a **percentage** (1–100) of the selected backends' estimated max.
  `25` runs each backend at ~25% (heat/power/duty scale roughly with it). This is the
  easy knob.
- **`-cap:1000000000`** — anything **over 100** is a raw **H/s** cap.

Percentages are relative to a built-in estimate (~8.4 MH/s per CPU thread, ~2.6 GH/s
for a GB10), so they're exact on a GB10 and approximate on other GPUs. When running
`-backend:cpu,cuda`, the global cap is split across both by their estimated rate, so
each ends up at the same fraction of its own max.

The cap is a **resource knob, not a chain-safety limit** — on this chain (network
difficulty ~133,000, shown live at startup) even the GPU is a negligible fraction of
the network. The default is low purely as a courtesy so a bare `./grotti` doesn't
compete with other work on the box; raise it freely. See `CLAUDE.md` § 2.

## Will I see accepted shares? A block?

The pool sends share difficulty **1024**, so a share takes ~4.4×10¹² hashes:

| Backend | Rate | ~time per share |
|---|---|---|
| CPU (500 KH/s cap) | 0.5 MH/s | ~100 days |
| CPU (full, uncapped) | ~168 MH/s | ~7 hours |
| **Metal (M1 Max)** | ~0.22 GH/s | **~5.5 hours** |
| **CUDA (GB10)** | ~2.6 GH/s | **~27 minutes** |

The live status line shows a running estimate from your current rate and difficulty —
`share ~28m · block ~2.5d` — so you can see roughly how long the wait is (it shrinks
as the pool's vardiff lowers your share difficulty).

You appear on the pool dashboard once your first share is accepted. A **block** (the
hash also clears the ~133k network target) is far rarer — ~2.5 days of solo GPU time —
but Grotti checks every hit against the network target locally and prints a bold-green
`🎉 BLOCK FOUND` line if you land one.

---

## Performance & headroom

Each hasher has been **meaningfully optimized, but not exhaustively** — the numbers below are
good, and there is very likely more to extract with deeper, hardware-specific tuning. If you
want to push a particular backend further, the per-backend `bench/` harnesses
(`odin run cuda/bench`, `vulkan/bench`, `metal/bench`) measure sustained throughput so you can
tell whether a change actually helped.

What's already done: a SIMD (`#simd[8]u32`) CPU inner loop; a precomputed **midstate** over the
constant first 64 header bytes (so each nonce hashes only the tail); a **register-resident
message schedule** (the fully-unrolled 64-round loop keeps the 16 words in registers, worth
~2× on Vulkan); and an **early-exit** big-endian word compare against the target before the full
256-bit check. Measured: ~8.4 MH/s per CPU thread, ~2.6 GH/s CUDA (GB10), ~1.78 GH/s Vulkan
(GB10, ~70% of CUDA), ~0.22 GH/s Metal (M1 Max).

Known remaining levers, roughly in order of likely payoff:

- **CUDA / Vulkan:** subgroup-size and occupancy tuning, and `__launch_bounds__` / LOP3
  hand-tuning on the CUDA side; the Vulkan↔CUDA gap is mostly the driver's SPIR-V→SASS
  compiler plus the missing LOP3.
- **Metal is different — it's genuinely near its ceiling on the M1 Max.** We measured it: the
  kernel is *ALU-bound*, not occupancy- or dispatch-bound (throughput is flat across every
  threadgroup size and launch size, and halving the SHA work cleanly doubles the rate). Apple
  GPUs have **no hardware funnel-shift/rotate**, so each of SHA-256's ~6 rotates per round costs
  three instructions instead of one — which is exactly why NVIDIA's rotate/`LOP3` hardware lets
  the GB10 run ~10× faster per the same math. Micro-optimizing instruction count (cheaper
  `Ch`/`Maj`) moved it ~1%. So ~0.22 GH/s is the honest number for this GPU, and the realistic
  optimized ceiling is only modestly higher; a newer Apple GPU (more cores) would scale up, but
  the per-core rotate cost is architectural.

None of this affects correctness — every backend is differentially verified regardless of speed.

---

## Tests

```sh
make test                  # runs the three suites below
odin test .                # engine: target, job, governor, ring, fenja, stats, metal worker, ...
odin test sha256d          # the optimized CPU hasher vs core:crypto/sha2
odin run cuda/kerneltest   # CUDA kernel: reproduces a known block, matches the CPU
odin run vulkan/kerneltest # Vulkan shader: reproduces a known block, matches the CPU
odin run metal/kerneltest  # Metal kernel (macOS): reproduces a known block, matches the CPU
```

## Layout

Odin: a directory is a package.

```
*.odin                 # package grotti — engine, governor, stratum, console
  target.odin          #   difficulty <-> 256-bit target (fractional-safe)
  job.odin             #   Job, header build + byte-order conversions
  menja.odin           #   the stone: scalar + SIMD nonce scan, block detection
  menja_worker.odin    #   CPU worker threads (per-thread extranonce2)
  cuda_worker.odin     #   CUDA worker: launches the kernel, rolls extranonce2
  vk_worker.odin       #   Vulkan worker: same shape as cuda_worker
  metal_worker.odin    #   Metal worker (macOS); metal_worker_stub.odin keeps grotti portable
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
vulkan/                # package vkbackend — Vulkan loader (dlopen) + compute engine
  sha256d.comp         #   GLSL compute shader; built to sha256d.spv (committed)
  probe/ kerneltest/ bench/   #   loader probe, correctness gate, throughput
metal/                 # package metalbackend (macOS) — Metal device + runtime-compiled engine
  sha256d.metal        #   MSL compute kernel; compiled at startup (no committed blob)
  probe/ kerneltest/ bench/   #   device probe, correctness gate, throughput
cli/                   # package main -> the grotti binary
capture/               # throwaway: record a raw pool session
Makefile               # make / make test / make check / make clean
```

See `CLAUDE.md` for invariants and the wire protocol, `DEVELOPMENT.md` for the phase
plan and test plan.
