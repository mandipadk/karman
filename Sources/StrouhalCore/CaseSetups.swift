import Foundation

/// Supersampled solid fraction of a disk over the cell grid (16×16 per cell)
/// — the input Noble-Torczynski cells need; STL voxelization produces the
/// same field later.
public func diskSolidFractions(nx: Int, ny: Int, cx: Double, cy: Double, r: Double) -> [Float] {
    var eps = [Float](repeating: 0, count: nx * ny)
    let r2 = r * r
    let sub = 16
    let lo = Int(cx - r) - 2, hi = Int(cx + r) + 2
    let loY = Int(cy - r) - 2, hiY = Int(cy + r) + 2
    for y in max(0, loY)...min(ny - 1, hiY) {
        for x in max(0, lo)...min(nx - 1, hi) {
            var inside = 0
            for sy in 0..<sub { for sx in 0..<sub {
                let px = Double(x) - 0.5 + (Double(sx) + 0.5) / Double(sub)
                let py = Double(y) - 0.5 + (Double(sy) + 0.5) / Double(sub)
                let dx = px - cx, dy = py - cy
                if dx * dx + dy * dy <= r2 { inside += 1 }
            }}
            eps[y * nx + x] = Float(inside) / Float(sub * sub)
        }
    }
    return eps
}

/// The Kármán vortex street (DFG 2D-2 geometry, NT cylinder, sponge, cosine
/// ramp) — shared by the CLI gates and the instrument app.
public struct VortexStreetCase {
    public let sim: Simulation
    public let D: Int
    public let uMean: Double
    public let uMax: Float
    public let boxX: ClosedRange<Int>
    public let boxY: ClosedRange<Int>

    public init(gpu: GPU, D: Int = 40, uinMax: Float = 0.075, lengthD: Int = 22,
                spongeD: Int = 3, spongeTau: Float = 1.0, re: Double = 100.0,
                wantsForces: Bool = true) throws {
        let nx = lengthD * D + 2
        let ny = Int(4.1 * Double(D)) + 2
        let uMean = Double(uinMax) * 2.0 / 3.0
        let nu = uMean * Double(D) / re
        let (wp, wm) = Simulation.trtOmegas(tau: 3.0 * nu + 0.5, lambda: 3.0 / 16.0)
        let cx = 0.5 + 2.0 * Double(D)
        let cy = 0.5 + 2.0 * Double(D)
        let sim = try Simulation(gpu: gpu, nx: nx, ny: ny, nz: 1,
                                 omega: wp, omegaMinus: wm,
                                 uin: uinMax, rampSteps: 24_000,
                                 wantsForces: wantsForces) { x, y, _ in
            if y == 0 || y == ny - 1 { return .solid }
            if x == 0 || x == nx - 1 { return .inflow }
            return .fluid
        }
        try sim.setSolidFractions(diskSolidFractions(nx: nx, ny: ny, cx: cx, cy: cy,
                                                     r: Double(D) / 2.0))
        sim.sponge = (x0: Float(nx - 1 - spongeD * D), width: Float(spongeD * D), tau: spongeTau)
        self.sim = sim
        self.D = D
        self.uMean = uMean
        self.uMax = uinMax
        self.boxX = (Int(cx) - D / 2 - 3)...(Int(cx) + D / 2 + 3)
        self.boxY = (Int(cy) - D / 2 - 3)...(Int(cy) + D / 2 + 3)
    }
}

/// Solid fractions of a sphere (8×8×8 supersampled) — the 3D NT body.
public func sphereSolidFractions(nx: Int, ny: Int, nz: Int,
                                 cx: Double, cy: Double, cz: Double,
                                 r: Double) -> [Float] {
    var eps = [Float](repeating: 0, count: nx * ny * nz)
    let r2 = r * r
    let sub = 8
    for z in max(0, Int(cz - r) - 2)...min(nz - 1, Int(cz + r) + 2) {
        for y in max(0, Int(cy - r) - 2)...min(ny - 1, Int(cy + r) + 2) {
            for x in max(0, Int(cx - r) - 2)...min(nx - 1, Int(cx + r) + 2) {
                var inside = 0
                for sz in 0..<sub { for sy in 0..<sub { for sx in 0..<sub {
                    let px = Double(x) - 0.5 + (Double(sx) + 0.5) / Double(sub)
                    let py = Double(y) - 0.5 + (Double(sy) + 0.5) / Double(sub)
                    let pz = Double(z) - 0.5 + (Double(sz) + 0.5) / Double(sub)
                    let dx = px - cx, dy = py - cy, dz = pz - cz
                    if dx * dx + dy * dy + dz * dz <= r2 { inside += 1 }
                }}}
                eps[(z * ny + y) * nx + x] = Float(inside) / Float(sub * sub * sub)
            }
        }
    }
    return eps
}

/// 3D flow past a sphere: uniform inflow (+x velocity walls both ends),
/// periodic lateral boundaries, NT sphere, outlet sponge. Reference for the
/// drag readout: Schiller–Naumann, C_D = 24/Re · (1 + 0.15 Re^0.687).
public struct SphereCase {
    public let sim: Simulation
    public let D: Int
    public let u: Double
    public let re: Double
    public let boxX: ClosedRange<Int>
    public let boxY: ClosedRange<Int>
    public let cdRef: Double

    public init(gpu: GPU, D: Int = 48, size: (Int, Int, Int) = (192, 192, 192),
                u: Float = 0.05, re: Double = 100.0) throws {
        let (nx, ny, nz) = size
        let nu = Double(u) * Double(D) / re
        let (wp, wm) = Simulation.trtOmegas(tau: 3.0 * nu + 0.5, lambda: 3.0 / 16.0)
        let cx = 0.5 + 1.5 * Double(D)
        let cy = Double(ny) / 2.0, cz = Double(nz) / 2.0
        let sim = try Simulation(gpu: gpu, nx: nx, ny: ny, nz: nz,
                                 omega: wp, omegaMinus: wm,
                                 uin: u, rampSteps: 8000, wantsForces: true) { x, _, _ in
            (x == 0 || x == nx - 1) ? .inflow : .fluid
        }
        sim.inflowUniform = true
        try sim.setSolidFractions(sphereSolidFractions(nx: nx, ny: ny, nz: nz,
                                                       cx: cx, cy: cy, cz: cz,
                                                       r: Double(D) / 2.0))
        sim.sponge = (x0: Float(nx - 1 - D), width: Float(D), tau: 1.0)
        self.sim = sim
        self.D = D
        self.u = Double(u)
        self.re = re
        self.boxX = (Int(cx) - D / 2 - 3)...(Int(cx) + D / 2 + 3)
        self.boxY = (Int(cy) - D / 2 - 3)...(Int(cy) + D / 2 + 3)
        self.cdRef = 24.0 / re * (1.0 + 0.15 * pow(re, 0.687))
    }

    /// C_D from a force probe (frontal area π D²/4).
    public func dragCoefficient(_ f: SIMD3<Double>) -> Double {
        2.0 * f.x / (u * u * Double.pi * Double(D * D) / 4.0)
    }
}

/// 2D lid-driven cavity (the Ghia case) for the instrument.
public struct CavityCase {
    public let sim: Simulation
    public let n: Int
    public let ulid: Float
    public let re: Double

    public init(gpu: GPU, n: Int = 256, re: Double = 1000, ulid: Float = 0.1) throws {
        let nu = Double(ulid) * Double(n) / re
        let (wp, wm) = Simulation.trtOmegas(tau: 3.0 * nu + 0.5, lambda: 0.25)
        let nx = n + 2, ny = n + 2
        let sim = try Simulation(gpu: gpu, nx: nx, ny: ny, nz: 1,
                                 omega: wp, omegaMinus: wm, lid: SIMD3(ulid, 0, 0),
                                 rampSteps: 5000) { x, y, _ in
            if y == ny - 1 { return .lid }
            if x == 0 || x == nx - 1 || y == 0 { return .solid }
            return .fluid
        }
        self.sim = sim
        self.n = n
        self.ulid = ulid
        self.re = re
    }
}

/// The vortex street as a ladderable case: rebuild at any resolution and any
/// Mach scale, probe mean C_D. This is the reference implementation of
/// `LadderableCase` and what the M4 credibility gate exercises.
public struct StreetLadder: LadderableCase {
    public let re: Double
    public let baseMach: Double
    public init(re: Double = 100, baseMach: Double = 0.075) {
        self.re = re
        self.baseMach = baseMach
    }

    public var setupDescription: String {
        String(format: "Schäfer–Turek DFG 2D-2 · cylinder in a channel · Re %.0f · velocity-wall inlet and outlet · NT curved body · outlet sponge · cosine ramp", re)
    }
    public var geometryClass: String { "bluff body in channel" }

    public func variant(gpu: GPU, cellsPerFeature: Int, machScale: Double) throws -> LadderVariant {
        let u = Float(baseMach * machScale)
        let c = try VortexStreetCase(gpu: gpu, D: cellsPerFeature, uinMax: u, re: re)
        // Physical time is what matters: at half the lattice velocity the flow
        // needs twice the steps to travel the same distance, and a finer grid
        // needs proportionally more steps again (diffusive scaling of the
        // convective time). Scale the schedule so every rung sees the same
        // number of shedding cycles.
        let scale = Double(cellsPerFeature) / 40.0 / machScale
        let transient = Int(60_000 * scale) & ~1
        // Sample ~45 shedding cycles: batch means need batches several cycles
        // long to decorrelate, and 22 cycles could not supply that (measured
        // lag-1 ρ = 0.61 at 12 batches).
        let sample = Int(120_000 * scale) & ~1
        let stride = max(8, Int(26 * scale)) & ~1
        let uMean = c.uMean
        return LadderVariant(
            sim: c.sim,
            mach: Double(u) * 2.0 / 3.0 * 3.0.squareRoot(),  // Ma of U_mean
            probe: { sim in
                let f = try sim.probeForce(xRange: c.boxX, yRange: c.boxY)
                return 2.0 * f.x / (uMean * uMean * Double(cellsPerFeature))
            },
            transientSteps: transient, sampleSteps: sample, stride: stride)
    }
}
