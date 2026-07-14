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
