import Foundation

// MARK: - Ghia, Ghia & Shin (1982) oracle — interior points only (boundary
// rows are identically satisfied by the BCs). Columns: coordinate, Re=100,
// Re=400, Re=1000. See docs/research/benchmarks-and-uq.md for provenance
// and known transcription caveats.

let ghiaU: [(y: Double, re100: Double, re400: Double, re1000: Double)] = [
    (0.9766,  0.84123,  0.75837,  0.65928),
    (0.9688,  0.78871,  0.68439,  0.57492),
    (0.9609,  0.73722,  0.61756,  0.51117),
    (0.9531,  0.68717,  0.55892,  0.46604),
    (0.8516,  0.23151,  0.29093,  0.33304),
    (0.7344,  0.00332,  0.16256,  0.18719),
    (0.6172, -0.13641,  0.02135,  0.05702),
    (0.5000, -0.20581, -0.11477, -0.06080),
    (0.4531, -0.21090, -0.17119, -0.10648),
    (0.2813, -0.15662, -0.32726, -0.27805),
    (0.1719, -0.10150, -0.24299, -0.38289),
    (0.1016, -0.06434, -0.14612, -0.29730),
    (0.0703, -0.04775, -0.10338, -0.22220),
    (0.0625, -0.04192, -0.09266, -0.20196),
    (0.0547, -0.03717, -0.08186, -0.18109),
]

let ghiaV: [(x: Double, re100: Double, re400: Double, re1000: Double)] = [
    (0.9688, -0.05906, -0.12146, -0.21388),
    (0.9609, -0.07391, -0.15663, -0.27669),
    (0.9531, -0.08864, -0.19254, -0.33714),
    (0.9453, -0.10313, -0.22847, -0.39188),
    (0.9063, -0.16914, -0.23827, -0.51550),
    (0.8594, -0.22445, -0.44993, -0.42665),
    (0.8047, -0.24533, -0.38598, -0.31966),
    (0.5000,  0.05454,  0.05186,  0.02526),
    (0.2344,  0.17527,  0.30174,  0.32235),
    (0.2266,  0.17507,  0.30203,  0.33075),
    (0.1563,  0.16077,  0.28124,  0.37095),
    (0.0938,  0.12317,  0.22965,  0.32627),
    (0.0781,  0.10890,  0.20920,  0.30353),
    (0.0703,  0.10091,  0.19713,  0.29012),
    (0.0625,  0.09233,  0.18360,  0.27485),
]

struct GateResult {
    let name: String
    let passed: Bool
    let detail: String
}

// MARK: - Self-tests (the parity/indexing proof)

func runSelftest(gpu: GPU) throws -> [GateResult] {
    var results: [GateResult] = []

    // 1. Rest state is a bitwise fixed point (periodic box, active collision).
    do {
        let sim = try Simulation(gpu: gpu, nx: 32, ny: 32, nz: 32, omega: 1.7) { _, _, _ in .fluid }
        let before = sim.stateDigest
        try sim.run(steps: 100)
        let after = sim.stateDigest
        results.append(GateResult(name: "rest fixed point (periodic)",
                                  passed: before == after,
                                  detail: before == after ? "bitwise stable over 100 steps" : "state changed"))
    }

    // 2. Rest cavity (walls + stationary lid) is also a bitwise fixed point.
    do {
        let n = 34
        let sim = try Simulation(gpu: gpu, nx: n, ny: n, nz: 1, omega: 1.7, ulid: 0) { x, y, _ in
            if y == n - 1 { return .lid }
            if x == 0 || x == n - 1 || y == 0 { return .solid }
            return .fluid
        }
        let before = sim.stateDigest
        try sim.run(steps: 100)
        let passed = sim.stateDigest == before
        results.append(GateResult(name: "rest fixed point (cavity walls)",
                                  passed: passed,
                                  detail: passed ? "bounce-back of zeros is zeros" : "wall handling perturbs rest state"))
    }

    // 3. Streaming: with omega = 0, a lone DDF in direction i must travel
    //    exactly T*c_i and remain bit-identical (verifies every slot in the
    //    AA parity scheme, all 18 directions at once).
    do {
        let n = 16
        let sim = try Simulation(gpu: gpu, nx: n, ny: n, nz: n, omega: 0) { _, _, _ in .fluid }
        let N = sim.cells
        let f = sim.fBuf.contents().bindMemory(to: Float.self, capacity: 19 * N)
        let c0 = (8, 8, 8)
        let cellIndex = { (x: Int, y: Int, z: Int) in (z * n + y) * n + x }
        var injected: [Float] = Array(repeating: 0, count: 19)
        for i in 1..<19 {
            injected[i] = Float(i) * 0.001
            f[i * N + cellIndex(c0.0, c0.1, c0.2)] = injected[i]
        }
        let T = 4
        try sim.run(steps: T)
        var ok = true
        var firstFailure = ""
        var nonzero = 0
        for i in 1..<19 {
            let dest = cellIndex((c0.0 + T * Simulation.cx[i] + 4 * n) % n,
                                 (c0.1 + T * Simulation.cy[i] + 4 * n) % n,
                                 (c0.2 + T * Simulation.cz[i] + 4 * n) % n)
            let v = f[i * N + dest]
            if v != injected[i] {
                ok = false
                if firstFailure.isEmpty {
                    firstFailure = "dir \(i): expected \(injected[i]) at dest, found \(v)"
                }
            }
        }
        for k in 0..<(19 * N) where f[k] != 0 { nonzero += 1 }
        if nonzero != 18 {
            ok = false
            if firstFailure.isEmpty { firstFailure = "\(nonzero) nonzero slots (expected 18) — leakage" }
        }
        results.append(GateResult(name: "streaming propagation (18 dirs, \(T) steps)",
                                  passed: ok,
                                  detail: ok ? "each DDF at exactly cell + \(T)·c_i, bit-identical, no leakage" : firstFailure))
    }

    return results
}

// MARK: - Benchmark

func runBench(gpu: GPU, n: Int, warmup: Int = 20, timed: Int = 200) throws -> GateResult {
    let sim = try Simulation(gpu: gpu, nx: n, ny: n, nz: n, omega: 1.9) { _, _, _ in .fluid }
    try sim.initTaylorGreen()
    try sim.run(steps: warmup)
    let t0 = sim.gpuSeconds
    try sim.run(steps: timed)
    let dt = sim.gpuSeconds - t0
    let mlups = Double(sim.cells) * Double(timed) / dt / 1e6
    // Bytes/cell/step: even = 19*8 f + 1 flag = 153; odd = +8 masks = 161; avg 157.
    let gbps = mlups * 157.0 / 1000.0
    let passed = mlups >= 600
    return GateResult(name: "bench \(n)³ (FP32)",
                      passed: passed,
                      detail: String(format: "%.0f MLUPS, ~%.0f GB/s effective (gate ≥600 MLUPS; FluidX3D-OpenCL on M5 = 800)", mlups, gbps))
}

// MARK: - Cavity

struct CavityRun {
    let sim: Simulation
    let nInterior: Int
    let converged: Bool
    let steps: Int
    let residual: Double
    let howConverged: String
}

/// Lid-driven cavity: interior n×n fluid cells + 1-cell solid frame, lid on
/// top (+x). Effective cavity width with halfway bounce-back = n exactly.
func cavity(gpu: GPU, n: Int, re: Double, ulid: Float = 0.1,
            maxSteps: Int, checkEvery: Int = 5000, tol: Double = 5e-7) throws -> CavityRun {
    let nx = n + 2, ny = n + 2
    let nu = Double(ulid) * Double(n) / re
    let tau = 3.0 * nu + 0.5
    let sim = try Simulation(gpu: gpu, nx: nx, ny: ny, nz: 1,
                             omega: Float(1.0 / tau), ulid: ulid, rampSteps: 5000) { x, y, _ in
        if y == ny - 1 { return .lid }
        if x == 0 || x == nx - 1 || y == 0 { return .solid }
        return .fluid
    }
    var prev: [Float] = []
    var converged = false
    var residual = Double.infinity
    var history: [Double] = []
    var how = "max steps reached"
    while sim.stepsDone < maxSteps {
        try sim.run(steps: min(checkEvery, maxSteps - sim.stepsDone))
        let m = try sim.probeMoments()
        var cur = [Float](); cur.reserveCapacity(sim.cells * 2)
        for v in m { cur.append(v.x); cur.append(v.y) }
        if !prev.isEmpty && sim.stepsDone > sim.rampSteps {
            var dsum = 0.0, nsum = 0.0
            for k in 0..<cur.count {
                let d = Double(cur[k] - prev[k])
                dsum += d * d
                nsum += Double(cur[k]) * Double(cur[k])
            }
            residual = nsum > 0 ? (dsum / nsum).squareRoot() : 0
            history.append(residual)
            if residual < tol {
                converged = true; how = "residual < tol"
            } else if residual < 2e-5, history.count >= 5,
                      let best = history.dropLast().suffix(4).min(),
                      residual > 0.95 * best {
                // FP32 round-off floor: the field has stopped improving at a
                // low level (mass-drift micro-jitter keeps it from reaching
                // arbitrarily small residuals — see PLAN M1 notes).
                converged = true; how = "FP32 residual floor (plateau)"
            }
        }
        prev = cur
        if converged { break }
    }
    return CavityRun(sim: sim, nInterior: n, converged: converged,
                     steps: sim.stepsDone, residual: residual, howConverged: how)
}

/// Compare centerline profiles against Ghia. Interior fluid nodes are at
/// physical y = (iy - 0.5)/n for iy = 1...n (array row iy). x = 0.5 lies
/// exactly between columns n/2 and n/2+1 — average them.
func ghiaComparison(run: CavityRun, re: Double) throws -> GateResult {
    let sim = run.sim
    let n = run.nInterior
    let m = try sim.probeMoments()
    let nx = sim.nx
    let ulid = Double(sim.ulidTarget)

    func u(atRow iy: Int) -> Double {
        let a = m[iy * nx + n / 2].x
        let b = m[iy * nx + n / 2 + 1].x
        return Double(a + b) / 2.0 / ulid
    }
    func v(atCol ix: Int) -> Double {
        let a = m[(n / 2) * nx + ix].y
        let b = m[(n / 2 + 1) * nx + ix].y
        return Double(a + b) / 2.0 / ulid
    }
    // Linear interpolation to an oracle coordinate: nodes at (k-0.5)/n, k=1...n.
    func interp(_ coord: Double, _ value: (Int) -> Double) -> Double {
        let s = coord * Double(n) + 0.5
        let k0 = min(max(Int(s.rounded(.down)), 1), n - 1)
        let frac = s - Double(k0)
        return value(k0) * (1 - frac) + value(k0 + 1) * frac
    }
    func oracle(_ r100: Double, _ r400: Double, _ r1000: Double) -> Double {
        switch re {
        case 100: return r100
        case 400: return r400
        default: return r1000
        }
    }

    var sumSq = 0.0
    var maxDev = 0.0
    var count = 0
    var lines: [String] = []
    for row in ghiaU {
        let ours = interp(row.y, u(atRow:))
        let ref = oracle(row.re100, row.re400, row.re1000)
        let d = ours - ref
        sumSq += d * d; maxDev = max(maxDev, abs(d)); count += 1
        lines.append(String(format: "  u(y=%.4f): karman %+.5f  ghia %+.5f  Δ %+.5f", row.y, ours, ref, d))
    }
    for row in ghiaV {
        let ours = interp(row.x, v(atCol:))
        let ref = oracle(row.re100, row.re400, row.re1000)
        let d = ours - ref
        sumSq += d * d; maxDev = max(maxDev, abs(d)); count += 1
        lines.append(String(format: "  v(x=%.4f): karman %+.5f  ghia %+.5f  Δ %+.5f", row.x, ours, ref, d))
    }
    let rms = (sumSq / Double(count)).squareRoot()
    let passed = rms <= 0.02
    let detail = String(format: "RMS %.4f (gate ≤0.02), max |Δ| %.4f, %@ after %d steps (residual %.1e)",
                        rms, maxDev,
                        run.converged ? "converged (\(run.howConverged))" : "NOT converged",
                        run.steps, run.residual)
    return GateResult(name: String(format: "cavity Re=%.0f vs Ghia (%d²)", re, n),
                      passed: passed && run.converged,
                      detail: detail + "\n" + lines.joined(separator: "\n"))
}

// MARK: - Determinism

func runDeterminism(gpu: GPU) throws -> GateResult {
    func cavityDigest() throws -> String {
        let run = try cavity(gpu: gpu, n: 128, re: 1000, maxSteps: 10000,
                             checkEvery: 10000, tol: 0)
        return run.sim.stateDigest
    }
    let a = try cavityDigest()
    let b = try cavityDigest()

    func benchDigest() throws -> String {
        let sim = try Simulation(gpu: gpu, nx: 128, ny: 128, nz: 128, omega: 1.9) { _, _, _ in .fluid }
        try sim.initTaylorGreen()
        try sim.run(steps: 100)
        return sim.stateDigest
    }
    let c = try benchDigest()
    let d = try benchDigest()

    let passed = a == b && c == d
    return GateResult(name: "bitwise determinism (run-twice)",
                      passed: passed,
                      detail: passed
                        ? "cavity 128² ×10k steps and 128³ TG ×100 steps: digests identical (\(a.prefix(16))…)"
                        : "DIGEST MISMATCH — cavity: \(a.prefix(16)) vs \(b.prefix(16)); bench: \(c.prefix(16)) vs \(d.prefix(16))")
}
