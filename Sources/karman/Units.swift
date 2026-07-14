import Foundation

/// SI <-> lattice-unit conversion (dx = dt = rho0 = 1 internally) with the
/// method's validity envelope made explicit — a verification-first tool must
/// refuse to silently exceed it.
struct UnitScales {
    let dx: Double      // m per cell
    let dt: Double      // s per step
    let rho: Double     // kg/m^3 per lattice-density unit

    /// Choose scales from a physical length (mapped to `cells`), a physical
    /// speed (mapped to `latticeSpeed`), and the fluid density.
    init(length: Double, cells: Int, speed: Double, latticeSpeed: Double, density: Double) {
        dx = length / Double(cells)
        dt = latticeSpeed * dx / speed
        rho = density
    }

    func velocity(toLattice v: Double) -> Double { v * dt / dx }
    func velocity(toSI v: Double) -> Double { v * dx / dt }
    func kinematicViscosity(toLattice nu: Double) -> Double { nu * dt / (dx * dx) }
    func time(toLattice t: Double) -> Double { t / dt }
    func force(toSI f: Double) -> Double { f * rho * dx * dx * dx * dx / (dt * dt) } // per unit depth handled by caller

    /// tau for a physical kinematic viscosity.
    func tau(nu: Double) -> Double { 3.0 * kinematicViscosity(toLattice: nu) + 0.5 }

    struct Envelope {
        let mach: Double
        let tau: Double
        var ok: Bool { mach <= 0.17 && tau > 0.5 && tau < 1.3 }
        var warnings: [String] {
            var w: [String] = []
            if mach > 0.17 { w.append(String(format: "Ma=%.3f > 0.17: O(Ma²) compressibility error exceeds ~1%%", mach)) }
            if tau <= 0.5 { w.append("tau <= 0.5: unstable without LES") }
            if tau >= 1.3 { w.append(String(format: "tau=%.2f >= 1.3: accuracy degrades (over-relaxed)", tau)) }
            return w
        }
    }

    func envelope(speed: Double, nu: Double) -> Envelope {
        Envelope(mach: velocity(toLattice: speed) * 3.0.squareRoot(), tau: tau(nu: nu))
    }
}
