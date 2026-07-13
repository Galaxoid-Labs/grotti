# Grotti — Development Plan

Read `CLAUDE.md` first. It holds the invariants and the wire protocol. This file
holds the *how* and the *order*.

---

## Concurrency architecture

### The decision: threads, not `nbio`

`core:nbio` is an event-loop abstraction for **I/O concurrency** — many sockets,
without a thread per socket.

Grotti has **one** socket, carrying a `mining.notify` every ~30s, an occasional
`mining.set_difficulty`, and a `mining.submit` every few seconds. That is not an
I/O scalability problem.

The actual problem is that mining is **100% CPU-bound**. An event loop produces
zero hashes. So:

- **`nbio` is not used.** Not "used later" — it solves a problem Grotti does not
  have, and an async network layer would only complicate the handoff to the
  hashers.
- It becomes the right tool *only* if Grotti ever serves many miners (a pool or
  proxy). That is an explicit non-goal.

### The shape

```
                 ┌──────────────────────────────┐
    TCP  ◄──────►│  Fenja  (1 thread)           │
                 │  blocking recv + timeout     │
                 │  line framing, JSON, state   │
                 └───────┬──────────────▲───────┘
                publish  │              │  drain
                  (job)  │              │  (shares)
                 ┌───────▼──────────────┴───────┐
                 │  job ring (8 slots)          │
                 │  atomic generation counter   │
                 │  MPSC share queue            │
                 └───────┬──────────────▲───────┘
                         │              │
         ┌───────────────┼──────────────┼──────────────┐
         ▼               ▼              ▼              ▼
    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐
    │ Menja 0 │    │ Menja 1 │    │ Menja 2 │ …  │ Menja N │
    │ the stone│   │         │    │         │    │         │
    └─────────┘    └─────────┘    └─────────┘    └─────────┘
```

**Fenja** owns the socket. Nothing else touches it. Blocking `recv` with
`SO_RCVTIMEO` gives us timers for free (reconnect backoff, stale-job detection,
keepalive) without an event loop.

**Menja** threads never touch the socket, never allocate, never lock.

### Job publication: generation counter + ring

Jobs are **immutable once published**. Publication is a store; consumption is a
load. No mutex.

```odin
// Shared, cache-line padded.
Job_Ring :: struct {
    slots: [8]Job,
    gen:   u64,            // atomic. gen % 8 == live slot index.
}
```

- **Fenja publishes:** write `slots[(gen+1) % 8]` fully, then
  `atomic_store_explicit(&gen, gen+1, .Release)`.
- **Menja consumes:** `g := atomic_load_explicit(&gen, .Acquire)`, read
  `slots[g % 8]`.

A slot is not reused until 8 jobs later — by which time no reader is on it. This
sidesteps the seqlock/ABA problem without a retry loop. (8 is arbitrary but
enormous: jobs arrive at ~2/min.)

The `.Release`/`.Acquire` pair is what makes the job's contents visible before
the generation bump is. Do not weaken it to `.Relaxed`.

> **Verify at implementation time:** exact spelling of Odin's atomics —
> `intrinsics.atomic_load_explicit` / `atomic_store_explicit` and the
> `Atomic_Memory_Order` enum members. Confirm against the compiler, don't trust
> this doc.

### The hot loop ("a turn")

The generation check is **outside** the batch, not inside it:

```odin
BATCH :: 1 << 14        // ~16k nonces ≈ a few ms. Tune.

for !quit {
    g := atomic_load_explicit(&ring.gen, .Acquire)
    if g != local_gen {
        load_job(&local, &ring.slots[g % 8])   // rebuild header + midstate
        local_gen = g
    }

    for _ in 0 ..< BATCH {
        // zero atomics, zero allocs, zero branches on shared state
        ...
    }
}
```

Cost of synchronization: one relaxed-ish atomic load per 16k nonces. Effectively
free. Do not put the check inside the inner loop.

`clean_jobs = true` in `mining.notify` means abandon in-flight work — which the
generation bump already accomplishes. `clean_jobs = false` means the old job is
still valid; we still switch, because on this chain job churn is irrelevant to
yield.

### Nonce and extranonce2 partitioning

Each Menja thread **owns a disjoint `extranonce2` stream**, claimed from a
shared atomic counter:

```
thread t claims en2 values where  en2 ≡ t  (mod N)
```

Given an `en2`, the thread builds its own coinbase → merkle root → header →
midstate, then scans the full 2³² nonce space for it.

Why per-thread `en2` rather than splitting the nonce range:

- Threads never collide, with zero coordination.
- Each thread's header differs, so each has its own midstate — computed once per
  2³² nonces, i.e. never, in practice.
- At 5 MH/s, 2³² nonces takes ~14 minutes, and jobs arrive every ~30s. **The
  nonce space is never exhausted.** `en2` rolling is a correctness backstop, not
  a hot path.

Cost: N coinbase+merkle computations per job instead of 1. At N=20 and one job
per 30s, this is noise.

### Share submission

Menja finds a share → pushes to a bounded MPSC ring → Fenja drains and submits.

The queue must be **bounded and non-blocking**. If it's full, drop the share and
count it. A hasher thread must never block on the network.

> **CORRECTED (2026-07-12 live wire):** share difficulty is **1024** and network
> difficulty is **~133,000**, so shares are ~130× easier than blocks — a share is
> NOT usually a block (the original note assumed a tiny chain where the two were
> comparable). Shares are also rare per backend: ~27 min at 2.6 GH/s. The submit
> path still must not block the stone. See `[[live-pool-findings]]`.

---

## The hasher

Three stages, in order. **Do not skip to stage 3.**

### Stage 1 — scalar, obviously correct

Plain `sha256d(header[80])`, straight out of `btcutils` if it's there. Expect
**3–8 MH/s/core**.

**This is already ~5× the entire network on one thread.** Stage 1 is a shippable
miner. Ship it. Stages 2 and 3 are for the engine's sake, not the chain's.

### Stage 2 — midstate + early exit

**Midstate is nearly free in Odin** because structs are value types. If
`btcutils`' SHA-256 is a standard `init/update/final` context:

```odin
base: sha256.Context
sha256.init(&base)
sha256.update(&base, header[:64])      // constant for the whole job

// per nonce:
ctx := base                             // struct copy == midstate restore
sha256.update(&ctx, header[64:80])
sha256.final(&ctx, digest[:])
```

No compression-function surgery, no new crypto. ~2× for a few lines.

**Early exit:** the target check needs `reverse(digest) < target`. So
`digest[31]` (the top byte, once reversed) must be zero for any real target.
Test the final u32 of the second hash and bail before the full compare. Kills
the tail work on ~everything.

Combined stage 2: expect **~2×** over stage 1.

### Stage 3 — SIMD lanes

SHA-256 over independent nonces has **no cross-nonce data dependencies**. So run
8 nonces at once in `#simd[8]u32` lanes: every `ROTR`, `XOR`, `ADD`, `Ch`, `Maj`
is lane-wise. This is how `cpuminer` gets its numbers.

```odin
import "core:simd"
Lane :: #simd[8]u32
```

- State becomes `[8]Lane`, schedule becomes `[16]Lane`.
- The **only** scalar part is the nonce word: broadcast `base_nonce` and add
  `{0,1,2,3,4,5,6,7}`.
- Early-exit becomes a lane mask: reduce the final word, if all 8 lanes non-zero,
  advance. Only unpack lanes on a hit.
- Everything else is a mechanical transliteration of the scalar code.

Expect **4–8×** over stage 2. This is where "fast" actually comes from.

Constraint: **stage 3 must be differentially tested against stage 1 on random
inputs**, not spot-checked. See Test plan.

---

## v2 — GPU backends (selectable)

Backends are **selected at runtime, not at build time.** One binary, no CUDA
build dependency, runs fine on a machine with no GPU at all.

| Backend | Library | Notes |
|---|---|---|
| `cpu` | — | Pure Odin. Always available. **The default.** |
| `cuda` | `libcuda.so.1` | NVIDIA. Best perf on GB10. First GPU backend. |
| `vulkan` | `libvulkan.so.1` | Portable (NVIDIA/AMD/Intel). `vendor:vulkan`. **Done** — correct + integrated, ~1.78 GH/s on GB10 (~70% of CUDA). |
| `opencl` | `libOpenCL.so.1` | Widest reach; proven reference kernels exist. Optional. |

### Runtime loading — `core:dynlib`, not `foreign import`

`foreign import` is a **link-time** dependency: the binary won't start without
`libcuda.so` present. That defeats the entire point of selectable backends.

Use `core:dynlib` instead: `dlopen` the library, resolve symbols into a struct
of proc pointers, and report the backend unavailable if it isn't there.

```odin
import "core:dynlib"

CUDA_API :: struct {
    cuInit:              proc "c" (flags: u32) -> i32,
    cuDeviceGet:         proc "c" (dev: ^i32, ordinal: i32) -> i32,
    cuCtxCreate_v2:      proc "c" (...) -> i32,
    cuModuleLoad:        proc "c" (...) -> i32,
    cuModuleGetFunction: proc "c" (...) -> i32,
    cuLaunchKernel:      proc "c" (...) -> i32,
    cuMemAllocHost_v2:   proc "c" (...) -> i32,
    cuStreamSynchronize: proc "c" (...) -> i32,
    // ~12 total
    _handle: dynlib.Library,
}

cuda_probe :: proc() -> (api: CUDA_API, ok: bool) {
    count, ok2 := dynlib.initialize_symbols(&api, "libcuda.so.1", "", "_handle")
    return api, ok2 && count > 0
}
```

> **Verify:** exact `dynlib.initialize_symbols` signature and whether it matches
> struct field names to symbol names directly. If it doesn't fit, fall back to
> manual `dynlib.symbol_address` per proc — still ~12 lines.

The same pattern covers Vulkan and OpenCL. Each GPU backend is a package that
probes, and either offers itself or doesn't.

### Selection rules

```
grotti -list-backends            # what's actually available on this box + what auto picks
grotti                           # -backend:auto (the default)
grotti -backend:cuda
grotti -backend:cpu,cuda         # both, concurrently
```

**`-backend:auto` is the default and picks the fastest AVAILABLE backend**, in fixed
capability order `cuda > metal > vulkan > cpu`, and *prints the choice*
(`backend=auto → metal`). It never runs a GPU silently or ungoverned. The earlier rule
here — "auto never selects a GPU" — was retired once the governor was understood to make
GPU selection safe: an auto-selected GPU is still capped by the default 500 KH/s governor
(`CLAUDE.md` § 2b), so the danger was never *which* backend runs but *ungoverned* hashing,
which still requires an explicit `-cap:0`. Full reasoning: `CLAUDE.md` § 2c.

`-list-backends` reports availability *and* an estimated hashrate (and what `auto` would
pick), committing to no device — so the choice is informed rather than a surprise.

### Running several backends at once

The seam already supports it: instantiate N backends, each with its **own
`extranonce2` stream** (same `en2 ≡ t (mod N)` partition, now across backends
rather than threads). All feed the same MPSC share queue. Fenja doesn't know or
care which backend found a share.

The governor's cap is **global**, not per-backend. It allocates a per-backend
budget each second, proportional to measured rate, and each backend's token
bucket draws from its slice. A shared atomic bucket would just create contention
on the hot path for no benefit.

### CUDA first, Vulkan second, Metal third

Not either/or — that framing was wrong once backends became selectable. Order is
just effort-per-hash (all three are now done):

- **CUDA** is ~12 FFI procs, one `.cu` file, and hand-tunable `LOP3`. It's the
  actual target hardware.
- **Vulkan** is ~500 lines of setup boilerplate and a SPIR-V compute shader,
  and gives up hand-tuned `LOP3` — but runs on anything. Worth having, worth
  having *second*. **Now done (bring-up):** `vulkan/` mirrors `cuda/`'s Engine
  API, picks the fastest device, drains multi-hits, and is differentially tested.
  Measured ~1.78 GH/s on GB10 vs 2.6 for CUDA (~70%), after unrolling the 64
  rounds via `GL_EXT_control_flow_attributes` `[[unroll]]` so the 16-word schedule
  is scalar-replaced into registers (glslang won't unroll on its own; `spirv-opt`
  didn't help). Remaining gap: SPIR-V→SASS vs nvcc + no LOP3/`__launch_bounds__`.
- **Metal** is macOS/Apple-Silicon GPU, built behind the same seam. **Now done:**
  `metal/` mirrors the Vulkan/CUDA Engine API, compiles the MSL kernel at startup,
  and is differentially tested on hardware. Measured ~0.22 GH/s on an M1 Max — which
  we confirmed is the GPU's *ALU-bound ceiling* for this workload, not an untuned port:
  Apple GPUs lack a hardware funnel-shift, so SHA's rotates cost ~3× the instructions
  (details in Phase 9 and `CLAUDE.md` § macOS / Metal).
- **OpenCL** is mostly interesting because the old cgminer kernels
  (`poclbm`/`phatk` lineage) are proven reference code. Optional.

### The kernel (CUDA)

Same optimizations as the CPU path, one level deeper:

- **Midstate** over `header[0:64]`, computed host-side, passed as 8 words.
- **Constant folding.** Nonce lives at `W[3]` of block B. `W[0..2]`, `W[4..15]`
  are job constants, padding is fixed (`0x80000000`, zeros, length `640`).
  Schedule words not depending on `W[3]` fold host-side. Hash 2's input is a
  fixed-length 32-byte digest, so its padding and early rounds fold too.
- **Early exit** on the final word — same trick, same big win.
- **`LOP3`.** `Ch`/`Maj` are 3-input bitwise ops and map onto `LOP3.LUT`. Check
  the SASS with `cuobjdump -sass`; hand-write `lop3.b32` PTX if nvcc misses it.
- **Registers are the whole game.** Full-unroll 64 rounds, rolling schedule
  window (not a `[64]u32` array), `__launch_bounds__`, check with
  `-Xptxas -v`. Aim ≤64 regs.

Compile `kernel.cu` with `nvcc -cubin -arch=native` as a build step — ship a
real cubin, don't JIT from PTX. Host is aarch64 → SBSA/Arm CUDA toolkit. GB10 is
believed to be `sm_121`; confirm with `deviceQuery`, don't assume.

Irrelevant on purpose: **tensor cores and the headline FP4 petaflop.** SHA-256
is rotate/XOR/add on u32; it cannot be expressed as a matmul. Also irrelevant:
the 273 GB/s unified memory bandwidth — the kernel is pure ALU, memory traffic
is ~zero. You are using the plain shader cores and ignoring most of the machine.

Unified memory *is* a real win for one thing: allocate the result buffer as
zero-copy host-mapped (`cuMemAllocHost`) and have the kernel `atomicAdd` into
it. No `cuMemcpy`, no PCIe round-trip on the result path.

### Two things that differ from every reference miner

**1. Multiple hits per launch — the result buffer is an array, not one slot.**

> **CORRECTION (2026-07-12 live wire).** The original reasoning below assumed share
> difficulty ≈ 0.001 (many shares per launch). The live pool actually sends share
> difficulty **1024**, so a share is ~4.4e12 hashes and a 2^24 launch finds ~0.
> The array-with-atomic-counter design is kept anyway — it costs nothing, and a
> single burst (or an easier future difficulty) can still yield several hits per
> launch, which a one-slot design would silently drop. `scan` still returns `[]u32`.
> See `[[live-pool-findings]]`.

Original reasoning (at the assumed diff 0.001):

```
share difficulty ≈ 0.001  ⇒  ~4.3e6 hashes per share
launch of 2^24 nonces     ⇒  ~16.7e6 hashes
                          ⇒  ~4 shares PER LAUNCH
```

The result buffer is an **array with an atomic counter**; the host drains all of
them. This is why `Backend.scan` returns `[]u32`, not `(u32, bool)`.

**2. The governor can't throttle mid-launch.**

A launch is atomic from the host's perspective. So the governor throttles by
**sizing the launch and sleeping between launches**, not by pacing inside one.
Pick a launch size that's a few milliseconds of work, then let the token bucket
gate the next one. Launch size becomes a governor input, not a tuning constant.

### Correctness

Every GPU kernel is differentially tested against the **scalar CPU hasher** on
random headers — same discipline as SIMD. A kernel that's fast and wrong is
worse than no kernel, and the constant-folding optimizations above are *exactly*
the kind that break silently and produce zero shares forever.

Do not fold a single constant until the naive kernel reproduces a known block
hash.

---

## The governor

Chain safety as a **runtime number**, so the engine can stay fully parallel.

### It paces; it does not de-thread

The cap and the thread count are **independent**. The governor does *not* reduce
parallelism to hit a target — it runs the full thread pool (and the full GPU)
and paces the batches.

- **Wrong:** "cap of 5 MH/s ⇒ run one thread."
- **Right:** run all N threads and every selected backend at full width, and let
  each one's token bucket gate how often it takes a turn.

Reducing threads is coarse (you can only hit N discrete rates), leaves the
engine untested at full width, and means the "fast" path and the "safe" path are
different code. Pacing keeps one code path and makes the cap an arbitrary real
number.

```odin
Governor :: struct {
    cap_hps: f64,        // 0 == UNCAPPED. A first-class mode, not a hack.
    // global; allocates per-backend budgets each second, proportional to
    // measured rate. Each backend/thread has its own token bucket over a
    // monotonic clock — no shared atomic on the hot path.
}
```

After each turn, a worker computes how long that batch *should* have taken at
its slice of `cap_hps` and sleeps the difference. GPU backends can't pace inside
a launch, so for them the governor sizes the launch instead (see § v2).

### Defaults, not restrictions

- `cap_hps` defaults to a conservative value (≈ observed network hashrate).
- **`--cap=0` is uncapped** and fully supported — it's one flag, and it's the
  right setting the moment LTL confirms the chain can absorb it.
- Startup logs `estimated_share_of_network`. Refuses >1.0× without
  `--i-know-what-im-doing`.

The point is that the *unsafe* setting is deliberate rather than accidental. It
is not that the unsafe setting is unavailable.

The governor is deliberately crude. It does not need to be precise; it needs to
be *on by default and impossible to disable by accident*.

---

## Dependency audit — do this first

Before Phase 1, answer these against the real code. Delete whatever's already
solved; the phase plan assumes the worst case.

**`btcutils`:**

- [ ] `sha256d` over a byte slice
- [ ] SHA-256 as an `init/update/final` **context struct** (needed for the
      cheap midstate in stage 2 — if it's only a one-shot `sha256d(bytes)`,
      midstate needs real work)
- [ ] 80-byte header type + LE serialization
- [ ] compact bits (`nbits`) ↔ 256-bit target
- [ ] 256-bit target comparison
- [ ] merkle root / branch folding
- [ ] CompactSize varint
- [ ] anything already handling internal-vs-display byte order

**`netutils`:**

- [ ] TCP connect / read / write (blocking is fine — preferred, even)
- [ ] socket read **timeout** (needed for timers without an event loop)
- [ ] line-delimited framing, or a read buffer I can split on `\n`
- [ ] JSON-RPC request/response with ID matching
- [ ] **does it tolerate server-initiated notifications with `id: null`?**
      ← the one that will break everything if it doesn't

**Likely missing from both** (Grotti writes these regardless):

- Stratum's prevhash word-swap (Stratum-specific, not Bitcoin-specific)
- The coinbase splice `coinb1 || en1 || en2 || coinb2`
- Fractional-difficulty → target (`diff < 1` on this chain!)
- The SIMD hasher

---

## Phases

### Phase 0 — Ground truth *(blocking; do not skip)*

1. Run the dependency audit above.
2. **Ask LTL:** does the chain have testnet/signet 20-minute min-difficulty
   reset rules? What hashrate can it absorb? *This gates whether we may connect
   at all.*
3. Get a Thunder address: `thunder-cli get-new-address`.
4. Capture a **real session trace**. Point any existing miner (or a 30-line
   Python socket script) at the pool and dump the raw JSON lines to a file.
   That trace is the fixture for everything downstream. Do not develop against
   an imagined protocol.

### Phase 1 — Fenja, offline

Stratum state machine + JSON-RPC codec, driven entirely by the Phase 0 trace and
the loopback test server. No hashing yet.

- connect → `subscribe` → `authorize` → receive `set_difficulty` + `notify`
- notification handling (`id: null`)
- reconnect with exponential backoff
- **Exit criterion:** replays the captured trace, produces the correct `Job`
  structs, submits a hardcoded share and parses the response.

### Phase 2 — Job construction

`notify` → 80-byte header. This is where the bugs are. Byte-order tests before
implementation, not after.

- prevhash word-swap
- coinbase splice, merkle fold
- version/nbits/ntime BE-hex → LE u32
- fractional difficulty → target
- **Exit criterion:** given a real `notify` + a known-good `en2`/`ntime`/`nonce`
  from the Phase 0 trace, we reconstruct the header and reproduce the exact
  block hash the pool accepted.

### Phase 3 — Menja, stage 1

Scalar hasher, single-threaded — **as a milestone, not a design.** The smallest
thing that can prove the whole pipeline end-to-end. Multithreading lands in
Phase 4 and is the real shape.

Nonce loop, share detection, submit.

- **Exit criterion:** *a share accepted by the live pool.* This is the real
  milestone. Everything before it is theatre.

### Phase 4 — Concurrency + the Backend seam

Job ring, generation counter, N threads, per-thread `en2`, MPSC share queue.

**Introduce `Backend` here**, with the CPU as its only implementation, and put
the governor above it. There is only one backend right now — build the seam
anyway. Retrofitting it in v2 means rewriting the governor and the share path.

- **Exit criterion:** N threads, zero duplicate shares, zero rejects over an
  hour. Race detector / thread sanitizer clean. Governor demonstrably caps.

### Phase 5 — Speed (CPU)

Midstate → early exit → SIMD. Benchmark each step; reject any change that
doesn't move H/s.

- **Exit criterion:** stage 3 is bit-identical to stage 1 across 10⁶ random
  headers, and ≥4× faster.

### Phase 6 — Ops

Stats, logging, `--cap`, clean shutdown, README. **v1 ships here.**

### Phase 7 — v2: CUDA backend  ✅ DONE

> Implemented on the GB10 (compute 12.1, `sm_121`), ~2.6 GH/s. `cuda/dynlib.odin`
> (runtime probe), `cuda/kernel.cu` (midstate + register-resident schedule, built to
> `cuda/kernel.cubin`, embedded via `#load`), `cuda/backend.odin` (host engine), and
> `cuda_worker.odin` (peer to the CPU workers, with extranonce2 rolling since the GPU
> sweeps 2^32 nonces in ~1.7s). Validated by `cuda/kerneltest` (reproduces block
> 125552 and matches the CPU `scan_simd` hit-for-hit). Remaining headroom: constant
> folding of the nonce-independent schedule words, `LOP3`, launch overlap.

See § v2 above. Order matters:

1. `cuda/dynlib.odin` — `core:dynlib` probe, resolve the ~12 driver-API symbols,
   load a trivial cubin and launch it. **Prove the FFI before writing crypto.**
   Also: prove the probe fails *gracefully* on a box with no `libcuda.so.1`.
2. **Naive kernel.** No midstate, no folding, no early exit. Reproduce a known
   block hash. This is the correctness anchor.
3. Wire it to `Backend`. Multi-hit result buffer. Launch-size as a governor
   input. Get a share accepted from the GPU, **capped**.
4. *Then* optimize: midstate → constant folding → early exit → `LOP3` →
   register tuning. Differential test against the scalar hasher after **every**
   step.

- **Exit criterion:** bit-identical to the scalar hasher across 10⁶ random
  headers; sustained GH/s measured; `-backend:cpu,cuda` runs both under one
  global cap; and — non-negotiable — the governor still holds it to the
  configured rate.

### Phase 8 — Vulkan backend (optional)

Portability, once CUDA has proven the seam. GLSL compute shader → SPIR-V,
`vendor:vulkan`, same `Backend` interface, same differential tests.

Expect materially more setup code than CUDA and somewhat lower throughput. Worth
it only if Grotti needs to run on non-NVIDIA hardware — which today it doesn't.

### Phase 9 — Metal backend (macOS / Apple Silicon) — DONE (2026-07-13, M1 Max)

**Shipped and validated.** `metal/` package (`metalbackend`, `#+build darwin`) + `metal_worker.odin`
(with a `#+build !darwin` stub keeping package grotti portable). Runtime-compiled MSL kernel
(`newLibraryWithSource`), unified-memory shared buffers, per-scan autorelease pool. Correctness
gate `metal/kerneltest` PASSES (block-125552 anchor + bit-exact differential vs `scan_simd`).
~0.22 GH/s on an M1 Max (compute-bound). Full write-up: **CLAUDE.md § macOS / Metal**. The one
open item is a live-pool share-acceptance test. Original design notes below.

Native GPU mining on Apple Silicon. Odin already ships the bindings
(`vendor:darwin/Metal` + `Foundation` + `QuartzCore`), and this drops in behind the
same seam as CUDA.

- **Kernel:** an MSL (`.metal`) compute shader — a near-direct port of `cuda/kernel.cu`
  (midstate + rolling schedule + atomic hit buffer). MSL is C++-flavored, so it
  translates almost line-for-line.
- **Host:** `metal/` package — `MTLDevice`, command queue, compute pipeline, buffers,
  `dispatchThreadgroups`, drain the hit buffer. A `metal_worker.odin` peer to
  `cuda_worker.odin`, feeding the same ring / governor / share queue.
- **Simpler than CUDA in two ways:** (1) compile the MSL from an embedded source string
  at runtime (`newLibraryWithSource`) — no fatbin, no per-arch `-gencode`, Metal
  handles GPU generations; (2) link `Metal.framework` directly (`foreign import`, not
  `dlopen`) — fine, because Metal is always present on macOS, so there's no
  "refuse-to-start" concern.
- **Platform note:** macOS-only (Metal is Apple's API), so a macOS build ships Metal
  where a Linux build ships CUDA — they don't coexist in one binary. The rest of the
  engine (SIMD CPU hasher, stratum, governor, keygen) is pure `core:` and already
  cross-platform, so **CPU mining on macOS very likely works today** (untested); Metal
  is the one missing piece for macOS *GPU* mining. Differentially tested against the
  scalar hasher, same discipline as CUDA. Throughput on an M-series GPU: below a GB10,
  well above CPU.

---

## Test plan

Correctness here is not a matter of taste. Byte order has no "mostly right."

### 1. The oracle

Every hasher stage is differentially tested against `core:crypto/sha2` on random
inputs. Not fixtures — **randomized, in a loop, in CI.**

```odin
@(test)
test_sha256d_matches_core :: proc(t: ^testing.T) {
    for _ in 0 ..< 100_000 {
        buf: [80]u8
        crypto.rand_bytes(buf[:])
        testing.expect_value(t, ours(buf[:]), oracle(buf[:]))
    }
}
```

Then `simd` vs `scalar`, same shape. A SIMD hasher that's fast and wrong is
worse than useless.

### 2. Known block

Reproduce a real Bitcoin block hash from its header. Block **125552** is the
canonical vector. **Pull the actual header bytes from a node** — do not trust
hex transcribed from memory or from a chat log, including this one.

This test catches header-layout errors that the SHA tests cannot.

### 3. Byte-order fixtures

One test per conversion, each with a real-data fixture:

- prevhash word-swap round-trips
- version/nbits/ntime BE-hex → LE u32 → back
- merkle fold against a block with a known multi-branch tree
- fractional difficulty → target (**explicitly test `diff = 0.001`**, which this
  chain will actually send, and which naive `diff1 / u64(diff)` implementations
  get catastrophically wrong)

### 4. Loopback stratum server

`testutil/loopback.odin` — a fake pool that speaks the real dialect, replaying
the Phase 0 trace. Lets us test reconnect, stale jobs, `clean_jobs`, vardiff
changes and malformed input **without touching the live chain.**

Deliberately hostile cases: truncated line, two JSON objects in one `recv`,
one object split across two `recv`s, `id: null` where a response was expected.

### 5. Chain-safety test

Assert the governor actually caps. Set `cap_hps = 1_000_000`, run 60s, assert
measured rate is within 5%. A governor that silently doesn't work is the worst
possible bug in this program.

---

## Open questions

1. **Does the chain have min-difficulty reset rules?** *Blocks Phase 0.* If not,
   the governor is load-bearing and the default cap must be conservative.
2. What does `btcutils`' SHA-256 API actually look like — one-shot or context?
   Decides whether stage-2 midstate is 5 lines or 150.
3. Does `netutils`' JSON-RPC tolerate `id: null` notifications?
4. Live share difficulty — the repo's `vardiff_min = 1.0` is clearly not what
   the deployed PPS build uses. Confirm from a real session (Phase 0 trace).
5. Should Grotti eventually drive `getblocktemplate` against Forseti directly
   (solo mode)? Deferred — but keep `job.odin` free of Stratum assumptions so
   the seam exists.
