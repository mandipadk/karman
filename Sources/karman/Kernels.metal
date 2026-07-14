#include <metal_stdlib>
using namespace metal;

// D3Q19 lattice-Boltzmann, TRT collision (SRT = special case omegaMinus ==
// omega), FP32 arithmetic, shifted DDFs (f_i - w_i stored), storage type FPXX
// (float or half — set by a preprocessor macro at library compile time; the
// FP16S scheme of Lehmann PRE 106, 015308: IEEE half storage of shifted DDFs,
// all arithmetic in FP32).
//
// In-place streaming via the AA-pattern (Bailey et al. 2009):
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
// TRT (Ginzburg 2008): per direction pair (i, opp(i)) relax the symmetric
// half with omega+ (sets viscosity) and the antisymmetric half with omega-
// (set via the magic parameter Lambda = (1/w+ - 1/2)(1/w- - 1/2); 3/16 makes
// the bounce-back wall location exact, 1/4 is the stability optimum).
//
// Guo forcing (Guo, Zheng & Shi 2002), TRT-split: the part of the source odd
// under i -> opp(i) relaxes with (1 - omega-/2), the even part with
// (1 - omega+/2). Velocity used in equilibrium and output: u = (p + F/2)/rho.
//
// Determinism: no atomics, no simdgroup ops, all moment sums in a fixed
// sequential order. Host compiles this source with mathMode = .safe and
// precise math functions.

#ifndef FPXX
#define FPXX float
#endif

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
    uint  nx, ny, nz, parity;   // parity: 0 = even step, 1 = odd step
    float omega;       // omega+ (1/tau; 0 disables collision exactly)
    float omegaMinus;  // omega- (== omega for SRT)
    float ulid;        // current (ramped) lid velocity, +x
    float uin;         // current (ramped) inflow peak velocity, +x
    float fx, fy, fz;  // uniform body force density (lattice units)
    float outBlend;    // outflow blend factor (1 = pure zero-gradient copy)
    uint  writeForce;  // odd steps: accumulate momentum-exchange per cell
    float rhoIn;       // inlet density (mass-flux controller state)
    uint  pad1, pad2;
};

constant uchar FLAG_FLUID   = 0;
constant uchar FLAG_SOLID   = 1;
constant uchar FLAG_LID     = 2;
constant uchar FLAG_INFLOW  = 3;  // bounce-back wall with parabolic normal velocity
constant uchar FLAG_OUTFLOW = 4;  // anti-bounce-back pressure wall: with shifted
                                  // DDFs at rho_target = 1, fs_in = -fs_out
                                  // (Ginzburg ABB, u-terms dropped: O(u^2) local)

// Moving-wall x-velocity for a boundary link into cell (wx, wy): lid walls
// carry the global lid speed; inflow walls the parabolic profile at wy.
// A bounce-back wall with a NORMAL velocity component injects mass flux
// rho_w * u_w exactly (the standard flux-exact velocity inlet).
inline float wallVelX(uchar wallFlag, int wy, constant Params& p) {
    if (wallFlag == FLAG_LID) { return p.ulid; }
    const float H  = (float)p.ny - 2.0f;
    const float yd = (float)wy - 0.5f;
    return max(4.0f * p.uin * yd * (H - yd) / (H * H), 0.0f);
}

inline uint fidx(uint i, uint n, uint N) { return i * N + n; }

inline int wrap(int v, int n) {
    v += (v < 0) ? n : 0;
    v -= (v >= n) ? n : 0;
    return v;
}

// TRT collision + Guo forcing on shifted DDFs, pairwise (no feq array).
// Well-conditioned equilibrium (Lehmann PRE 106, 015308): rho-1 comes
// directly from the shifted sum; the pair-symmetric equilibrium part is
// w_i*(rhom1 + rho*(cu^2/2 - 1.5 u^2)) and the antisymmetric part w_i*rho*cu,
// with cu = 3(c_i . u).
inline void collide(thread float* fh, constant Params& p) {
    const float wp = p.omega, wm = p.omegaMinus;
    float rhom1 = 0.0f;
    for (int i = 0; i < 19; i++) { rhom1 += fh[i]; }
    const float rho = 1.0f + rhom1;
    const float inv = 1.0f / rho;
    float px = 0.0f, py = 0.0f, pz = 0.0f;
    for (int i = 1; i < 19; i++) {
        px += (float)Cx[i] * fh[i];
        py += (float)Cy[i] * fh[i];
        pz += (float)Cz[i] * fh[i];
    }
    const float ux = (px + 0.5f * p.fx) * inv;
    const float uy = (py + 0.5f * p.fy) * inv;
    const float uz = (pz + 0.5f * p.fz) * inv;
    const float u2 = ux*ux + uy*uy + uz*uz;
    const float uF = ux*p.fx + uy*p.fy + uz*p.fz;
    const float ap = 1.0f - 0.5f * wp;   // even-source prefactor
    const float am = 1.0f - 0.5f * wm;   // odd-source prefactor

    // rest direction: purely symmetric
    {
        const float feq0 = W[0] * (rhom1 - 1.5f * rho * u2);
        const float s0   = W[0] * ap * (-3.0f * uF);
        fh[0] = fma(wp, feq0 - fh[0], fh[0]) + s0;
    }
    for (int i = 1; i < 19; i += 2) {
        const float cu = 3.0f * ((float)Cx[i]*ux + (float)Cy[i]*uy + (float)Cz[i]*uz);
        const float cF = (float)Cx[i]*p.fx + (float)Cy[i]*p.fy + (float)Cz[i]*p.fz;
        const float feqp = W[i] * (rhom1 + rho * (0.5f*cu*cu - 1.5f*u2)); // symmetric eq
        const float feqm = W[i] * rho * cu;                               // antisymmetric eq
        const float fp = 0.5f * (fh[i] + fh[i+1]);
        const float fm = 0.5f * (fh[i] - fh[i+1]);
        const float dp = wp * (feqp - fp);
        const float dm = wm * (feqm - fm);
        // Guo source, split: odd part 3(c.F); even part 3 cu*(c.F) - 3 u.F
        const float sm = W[i] * am * (3.0f * cF);
        const float sp = W[i] * ap * (3.0f * cu * cF - 3.0f * uF);
        fh[i]   += dp + dm + sp + sm;
        fh[i+1] += dp - dm + sp - sm;
    }
}

kernel void step(device FPXX*        f         [[buffer(0)]],
                 device const uchar* flags     [[buffer(1)]],
                 device const uint*  solidMask [[buffer(2)]],  // bit i-1: neighbor n + c_i is solid
                 device const uint*  lidMask   [[buffer(3)]],  // subset of solidMask that is lid
                 constant Params&    p         [[buffer(4)]],
                 device float4*      force     [[buffer(5)]],  // per-cell momentum exchange (writeForce)
                 uint n [[thread_position_in_grid]])
{
    const uint N = p.nx * p.ny * p.nz;
    if (n >= N) { return; }
    const uchar flag = flags[n];
    if (flag != FLAG_FLUID) { return; }

    const int x = (int)(n % p.nx);
    const int t = (int)(n / p.nx);
    const int y = t % (int)p.ny;
    const int z = t / (int)p.ny;

    float fh[19];

    if (p.parity == 0u) {
        // -------- even: pure in-cell pass --------
        for (int i = 0; i < 19; i++) { fh[i] = (float)f[fidx(i, n, N)]; }
        collide(fh, p);
        f[fidx(0, n, N)] = (FPXX)fh[0];
        for (int i = 1; i < 19; i++) { f[fidx(OPP[i], n, N)] = (FPXX)fh[i]; }
    } else {
        // -------- odd: streaming pass (neighbors + bounce-back) --------
        // Momentum exchange (Mei/Ladd): net momentum flux fluid->wall across
        // a link with toward-wall direction j during one step is
        // c_j (f_j^out + f_i^in), i = opp(j), in RAW DDFs. Shifted DDFs add
        // the constant 2 w_j c_j per link (static pressure; sums to zero over
        // closed bodies). The load side handles f_i^in (with -c_i = c_j), the
        // store side f_j^out + 2 w_j.
        const uint sMask = solidMask[n];
        const uint lMask = lidMask[n];
        float ax = 0.0f, ay = 0.0f, az = 0.0f;
        fh[0] = (float)f[fidx(0, n, N)];
        for (int i = 1; i < 19; i++) {
            // incoming along i from source s = n - c_i (neighbor in dir opp(i))
            const int srcBit = OPP[i] - 1;
            if ((sMask >> srcBit) & 1u) {
                float corr = 0.0f;
                float sign = 1.0f;
                if ((lMask >> srcBit) & 1u) {
                    const int sy = wrap(y - Cy[i], (int)p.ny);
                    const uint s = ((uint)wrap(z - Cz[i], (int)p.nz) * p.ny + (uint)sy) * p.nx
                                 + (uint)wrap(x - Cx[i], (int)p.nx);
                    const uchar wf = flags[s];
                    if (wf == FLAG_OUTFLOW) { sign = -1.0f; }
                    else { corr = 6.0f * W[i] * ((float)Cx[i] * wallVelX(wf, sy, p)); }
                }
                fh[i] = sign * (float)f[fidx(i, n, N)] + corr;
                if (p.writeForce != 0u) {
                    ax -= (float)Cx[i] * fh[i];
                    ay -= (float)Cy[i] * fh[i];
                    az -= (float)Cz[i] * fh[i];
                }
            } else {
                const int sx = wrap(x - Cx[i], (int)p.nx);
                const int sy = wrap(y - Cy[i], (int)p.ny);
                const int sz = wrap(z - Cz[i], (int)p.nz);
                const uint s = ((uint)sz * p.ny + (uint)sy) * p.nx + (uint)sx;
                fh[i] = (float)f[fidx(OPP[i], s, N)];
            }
        }
        collide(fh, p);
        f[fidx(0, n, N)] = (FPXX)fh[0];
        for (int i = 1; i < 19; i++) {
            const int dstBit = i - 1;
            if ((sMask >> dstBit) & 1u) {
                float corr = 0.0f;
                float sign = 1.0f;
                if ((lMask >> dstBit) & 1u) {
                    const int dy = wrap(y + Cy[i], (int)p.ny);
                    const uint d = ((uint)wrap(z + Cz[i], (int)p.nz) * p.ny + (uint)dy) * p.nx
                                 + (uint)wrap(x + Cx[i], (int)p.nx);
                    const uchar wf = flags[d];
                    if (wf == FLAG_OUTFLOW) { sign = -1.0f; }
                    else { corr = 6.0f * W[i] * ((float)Cx[i] * wallVelX(wf, dy, p)); }
                }
                f[fidx(OPP[i], n, N)] = (FPXX)(sign * fh[i] - corr);
                if (p.writeForce != 0u) {
                    const float v = fh[i] + 2.0f * W[i];
                    ax += (float)Cx[i] * v;
                    ay += (float)Cy[i] * v;
                    az += (float)Cz[i] * v;
                }
            } else {
                const int dx = wrap(x + Cx[i], (int)p.nx);
                const int dy = wrap(y + Cy[i], (int)p.ny);
                const int dz = wrap(z + Cz[i], (int)p.nz);
                const uint d = ((uint)dz * p.ny + (uint)dy) * p.nx + (uint)dx;
                f[fidx(i, d, N)] = (FPXX)fh[i];
            }
        }
        if (p.writeForce != 0u && sMask != 0u) {
            force[n] = float4(ax, ay, az, 0.0f);
        }
    }
}

// Pressure outlet: after each step, outflow cells become shifted equilibrium
// at rho = 1 with the -x neighbor's velocity (velocity zero-gradient,
// pressure Dirichlet). A raw DDF copy does NOT conserve mass — the channel
// back-pressures until a soft equilibrium inlet yields several percent of
// flux (measured: -4.8%). Anchoring rho at the outlet lets the inlet flux
// through. Slot-verbatim equilibrium write is parity-safe. Runs as a
// separate dispatch after the step kernel (reads neighbor post-step state).
kernel void outflowCopy(device FPXX*        f     [[buffer(0)]],
                        device const uchar* flags [[buffer(1)]],
                        constant Params&    p     [[buffer(6)]],  // 2-5 belong to `step` — do not clobber
                        uint n [[thread_position_in_grid]])
{
    const uint N = p.nx * p.ny * p.nz;
    if (n >= N || flags[n] != FLAG_OUTFLOW) { return; }
    const uint src = n - 1; // -x neighbor
    // Parity-aware READ: after an even step f_i sits at slot opp(i); a
    // verbatim read there negates the momentum sum (imposing a backward
    // outlet velocity every other step).
    float rhom1 = 0.0f, px = 0.0f, py = 0.0f, pz = 0.0f;
    for (int i = 0; i < 19; i++) {
        const uint slot = (p.parity == 1u) ? (uint)i : (uint)OPP[i];
        const float v = (float)f[fidx(slot, src, N)];
        rhom1 += v;
        px += (float)Cx[i] * v;
        py += (float)Cy[i] * v;
        pz += (float)Cz[i] * v;
    }
    const float inv = 1.0f / (1.0f + rhom1);
    const float ux = px * inv, uy = py * inv, uz = pz * inv;
    const float u2 = ux*ux + uy*uy + uz*uz;
    // Parity-aware store: after an odd step the state sits in natural slots;
    // after an even step, in swapped slots (f_i lives at opp(i)).
    const int x = (int)(n % p.nx);
    const int t = (int)(n / p.nx);
    const int y = t % (int)p.ny;
    const int z = t / (int)p.ny;
    for (int i = 0; i < 19; i++) {
        const float cu = 3.0f * ((float)Cx[i]*ux + (float)Cy[i]*uy + (float)Cz[i]*uz);
        const float v = W[i] * (cu + 0.5f*cu*cu - 1.5f*u2); // rho = 1
        const uint slot = (p.parity == 1u) ? (uint)i : (uint)OPP[i];
        f[fidx(slot, n, N)] = (FPXX)v;
        // The outflow never scatters during the pass (mid-pass writes race
        // with its neighbor's). After odd steps, deliver here what an active
        // cell's odd-store would have left in the neighbors' natural slots:
        // the -x-family DDFs their next EVEN load reads.
        if (p.parity == 1u && Cx[i] < 0) {
            const int dx = wrap(x + Cx[i], (int)p.nx);
            const int dy = wrap(y + Cy[i], (int)p.ny);
            const int dz = wrap(z + Cz[i], (int)p.nz);
            const uint d = ((uint)dz * p.ny + (uint)dy) * p.nx + (uint)dx;
            if (flags[d] == FLAG_FLUID) { f[fidx(i, d, N)] = (FPXX)v; }
        }
    }
}

// Moments probe. Valid only when the NEXT step would be even (i.e. after an
// even number of completed steps): DDFs then sit in natural slots.
// Output velocity includes the Guo half-force shift.
kernel void momentsEven(device const FPXX*  f     [[buffer(0)]],
                        device const uchar* flags [[buffer(1)]],
                        device float4*      out   [[buffer(2)]],
                        constant Params&    p     [[buffer(3)]],
                        uint n [[thread_position_in_grid]])
{
    const uint N = p.nx * p.ny * p.nz;
    if (n >= N) { return; }
    const uchar flag = flags[n];
    if (flag != FLAG_FLUID && flag != FLAG_OUTFLOW) { out[n] = float4(0.0f); return; }
    float rhom1 = 0.0f, px = 0.0f, py = 0.0f, pz = 0.0f;
    for (int i = 0; i < 19; i++) {
        const float v = (float)f[fidx(i, n, N)];
        rhom1 += v;
        px += (float)Cx[i] * v;
        py += (float)Cy[i] * v;
        pz += (float)Cz[i] * v;
    }
    const float rho = 1.0f + rhom1;
    out[n] = float4((px + 0.5f * p.fx) / rho,
                    (py + 0.5f * p.fy) / rho,
                    (pz + 0.5f * p.fz) / rho, rho);
}

// Initializer: shifted equilibrium of an analytic velocity field.
// mode 0: zero (rest). mode 1: Taylor-Green, amplitude A, one period per box.
struct InitParams {
    uint  nx, ny, nz, mode;
    float amplitude;
    float tau;      // for the analytic non-equilibrium part
    float pad1, pad2;
};

kernel void initField(device FPXX*         f [[buffer(0)]],
                      constant InitParams& p [[buffer(1)]],
                      uint n [[thread_position_in_grid]])
{
    const uint N = p.nx * p.ny * p.nz;
    if (n >= N) { return; }
    float ux = 0.0f, uy = 0.0f, uz = 0.0f;
    if (p.mode == 1u) {
        const uint x = n % p.nx;
        const uint t = n / p.nx;
        const uint y = t % p.ny;
        const float kx = 2.0f * M_PI_F / (float)p.nx;
        const float ky = 2.0f * M_PI_F / (float)p.ny;
        ux =  p.amplitude * sin(kx * ((float)x + 0.5f)) * cos(ky * ((float)y + 0.5f));
        uy = -p.amplitude * cos(kx * ((float)x + 0.5f)) * sin(ky * ((float)y + 0.5f));
    }
    // Consistent initialization (Mei et al. 2006): f = feq(rho, u) + fneq.
    // Two first-order-in-relative-error traps if omitted:
    //  - the analytic TG PRESSURE field: for THIS phase convention
    //    (u = A sin x cos y), p = +(u0^2/4)(cos 2kx + cos 2ky);
    //    starting at uniform rho launches an acoustic transient ~O(u0^2),
    //    first order relative to the u0 signal under diffusive scaling;
    //  - the non-equilibrium part: for the symmetric TG field S_xy = 0 and
    //    tr(S) = 0, so fneq_i = -3 w_i tau S_xx (cx^2 - cy^2).
    float sxx = 0.0f;
    float rhom1 = 0.0f;
    if (p.mode == 1u) {
        const uint x = n % p.nx;
        const uint t = n / p.nx;
        const uint y = t % p.ny;
        const float kx = 2.0f * M_PI_F / (float)p.nx;
        const float ky = 2.0f * M_PI_F / (float)p.ny;
        const float xa = (float)x + 0.5f, ya = (float)y + 0.5f;
        sxx = p.amplitude * kx * cos(kx * xa) * cos(ky * ya);
        rhom1 = 0.75f * p.amplitude * p.amplitude
              * (cos(2.0f * kx * xa) + cos(2.0f * ky * ya)); // rho-1 = 3p
    }
    const float rho = 1.0f + rhom1;
    const float u2 = ux*ux + uy*uy + uz*uz;
    for (int i = 0; i < 19; i++) {
        const float cu = 3.0f * ((float)Cx[i]*ux + (float)Cy[i]*uy + (float)Cz[i]*uz);
        const float feq = W[i] * (rhom1 + rho * (cu + 0.5f*cu*cu - 1.5f*u2));
        const float cc = (float)(Cx[i]*Cx[i] - Cy[i]*Cy[i]);
        const float fneq = -3.0f * W[i] * p.tau * sxx * cc;
        f[fidx(i, n, N)] = (FPXX)(feq + fneq);
    }
}
