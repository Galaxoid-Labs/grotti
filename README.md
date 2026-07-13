# Grotti

A Stratum V1 miner in pure Odin — CPU (SIMD), NVIDIA GPU (CUDA), and portable GPU
(Vulkan) backends in one binary, with no build-time GPU or C dependency (GPU drivers are
loaded at runtime). Connects to LayerTwo Labs' `simplepool` on the BIP300/301 drivechain
test network.

> In *Grottasöngr*, King Fróði's mill **Grotti** grinds out gold, turned by two
> giantesses who are never allowed to rest. There is no better description of
> proof-of-work. **Fenja** is the stratum client that feeds the mill; **Menja** is
> the hasher that turns the stone.

**Status:** working, verified against a live pool session. It connects, authorizes,
receives real jobs, hashes them under a hashrate governor, submits shares, and flags a
found block. The CPU SIMD engine does ~8.4 MH/s per thread; the CUDA backend does
~2.6 GH/s on an NVIDIA GB10. A portable **Vulkan** backend (NVIDIA/AMD/Intel) is wired in
and correct — ~1.78 GH/s on the same GB10 (~70% of the CUDA path, after the shader's SHA
schedule was made register-resident). 56 tests pass, and the CPU, CUDA, and Vulkan hashers
are each differentially tested against `core:crypto/sha2` / the CPU scan.

---

## Build

```sh
odin build cli -out:grotti -o:speed     # -o:speed is mandatory for hashrate
```

> Don't name the binary `grotti` if you also run `odin test .` in this directory —
> the test runner's temporary binary is named after the package and will clobber it.
> Use `-out:bin/grotti` or any other name.

## Quick start

You need a Thunder address for `-user` (generate one with `./grotti keygen` — see
below). Then:

```sh
./grotti -user:<thunder-addr>.<rig>      # gentle defaults: 4 threads, 500 KH/s cap
```

Or put `user` (and anything else) in a `grotti.conf` next to the binary and just run
`./grotti`. Grotti **refuses to start without a username** — no address is baked in.
Press **Ctrl-C** to stop cleanly.

### Examples

```sh
# GPU at 25% — just give -cap a percentage
./grotti -backend:cuda -cap:25

# GPU at half speed
./grotti -backend:cuda -cap:50

# Full tilt (uncapped)
./grotti -backend:cuda -cap:0

# Portable GPU via Vulkan (NVIDIA / AMD / Intel) — picks the fastest device
./grotti -backend:vulkan -cap:25

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
| `-pool:ENDPOINT` | `pool.drivechain.info:3334` | stratum pool — `host:port` or `stratum+tcp://host:port` |
| `-user:addr.rig` | **required** | `<thunder-addr>.<rig>` for `mining.authorize` (or set in `grotti.conf`) |
| `-backend:LIST` | `cpu` | `cpu` \| `cuda` \| `vulkan` \| comma-combo — never auto-selects the GPU |
| `-threads:N` | `4` | CPU worker threads |
| `-cap:N` | `500000` | **`0`** = uncapped · **`1–100`** = percent of max (e.g. `-cap:25`) · **`>100`** = raw H/s |
| `-color:MODE` | `auto` | `auto` \| `always` \| `never` |

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

**GPU backend:** the CUDA driver is `dlopen`'d at runtime — no build-time CUDA
dependency, and a GPU-less box runs fine. It's opt-in (`-backend:cuda`); a bare
`./grotti` is always CPU. The GB10 does ~2.6 GH/s (~300× a CPU thread).

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

**Portability / CI:** the CPU and Vulkan backends are cross-platform. The only OS-specific
code (TTY detection + color enabling, Ctrl-C) lives in per-OS files. The CUDA backend
remains Linux-only (`libcuda.so.1`); on Windows, Vulkan covers the NVIDIA card too. A native
Windows `.exe` links on a Windows host (Odin can't cross-link one from Linux, though it
type-checks the target), so CI builds it on a `windows-latest` runner. `.github/workflows/ci.yml`
tests and builds `grotti` for `linux-x86_64`, `linux-arm64`, and `windows-x86_64` on every
push and publishes all three on a `v*` tag. See `CLAUDE.md` § Windows for a first-run checklist.

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
| **GPU (GB10)** | ~2.6 GH/s | **~27 minutes** |

The live status line shows a running estimate from your current rate and difficulty —
`share ~28m · block ~2.5d` — so you can see roughly how long the wait is (it shrinks
as the pool's vardiff lowers your share difficulty).

You appear on the pool dashboard once your first share is accepted. A **block** (the
hash also clears the ~133k network target) is far rarer — ~2.5 days of solo GPU time —
but Grotti checks every hit against the network target locally and prints a bold-green
`🎉 BLOCK FOUND` line if you land one.

---

## Tests

```sh
odin test .                # engine: target, job, governor, ring, fenja, stats, ...
odin test sha256d          # the optimized CPU hasher vs core:crypto/sha2
odin run cuda/kerneltest   # CUDA kernel: reproduces a known block, matches the CPU
odin run vulkan/kerneltest # Vulkan shader: reproduces a known block, matches the CPU
```

## Layout

Odin: a directory is a package.

```
*.odin                 # package grotti — engine, governor, stratum, console
  target.odin          #   difficulty <-> 256-bit target (fractional-safe)
  job.odin             #   Job, header build + byte-order conversions
  menja.odin           #   the stone: scalar + SIMD nonce scan, block detection
  menja_worker.odin    #   CPU worker threads (per-thread extranonce2)
  cuda_worker.odin      #   CUDA worker: launches the kernel, rolls extranonce2
  vk_worker.odin       #   Vulkan worker: same shape as cuda_worker
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
cli/                   # package main -> the grotti binary
capture/               # throwaway: record a raw pool session
```

See `CLAUDE.md` for invariants and the wire protocol, `DEVELOPMENT.md` for the phase
plan and test plan.
