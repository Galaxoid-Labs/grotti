#include <metal_stdlib>
using namespace metal;

// Grotti SHA-256d Metal compute kernel — the MSL twin of vulkan/sha256d.comp and
// cuda/kernel.cu. Compiled at RUNTIME from this source string (newLibraryWithSource),
// so there is no metallib to ship and Metal handles every GPU generation. Validated
// against sha256d (scalar) in metal/kerneltest on every build (CLAUDE.md invariant #4).
// One SHA-256d per thread over one nonce; hits drain through an atomic counter, because
// a single launch finds SEVERAL shares on this chain (CLAUDE.md § the Backend seam).
//
// PERF: the 64-round schedule is fully unrolled (#pragma unroll) so every w[i & 15]
// index folds to a compile-time constant and the 16-word schedule stays in registers
// rather than thread-local memory — the same lever that took the Vulkan shader from
// ~0.86 to ~1.78 GH/s. Do NOT remove the unroll (CLAUDE.md § macOS/Metal notes).

// Job + launch params ride in a small constant buffer (setBytes at index 0). All-uint,
// tight 4-byte stride — the layout MUST match the host Params struct in backend.odin.
struct Params {
    uint midstate[8]; // sha256 state after the first 64 header bytes
    uint w0;          // } the three constant block-B message words
    uint w1;          // }  (big-endian of header[64:76])
    uint w2;          // }
    uint target[8];   // target as 8 big-endian words (display order)
    uint start_nonce;
    uint count;
    uint max_hits;
};

constant uint K[64] = {
    0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,
    0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,
    0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
    0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,
    0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,
    0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
    0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,
    0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u
};

inline uint rotr(uint x, uint n) { return (x >> n) | (x << (32u - n)); }
inline uint Ch(uint x, uint y, uint z)  { return (x & y) ^ (~x & z); }
inline uint Maj(uint x, uint y, uint z) { return (x & y) ^ (x & z) ^ (y & z); }
inline uint BS0(uint x) { return rotr(x, 2u)  ^ rotr(x, 13u) ^ rotr(x, 22u); }
inline uint BS1(uint x) { return rotr(x, 6u)  ^ rotr(x, 11u) ^ rotr(x, 25u); }
inline uint SS0(uint x) { return rotr(x, 7u)  ^ rotr(x, 18u) ^ (x >> 3u); }
inline uint SS1(uint x) { return rotr(x, 17u) ^ rotr(x, 19u) ^ (x >> 10u); }
inline uint bswap(uint x) {
    return ((x & 0xffu) << 24) | ((x & 0xff00u) << 8) | ((x >> 8) & 0xff00u) | (x >> 24);
}

// One SHA-256 compression: state[8] folded with 16 message words, updated in place as a
// rolling schedule (matches cuda/kernel.cu::sha256_block and sha256d.comp exactly).
inline void sha256_block(thread uint st[8], thread uint w[16]) {
    uint a = st[0], b = st[1], c = st[2], d = st[3];
    uint e = st[4], f = st[5], g = st[6], h = st[7];
    // Full unroll: with i constant, every w[i & 15] index folds to a compile-time
    // constant, so the 16-word schedule is scalar-replaced into registers.
    #pragma unroll
    for (int i = 0; i < 64; i++) {
        uint wi;
        if (i < 16) {
            wi = w[i];
        } else {
            w[i & 15] += SS1(w[(i + 14) & 15]) + w[(i + 9) & 15] + SS0(w[(i + 1) & 15]);
            wi = w[i & 15];
        }
        uint t1 = h + BS1(e) + Ch(e, f, g) + K[i] + wi;
        uint t2 = BS0(a) + Maj(a, b, c);
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    st[0] += a; st[1] += b; st[2] += c; st[3] += d;
    st[4] += e; st[5] += f; st[6] += g; st[7] += h;
}

kernel void scan(constant Params        &pc        [[buffer(0)]],
                 device   uint          *hits      [[buffer(1)]],
                 device   atomic_uint   *hit_count [[buffer(2)]],
                 uint                    gid       [[thread_position_in_grid]]) {
    if (gid >= pc.count) return;
    uint nonce = pc.start_nonce + gid;

    // Block B from the midstate. W3 is the nonce word: the header stores the nonce
    // little-endian, so the big-endian message word is bswap(nonce).
    uint s[8];
    #pragma unroll
    for (int i = 0; i < 8; i++) s[i] = pc.midstate[i];
    uint w[16] = {
        pc.w0, pc.w1, pc.w2, bswap(nonce),
        0x80000000u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 640u
    };
    sha256_block(s, w);

    // Second hash: the 8 first-hash words are the message, plus padding for 256 bits.
    uint s2[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
    };
    uint w2[16] = {
        s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7],
        0x80000000u, 0u, 0u, 0u, 0u, 0u, 0u, 256u
    };
    sha256_block(s2, w2);

    // display (big-endian) word i = bswap of the final state words in reverse order;
    // compare to the target word by word, MSW first (fractional-diff safe — the target's
    // leading word may be nonzero on this chain, CLAUDE.md § Target check).
    bool below = false;
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        uint dw = bswap(s2[7 - i]);
        uint tw = pc.target[i];
        if (dw != tw) { below = dw < tw; break; }
    }
    if (below) {
        uint j = atomic_fetch_add_explicit(hit_count, 1u, memory_order_relaxed);
        if (j < pc.max_hits) hits[j] = nonce;
    }
}
