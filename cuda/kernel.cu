// Grotti CUDA hasher — the only non-Odin file in the repo.
//
// STAGE: optimized (step 4). Two wins over the naive version:
//   1. Midstate — the host hashes the constant first 64 header bytes once per job and
//      passes the 8-word state in; the kernel does only block B + the second hash.
//   2. Register-resident rolling 16-word schedule — no w[64] array, so no local-memory
//      spill. Full-unrolled, __launch_bounds__ to keep registers in check.
// Still validated against the scalar CPU hasher and a known block (kerneltest).
//
// Build a PORTABLE fatbin (native SASS for Turing..Blackwell + compute_75 PTX so the
// driver can JIT anything else >= 7.5). Needs CUDA 13 for sm_121 (GB10); no GPU:
//   nvcc -fatbin \
//     -gencode arch=compute_75,code=sm_75  -gencode arch=compute_80,code=sm_80 \
//     -gencode arch=compute_86,code=sm_86  -gencode arch=compute_89,code=sm_89 \
//     -gencode arch=compute_90,code=sm_90  -gencode arch=compute_100,code=sm_100 \
//     -gencode arch=compute_120,code=sm_120 -gencode arch=compute_121,code=sm_121 \
//     -gencode arch=compute_75,code=compute_75 \
//     kernel.cu -o kernel.cubin
// The file keeps the .cubin name but is a fatbin; cuModuleLoadData handles it.

#include <stdint.h>

__constant__ uint32_t K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
};

__device__ __forceinline__ uint32_t rotr(uint32_t x, uint32_t n) { return (x >> n) | (x << (32 - n)); }
__device__ __forceinline__ uint32_t Ch(uint32_t x, uint32_t y, uint32_t z) { return (x & y) ^ (~x & z); }
__device__ __forceinline__ uint32_t Maj(uint32_t x, uint32_t y, uint32_t z) { return (x & y) ^ (x & z) ^ (y & z); }
__device__ __forceinline__ uint32_t BS0(uint32_t x) { return rotr(x,2) ^ rotr(x,13) ^ rotr(x,22); }
__device__ __forceinline__ uint32_t BS1(uint32_t x) { return rotr(x,6) ^ rotr(x,11) ^ rotr(x,25); }
__device__ __forceinline__ uint32_t SS0(uint32_t x) { return rotr(x,7) ^ rotr(x,18) ^ (x >> 3); }
__device__ __forceinline__ uint32_t SS1(uint32_t x) { return rotr(x,17) ^ rotr(x,19) ^ (x >> 10); }
__device__ __forceinline__ uint32_t bswap(uint32_t x) {
    return ((x & 0xffu) << 24) | ((x & 0xff00u) << 8) | ((x >> 8) & 0xff00u) | (x >> 24);
}

// One SHA-256 compression: state[8] folded with 16 message words w[16], updated in
// place as a rolling schedule. Full-unrolled so every w[] index is a compile-time
// constant → the 16 words live in registers, not local memory.
__device__ __forceinline__ void sha256_block(uint32_t st[8], uint32_t w[16]) {
    uint32_t a=st[0],b=st[1],c=st[2],d=st[3],e=st[4],f=st[5],g=st[6],h=st[7];
    #pragma unroll
    for (int i = 0; i < 64; i++) {
        uint32_t wi;
        if (i < 16) {
            wi = w[i];
        } else {
            wi = w[i & 15] += SS1(w[(i+14) & 15]) + w[(i+9) & 15] + SS0(w[(i+1) & 15]);
        }
        uint32_t t1 = h + BS1(e) + Ch(e,f,g) + K[i] + wi;
        uint32_t t2 = BS0(a) + Maj(a,b,c);
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    st[0]+=a; st[1]+=b; st[2]+=c; st[3]+=d;
    st[4]+=e; st[5]+=f; st[6]+=g; st[7]+=h;
}

// job layout (19 u32, uploaded once per job):
//   [0..7]   midstate — sha256 state after the first 64 header bytes
//   [8..10]  w0,w1,w2 — the constant block-B message words (be of header[64:76])
//   [11..18] target as 8 big-endian words (display order)
extern "C" __global__ __launch_bounds__(256) void scan(
    const uint32_t* __restrict__ job,
    uint32_t start_nonce,
    uint32_t count,
    uint32_t* hits,
    uint32_t* hit_count,
    uint32_t max_hits)
{
    uint32_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= count) return;
    uint32_t nonce = start_nonce + idx;

    // Block B from the midstate. W3 is the nonce word: the header stores the nonce
    // little-endian, so the big-endian message word is byteswap(nonce).
    uint32_t s[8];
    #pragma unroll
    for (int i = 0; i < 8; i++) s[i] = job[i];
    uint32_t w[16] = { job[8], job[9], job[10], bswap(nonce),
                       0x80000000u,0,0,0,0,0,0,0,0,0,0, 640u };
    sha256_block(s, w);

    // Second hash: the 8 first-hash words are the message, + padding for 256 bits.
    uint32_t s2[8] = {0x6a09e667u,0xbb67ae85u,0x3c6ef372u,0xa54ff53au,0x510e527fu,0x9b05688cu,0x1f83d9abu,0x5be0cd19u};
    uint32_t w2[16] = { s[0],s[1],s[2],s[3],s[4],s[5],s[6],s[7],
                        0x80000000u,0,0,0,0,0,0, 256u };
    sha256_block(s2, w2);

    // display (big-endian) = byteswap of the final words in reverse order; compare to
    // the target word by word.
    bool below = false;
    for (int i = 0; i < 8; i++) {
        uint32_t dw = bswap(s2[7 - i]);
        uint32_t tw = job[11 + i];
        if (dw != tw) { below = dw < tw; break; }
    }
    if (below) {
        uint32_t j = atomicAdd(hit_count, 1);
        if (j < max_hits) hits[j] = nonce;
    }
}
