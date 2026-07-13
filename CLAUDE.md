# Grotti

A Stratum V1 CPU miner in pure Odin.

> In *Grottasöngr*, King Fróði owns a millstone called Grotti and two giantess
> slaves, Fenja and Menja, who turn it. The mill grinds out whatever it is asked
> for. He sets it to grind **gold**, and forbids the women to rest longer than
> the space of a cuckoo's call. They grind without stopping.
>
> An endless mill that produces gold, powered by labour that is never permitted
> to halt. There is no better description of proof-of-work.

**Grotti** is the mill. **Fenja** is the stratum client that feeds it work.
**Menja** is the hasher that turns the stone.

---

## What this is

A correct, fast, single-binary Stratum V1 miner. Target pool:
`stratum+tcp://pool.drivechain.info:3334` (LayerTwo Labs' `simplepool`, a
BIP300/301 drivechain test network).

**Backends** — selected at runtime, not at build time. One binary; no CUDA build
dependency; runs on a box with no GPU.

| | Backend | Library | Status |
|---|---|---|---|
| **v1** | `cpu` | — | Pure Odin, scalar → midstate → SIMD. **Default. Done.** |
| **v2** | `cuda` | `libcuda.so.1` | NVIDIA / GB10. **Done — ~2.6 GH/s.** (`cuda/`) |
| **v2** | `vulkan` | `libvulkan.so.1` | Portable (NVIDIA/AMD/Intel). `vendor:vulkan`. **Bring-up done — correct, ~0.86 GH/s on GB10; shader perf pending.** (`vulkan/`) |
| *opt* | `metal` | `Metal.framework` | macOS / Apple Silicon. Roadmap (DEVELOPMENT.md § Phase 9). |
| *opt* | `opencl` | `libOpenCL.so.1` | Widest reach. Optional. Not started. |

GPU libraries are `dlopen`'d via `core:dynlib` — **never `foreign import`**, which
would make the binary refuse to start without CUDA installed.

**It is not:**

- a pool or proxy (no `nbio`, no many-socket event loop; if that changes, revisit)
- a Stratum V2 client
- anything that touches consensus code

## What this is for

Two things, in order:

1. **Producing blocks on a drivechain test network** so Thunder/BIP300 work has
   a hashrate source.
2. **Exercising Forseti's primitives** — header serialization, `sha256d`, merkle
   roots, compact-bits↔target. Grotti is a consumer of that code, and a second
   implementation is a second opinion on whether it's right.

---

## Hard invariants

These are not negotiable. If a change violates one, the change is wrong.

### 1. Grotti never writes consensus code

Grotti consumes `btcutils`. It does not fork it, does not optimize it in place,
does not add a "fast path" to it.

A bug in a miner's fast path costs a rejected share. **The identical bug in
consensus code costs a chain split.** Forseti's hasher stays boring, general and
obviously correct. Grotti is allowed to be the clever one, in its own package,
behind its own tests.

Grotti's optimized SHA-256 lives in `grotti/sha256d/` and is validated against
`core:crypto/sha2` on every build. It is never imported by Forseti.

### 2. Chain safety is a first-class feature, not an afterthought

> **UPDATED 2026-07-12 from a live session** (`capture/main.odin`, fixture in
> `real_notify_test.odin`). The numbers below were a 2026-07 snapshot at difficulty
> 0.56; the wire now says otherwise. **Trust the wire.**
>
> | | 2026-07 snapshot (stale) | live wire (2026-07-12) |
> |---|---|---|
> | Share difficulty | ~0.56, fractional (<1) | **1024** (integer) |
> | Network difficulty (nbits) | ~0.56 | **≈133,000** (`0x1a7e2500`) |
> | Work per block | ~2.4 GH | **≈5.7×10¹⁴ hashes** |
>
> At difficulty 133,000 a full CPU (~168 MH/s) is **~39 days per block solo** — NOT
> a chain-bricking threat. The original fear below assumed a tiny chain. **OPEN,
> for LTL:** the dashboard's ~800 KH/s is inconsistent with diff 133k (→ ~22-yr
> blocks) unless the mainchain is merge-mined / externally secured. The governor
> stays on by default (cheap insurance), but the *default cap* is almost certainly
> far too conservative now — do not finalize it until LTL resolves the
> hashrate-vs-difficulty discrepancy. See `[[live-pool-findings]]`.

The reasoning that made the governor load-bearing, preserved from the 0.56-difficulty
snapshot (a **single** Odin thread at 5 MH/s was ~6× the entire network; the full CPU
~100×; a GPU ~3,500×):

If Grotti overwhelms the chain, difficulty retargets upward (clamped 4× per
2016-block epoch). When Grotti stops, the residual ~865 KH/s must grind 2016
blocks at the inflated difficulty before it can drop 4×. **That is centuries.
The chain is bricked.**

Therefore:

- **The governor is on by default.** `hashrate_cap` defaults to a value at or
  below the current network hashrate. Uncapped operation requires explicit
  opt-in.
- Grotti logs its share of estimated network hashrate on startup and refuses to
  run above `1.0×` without `--i-know-what-im-doing`.
- **OPEN QUESTION, blocking first connection:** does this chain implement the
  testnet3/signet 20-minute minimum-difficulty reset rule? If yes, all of the
  above is belt-and-braces. If no, it is load-bearing. *Ask LTL before pointing
  anything at the pool.*

### 2b. The governor sits ABOVE the backend seam

This is what makes a GPU backend permissible at all.

```
        Fenja ─► job ring ─► Governor ─► Backend (CPU | CUDA)
                             ▲
                    the cap lives HERE
```

The governor must never be reimplemented per-backend, and a backend must never
be able to bypass it. A backend's only job is: *scan this nonce range, tell me
what you found.* How fast it goes is not its decision.

A 3 GH/s CUDA engine capped at 500 KH/s is safe. The same engine uncapped is a
chain-bricking event. The difference is one layer of indirection, and it is not
optional.

### 2c. Auto-detect never selects a GPU

If `--backend` is omitted, Grotti runs on **CPU**. Full stop — even if a GB10 is
sitting right there, idle, detected, and reported by `--list-backends`.

A user who did not ask for 3 GH/s must not receive 3 GH/s. Convenience
auto-selection is how someone bricks a chain by running `grotti` with no
arguments. Availability is *reported*; it is never *assumed*.

```
grotti                        # cpu. always.
grotti --list-backends        # shows cuda is available + est. hashrate
grotti --backend=cuda         # explicit. still governed.
grotti --backend=cpu,cuda     # both, one global cap between them.
```

### 3. No allocation in the hot loop

The nonce loop allocates nothing, locks nothing, and syscalls nothing. Every
buffer is preallocated per-thread at job-load time. Violations are a defect, not
a style preference.

### 4. Correctness is proven, not asserted

Every byte-order convention (and there are many, and they disagree) has a test
with a fixture from a real block. See `DEVELOPMENT.md` § Test plan. The
optimized hasher is differentially tested against `core:crypto/sha2` — not
merely spot-checked.

---

## The protocol

Verified by reading `LayerTwo-Labs/simplepool` (~1300 LOC C11), not by guessing.

**It is vanilla Stratum V1.** There is *nothing* drivechain-specific on the
wire. BIP301 commitments are built into the coinbase server-side; Grotti never
sees them and never needs to.

### Methods

| Direction | Method | Params |
|---|---|---|
| C→S | `mining.configure` | `[[exts], {ext params}]` — optional, BIP310 |
| C→S | `mining.subscribe` | — |
| C→S | `mining.authorize` | `[<thunder-addr>[.<rig>], <ignored>]` |
| C→S | `mining.submit` | `[worker, job_id, en2, ntime, nonce]` (+ `version`) |
| S→C | `mining.set_difficulty` | `[diff]` — notification, `id: null` |
| S→C | `mining.notify` | see below — notification, `id: null` |

**The JSON-RPC client MUST tolerate server-initiated notifications with
`id: null`.** A strict request/response client will choke. This is the first
thing to check in `netutils`.

> **Generating a Thunder address (local dev note, not in the public README).**
> The `<thunder-addr>` for `mining.authorize` is a base58-encoded 20-byte address:
> `base58( blake3_xof( ed25519_pubkey )[0:20] )`, where the key comes from a BIP39
> seed via the ed25519-HD path `m/1'/0'/0'/1'` (the first address a fresh wallet
> hands out). Generate one **offline** (no node/RPC) with the example added to a
> local `thunder-rust` checkout:
> `cargo run -p thunder --example gen_address` (optionally `-- "<12-word mnemonic>"`
> to recover). This lives in a personal `thunder-rust` fork, so it's kept out of the
> public README. The wallet mnemonic is the user's secret — never request or store it.

### `mining.subscribe` reply

```
[[["mining.set_difficulty","sd"],["mining.notify","sn"]], <extranonce1_hex>, 4]
```

- `extranonce1` = **4 bytes**
- `extranonce2_size` = **4 bytes**

### `mining.notify` params, in order

```
[ job_id, prevhash, coinb1, coinb2, merkle_branch[], version, nbits, ntime, clean_jobs ]
```

### Version rolling

`mining.configure` supports `version-rolling` (BIP310). Server mask is the
standard BIP320 `0x1fffe000`. The rolled version goes in an **optional 6th
`mining.submit` param**. *Not needed for v1* — the search space is already
absurdly oversized for this difficulty. Support it later, if ever.

### Vardiff

Server-side, and it works: target 12 shares/min, 30s window, ≤4× step per
retarget, deadband at [0.5×, 2×]. `vardiff_max` is clamped by network difficulty
— on this chain that means share difficulty is pinned *below 1*. Grotti must
therefore handle **fractional difficulty** (`diff < 1.0` ⇒ `target > diff1`).
Do not assume `diff >= 1`.

> Caveat: the repo's `main` is the **solo build**; the live pool runs the
> **PPS-classic build**. Wire protocol is the same, config defaults are not.
> Trust the wire, not the repo's `config.c`.

---

## Byte order — read this before writing a single line

This is where every Stratum bug lives. Three different conventions are in play
simultaneously.

### Header layout (80 bytes)

| Offset | Field | Encoding |
|---|---|---|
| `[0:4]` | version | u32 **LE** |
| `[4:36]` | prev_hash | 32B internal order |
| `[36:68]` | merkle_root | 32B internal order |
| `[68:72]` | ntime | u32 **LE** |
| `[72:76]` | nbits | u32 **LE** |
| `[76:80]` | nonce | u32 **LE** |

### The conversions

- **`prevhash`** arrives **word-swapped**: each 4-byte word is byte-reversed,
  word order preserved. **Reverse each 4-byte group again** to recover header
  bytes. `simplepool`'s own source comments warn that getting this wrong makes
  every share reject as "low difficulty." It is the #1 bug.

- **`version`, `nbits`, `ntime`** arrive as **big-endian hex** of a u32. The
  header stores them **little-endian**. Parse hex → u32 → write LE.

- **`merkle_branch[]`** entries are already in internal order. Fold directly, no
  reversal.

- **`nonce` in `mining.submit`** is **big-endian hex** of the u32, even though
  the header stores it LE. Same for `ntime`.

### Coinbase and merkle

```
coinbase = coinb1 || extranonce1 || extranonce2 || coinb2
root     = sha256d(coinbase)
for branch in merkle_branch:
    root = sha256d(root || branch)      // current ALWAYS on the left. Never sort.
```

### Target check

```
diff1  = 0x00000000FFFF0000000000000000000000000000000000000000000000000000
target = diff1 / difficulty            // difficulty may be < 1 → target > diff1
hash   = reverse(sha256d(header))      // 32B, now big-endian
accept if mem.compare(hash, target) < 0
```

Comparing equal-length big-endian byte strings with `memcmp` *is* a correct
256-bit integer comparison. Use it.

**Early exit:** test the hash's leading big-endian word against the *target's*
leading word and bail if it is larger, before the full 256-bit compare. This is
the single biggest hot-loop win.

> **CORRECTION (verified in code).** The naive form — "the top word must be zero,
> so bail unless the final digest word is zero" — is **wrong on this chain** and
> silently discards valid shares. It only holds when the target's top word is
> zero, i.e. difficulty ≥ 1. Here difficulty is < 1, so `target > diff1` and the
> target's leading word is **nonzero**. The early exit must therefore compare
> against the target's leading word, not against zero.
>
> Byte-order note: the hasher's final state word `s2[7]` is not the hash's leading
> word — the leading big-endian word is `byteswap(s2[7])`. Compare *that* to
> `u32be(target[0:4])`. See `menja.odin` `scan_simd` and its differential test
> against `scan_scalar`, which caught exactly this.

### Submit echo rule

The `extranonce2` and `ntime` you submit **must be byte-identical to what you
hashed.** The server rebuilds your coinbase from them. Any mismatch, however
semantically equivalent, is a rejected share.

---

## Layout

Odin: **a directory is a package.** No `src/`.

```
grotti/
  CLAUDE.md  DEVELOPMENT.md  README.md
  grotti.odin              # package grotti — public API, config
  fenja.odin               # stratum client: connection, framing, state machine
  fenja_jsonrpc.odin       # message encode/decode, notification handling
  job.odin                 # Job type, notify → Job, coinbase splice, merkle, header
  target.odin              # difficulty ↔ 256-bit target (fractional-safe)
  backend.odin             # the Backend seam + registry. All engines implement it.
  menja.odin               # cpu backend: hasher threads, nonce loop, batching
  ring.odin                # lock-free job publication (generation counter + ring)
  governor.odin            # GLOBAL hashrate cap — above the backends, never inside one
  stats.odin               # H/s estimate, accepted/rejected, uptime
  errors.odin
  sha256d/                 # package sha256d — the optimized CPU hasher, ISOLATED
    sha256d.odin           # scalar + midstate
    simd.odin              # #simd[8]u32 lanes
    sha256d_test.odin      # differential vs core:crypto/sha2
  cuda/                    # package cuda — v2
    dynlib.odin            # core:dynlib probe → CUDA_API proc-pointer struct
    backend.odin           # Backend impl: module load, launch, multi-hit drain
    kernel.cu              # the only non-Odin file in the repo
    kernel_test.odin       # differential vs sha256d (scalar)
  vulkan/                  # package vulkan — v2, second
    backend.odin
    sha256d.comp           # GLSL → SPIR-V
  cli/                     # package main → the `grotti` binary
    main.odin
  testutil/
    loopback.odin          # fake stratum server for integration tests
    vectors.odin           # real-block fixtures
  tests/
```

### The Backend seam

Defined in v1, even though v1 ships only `cpu`. Retrofitting this later means
rewriting the governor and the share path — do it now.

```odin
Backend :: struct {
    name:      string,
    probe:     proc() -> (available: bool, est_hps: f64),  // dlopen, don't commit
    init:      proc(^Backend, Backend_Config) -> Error,
    load_job:  proc(^Backend, ^Job) -> Error,          // header prefix, midstate, target
    scan:      proc(^Backend, start: u32, count: u32,  // scan a nonce range...
                    hits: []u32) -> (n_hits: int),     // ...report EVERY hit
    destroy:   proc(^Backend),
}
```

Two things that look wrong and aren't:

- **`scan` returns an array of hits, not one.** See `DEVELOPMENT.md` § v2 — on
  this chain a single GPU launch typically finds *several* shares, which inverts
  the assumption every reference miner is built on. A single result slot
  silently discards most of them.
- **`probe` is separate from `init`.** `--list-backends` must be able to report
  availability without committing to a device or allocating anything.

Backends run **concurrently** if selected. Each gets its own `extranonce2`
stream; all feed one MPSC share queue. Fenja never knows which one found a
share.

## Dependencies

**Core only.** Grotti has no third-party runtime dependencies. Everything the
miner consumes from a Stratum V1 pool is small enough to own outright, and owning
it sidesteps the two traps below.

| Need | Source |
|---|---|
| TCP | `core:net` |
| JSON | `core:encoding/json` |
| Hex | `core:encoding/hex` |
| SHA-256 **oracle** | `core:crypto/sha2` — tests only, never the hot loop |
| Threads / atomics | `core:thread`, `core:sync`, `base:intrinsics` |
| SIMD | `core:simd` |
| sha256d (hot loop) | **`grotti/sha256d/`** — ours, differentially tested |
| header ser, coinbase splice, merkle fold | inline in `job.odin` — fixed layouts, no varint needed |
| compact-bits ↔ target | inline in `target.odin` — small, self-contained, fractional-safe |
| stratum framing + JSON-RPC | inline in `fenja.odin` / `fenja_jsonrpc.odin` |

No FFI, no C, no `vendor:` **in the core miner**. The optional GPU backends are the sole
carve-out: `cuda/kernel.cu` (CUDA C) and `vulkan/` (`vendor:vulkan` — Odin's bundled
bindings: types + a proc-pointer loader — plus a GLSL shader). Both GPU libraries are
still `dlopen`'d, never `foreign import`'d, so the binary starts with no GPU library
present and the no-runtime-dependency invariant holds. No `btcutils`, no `netutils`.

**Why not `btcutils` / `netutils`?** Neither exists yet, and the miner needs so
little from either that writing it ourselves is less work than auditing a
general-purpose package into a narrow role:

- **`netutils` (JSON-RPC codec)** is a *liability*, not a shortcut. A generic
  JSON-RPC client is built around request→response correlation and chokes on the
  server-initiated notifications (`id: null`) that Stratum depends on — see
  § The protocol. We need `core:net` + a thin framing/dispatch layer, and that
  layer must treat `id: null` as a notification by design.

- **`btcutils` (consensus primitives)** never touches the runtime path anyway —
  invariant #1 forbids importing it into the hasher, and the hot loop uses
  `grotti/sha256d/` regardless. Its *only* future role is as a **test-only
  differential oracle** (purpose #2: a second opinion on Forseti's primitives),
  alongside `core:crypto/sha2`. That is optional and gated on the package ever
  existing; `core:crypto/sha2` is a sufficient oracle on its own. **Not a Phase 1
  blocker.**

---

## Build

```
odin build cli -out:grotti -o:speed
odin test .                    # unit
odin test sha256d              # differential hasher tests
odin test . -all-packages
```

`-o:speed` is mandatory for anything hashrate-related. Never benchmark a debug
build.

---

## Console output

An operator watching Grotti run is watching for exactly two things: **am I about
to brick the chain**, and **are my shares being accepted or silently rejected**.
The output is designed so neither can be missed at a glance. Logging lives in
`stats.odin` + a small output helper, fed by events Fenja and the stats thread
emit.

### The stone never logs

Invariant #3 extends here: the hot loop formats no strings, holds no output lock,
and touches no `stdout`. It reports hits; Fenja and the stats thread do all
rendering. A log call inside the nonce loop is a defect.

### Two channels

1. **Event log** — scrolling, timestamped, leveled. Discrete events: connect,
   subscribe, authorize, new job, difficulty change, share result, reconnect,
   errors, block found.
2. **Live status line** — a single line that **repaints in place** (carriage
   return) on a TTY, carrying the continuously-changing figures: hashrate,
   shares, governor utilization, uptime, current job.

```
◆ 498 KH/s · shares 41✔ 1✘ (97.6%) · gov 99.6% · up 07:41 · job 3f9b
```

When stdout is **not** a TTY, the repainting line degrades to a plain heartbeat
line emitted every ~10s — no terminal control codes ever reach a file or
journald.

### Color

Emit ANSI color only when **all** hold: stdout is a TTY, `NO_COLOR` is unset,
and `TERM != dumb`. A `--color=auto|always|never` flag overrides (default
`auto`). The same "is this an interactive terminal" decision gates both color
and the repainting status line, so piped output is always clean plain text.

Color is meaning-first, never decoration:

| Element | Color |
|---|---|
| timestamp / event-tag columns | dim |
| `✔ accepted` | green |
| `✘ rejected` + server reason | **red** |
| hashrate headline number | **bold cyan** |
| governor `≤ 1.0× network` / "OK, governed" | green |
| near-cap, stale-job warnings | yellow |
| `> 1.0× network`, refusal, danger | **bold red** |
| job id / extranonce reference detail | dim |
| block found | **bold green**, whole line |

A rejected share turns its whole right side red, so a run that is silently
rejecting every share (the classic word-swapped-`prevhash` bug — see § Byte
order) looks alarming instead of calm.

### The startup safety block

Printed once, before hashing begins. Restates invariant #2 in numbers the
operator can act on: the cap as an absolute rate **and** as a multiple of network
hashrate, plus what uncapped would be. The `× network` figure is the one that
matters; it is **bold red** whenever above `1.0`.

```
  chain safety
    network        ~865 KH/s   diff 0.56
    your cap       500 KH/s    →  0.58× network      OK, governed
    uncapped est.  41 MH/s     →  47× network        needs --i-know-what-im-doing
```

### `--json` is a later renderer, not now

Every log line is a small event value. The human output is one renderer over
that stream; a `--log-format=json` NDJSON renderer can be added later as a second
consumer at near-zero cost. Do not build it in v1 — just don't preclude it by
formatting strings at the event source.

## Vocabulary

Use the myth. It's shorter than the alternatives and it disambiguates.

- **the stone** — the hasher's inner nonce loop
- **the song** — the stratum connection (`Grottasöngr` = "the mill's song")
- **Fenja** / **Menja** — the two halves, as above
- **a turn** — one batch of nonces between generation checks
