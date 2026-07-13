#include <metal_stdlib>
using namespace metal;

// D3Q19 lattice-Boltzmann, SRT collision, FP32, shifted DDFs (f_i - w_i stored),
// in-place streaming via the AA-pattern (Bailey et al. 2009):
//   even step: read f_i^in = A(n,i); collide; write f_i^post -> A(n, opp(i))
//   odd  step: read f_i^in = A(n - c_i, opp(i)); collide; write f_i^post -> A(n + c_i, i)
// Each slot has a unique writer and unique reader per pass (single-array safe;
// every thread stages all 19 DDFs in registers before storing).
//
// Halfway bounce-back is fused into the odd step only (streaming across a wall
// link only occurs there under AA):
//   odd load,  source solid: f_i^in   = A(n, i)        + 6 w_i (c_i . u_w)
//   odd store, dest   solid: A(n,opp) = f_i^post       - 6 w_i (c_i . u_w)
// (Krueger et al. eq. 5.26 with rho_w = 1; error O(Ma^2). Shifted DDFs cancel
// the w_i constants in the bounce relation because w_i = w_opp(i).)
//
// Determinism: no atomics, no simdgroup ops, all moment sums in a fixed
// sequential order. Host compiles this source with mathMode = .safe and
// precise math functions.

// Pairing: for i >= 1, opp(i) = i odd ? i+1 : i-1.
constant int Cx[19] = {0, 1,-1, 0, 0, 0, 0, 1,-1, 1,-1, 1,-1, 1,-1, 0, 0, 0, 0};
constant int Cy[19] = {0, 0, 0, 1,-1, 0, 0, 1,-1,-1, 1, 0, 0, 0, 0, 1,-1, 1,-1};
constant int Cz[19] = {0, 0, 0, 0, 0, 1,-1, 0, 0, 0, 0, 1,-1,-1, 1, 1,-1,-1, 1};
constant float W[19] = {
    1.0f/3.0f,
    1.0f/18.0f, 1.0f/18.0f, 1.0f/18.0f, 1.0f/18.0f, 1.0f/18.0f, 1.0f/18.0f,
    1.0f/36.0f, 1.0f/36.0f, 1.0f/36.0f, 1.0f/36.0f, 1.0f/36.0f, 1.0f/36.0f,
    1.0f/36.0f, 1.0f/36.0f, 1.0f/36.0f, 1.0f/36.0f, 1.0f/36.0f, 1.0f/36.0f};
constant int OPP[19] = {0, 2,1, 4,3, 6,5, 8,7, 10,9, 12,11, 14,13, 16,15, 18,17};

struct Params {
    uint  nx, ny, nz;
    uint  parity;   // 0 = even step, 1 = odd step
    float omega;    // 1/tau (0 disables collision exactly: fma(0,...) below)
    float ulid;     // current (ramped) lid velocity, +x
    uint  pad0, pad1;
};

constant uchar FLAG_FLUID = 0;

inline uint fidx(uint i, uint n, uint N) { return i * N + n; }

inline int wrap(int v, int n) {
    v += (v < 0) ? n : 0;
    v -= (v >= n) ? n : 0;
    return v;
}

// SRT collision on shifted DDFs. Well-conditioned equilibrium (Lehmann PRE
// 106, 015308): rho-1 comes directly from the shifted sum (no cancellation),
// and f_eq - w_i is computed as w_i*(rhom1 + rho*(cu + cu^2/2 - 1.5 u^2))
// with cu = 3(c_i . u).
inline void collide(thread float* fh, float omega) {
    float rhom1 = 0.0f;
    for (int i = 0; i < 19; i++) { rhom1 += fh[i]; }
    float rho = 1.0f + rhom1;
    float inv = 1.0f / rho;
    float ux = 0.0f, uy = 0.0f, uz = 0.0f;
    for (int i = 1; i < 19; i++) {
        ux += (float)Cx[i] * fh[i];
        uy += (float)Cy[i] * fh[i];
        uz += (float)Cz[i] * fh[i];
    }
    ux *= inv; uy *= inv; uz *= inv;
    float u2 = ux*ux + uy*uy + uz*uz;
    for (int i = 0; i < 19; i++) {
        float cu  = 3.0f * ((float)Cx[i]*ux + (float)Cy[i]*uy + (float)Cz[i]*uz);
        float feq = W[i] * (rhom1 + rho * (cu + 0.5f*cu*cu - 1.5f*u2));
        fh[i] = fma(omega, feq - fh[i], fh[i]);
    }
}

kernel void step(device float*       f         [[buffer(0)]],
                 device const uchar* flags     [[buffer(1)]],
                 device const uint*  solidMask [[buffer(2)]],  // bit i-1: neighbor n + c_i is solid
                 device const uint*  lidMask   [[buffer(3)]],  // subset of solidMask that is lid
                 constant Params&    p         [[buffer(4)]],
                 uint n [[thread_position_in_grid]])
{
    const uint N = p.nx * p.ny * p.nz;
    if (n >= N || flags[n] != FLAG_FLUID) { return; }

    const int x = (int)(n % p.nx);
    const int t = (int)(n / p.nx);
    const int y = t % (int)p.ny;
    const int z = t / (int)p.ny;

    float fh[19];

    if (p.parity == 0u) {
        // -------- even: pure in-cell pass --------
        for (int i = 0; i < 19; i++) { fh[i] = f[fidx(i, n, N)]; }
        collide(fh, p.omega);
        f[fidx(0, n, N)] = fh[0];
        for (int i = 1; i < 19; i++) { f[fidx(OPP[i], n, N)] = fh[i]; }
    } else {
        // -------- odd: streaming pass (neighbors + bounce-back) --------
        const uint sMask = solidMask[n];
        const uint lMask = lidMask[n];
        fh[0] = f[fidx(0, n, N)];
        for (int i = 1; i < 19; i++) {
            // incoming along i from source s = n - c_i (neighbor in dir opp(i))
            const int srcBit = OPP[i] - 1;
            if ((sMask >> srcBit) & 1u) {
                float corr = ((lMask >> srcBit) & 1u)
                    ? 6.0f * W[i] * ((float)Cx[i] * p.ulid) : 0.0f;
                fh[i] = f[fidx(i, n, N)] + corr;
            } else {
                const int sx = wrap(x - Cx[i], (int)p.nx);
                const int sy = wrap(y - Cy[i], (int)p.ny);
                const int sz = wrap(z - Cz[i], (int)p.nz);
                const uint s = ((uint)sz * p.ny + (uint)sy) * p.nx + (uint)sx;
                fh[i] = f[fidx(OPP[i], s, N)];
            }
        }
        collide(fh, p.omega);
        f[fidx(0, n, N)] = fh[0];
        for (int i = 1; i < 19; i++) {
            const int dstBit = i - 1;
            if ((sMask >> dstBit) & 1u) {
                float corr = ((lMask >> dstBit) & 1u)
                    ? 6.0f * W[i] * ((float)Cx[i] * p.ulid) : 0.0f;
                f[fidx(OPP[i], n, N)] = fh[i] - corr;
            } else {
                const int dx = wrap(x + Cx[i], (int)p.nx);
                const int dy = wrap(y + Cy[i], (int)p.ny);
                const int dz = wrap(z + Cz[i], (int)p.nz);
                const uint d = ((uint)dz * p.ny + (uint)dy) * p.nx + (uint)dx;
                f[fidx(i, d, N)] = fh[i];
            }
        }
    }
}

// Moments probe. Valid only when the NEXT step would be even (i.e. after an
// even number of completed steps): DDFs then sit in natural slots.
kernel void momentsEven(device const float* f     [[buffer(0)]],
                        device const uchar* flags [[buffer(1)]],
                        device float4*      out   [[buffer(2)]],
                        constant Params&    p     [[buffer(3)]],
                        uint n [[thread_position_in_grid]])
{
    const uint N = p.nx * p.ny * p.nz;
    if (n >= N) { return; }
    if (flags[n] != FLAG_FLUID) { out[n] = float4(0.0f); return; }
    float rhom1 = 0.0f, ux = 0.0f, uy = 0.0f, uz = 0.0f;
    for (int i = 0; i < 19; i++) {
        const float v = f[fidx(i, n, N)];
        rhom1 += v;
        ux += (float)Cx[i] * v;
        uy += (float)Cy[i] * v;
        uz += (float)Cz[i] * v;
    }
    const float rho = 1.0f + rhom1;
    out[n] = float4(ux / rho, uy / rho, uz / rho, rho);
}

// Bench initializer: shifted equilibrium of a Taylor-Green-like velocity
// field, so the benchmark streams realistic non-zero data. Natural slots
// (state is "before an even step").
kernel void initTaylorGreen(device float*    f [[buffer(0)]],
                            constant Params& p [[buffer(1)]],
                            uint n [[thread_position_in_grid]])
{
    const uint N = p.nx * p.ny * p.nz;
    if (n >= N) { return; }
    const uint x = n % p.nx;
    const uint t = n / p.nx;
    const uint y = t % p.ny;
    const uint z = t / p.ny;
    const float kx = 2.0f * M_PI_F / (float)p.nx;
    const float ky = 2.0f * M_PI_F / (float)p.ny;
    const float kz = 2.0f * M_PI_F / (float)p.nz;
    const float A = 0.05f;
    const float ux =  A * sin(kx * (float)x) * cos(ky * (float)y) * cos(kz * (float)z);
    const float uy = -A * cos(kx * (float)x) * sin(ky * (float)y) * cos(kz * (float)z);
    const float uz = 0.0f;
    const float u2 = ux*ux + uy*uy + uz*uz;
    for (int i = 0; i < 19; i++) {
        const float cu = 3.0f * ((float)Cx[i]*ux + (float)Cy[i]*uy + (float)Cz[i]*uz);
        f[fidx(i, n, N)] = W[i] * (cu + 0.5f*cu*cu - 1.5f*u2); // rho = 1
    }
}
