import Foundation

/// SI <-> lattice-unit conversion (dx = dt = rho0 = 1 internally) with the
/// method's validity envelope made explicit — a verification-first tool must
/// refuse to silently exceed it.
public struct UnitScales {
    public let dx: Double      // m per cell
    public let dt: Double      // s per step
    public let rho: Double     // kg/m^3 per lattice-density unit

    /// Choose scales from a physical length (mapped to `cells`), a physical
    /// speed (mapped to `latticeSpeed`), and the fluid density.
    public init(length: Double, cells: Int, speed: Double, latticeSpeed: Double, density: Double) {
        dx = length / Double(cells)
        dt = latticeSpeed * dx / speed
        rho = density
    }

    public func velocity(toLattice v: Double) -> Double { v * dt / dx }
    public func velocity(toSI v: Double) -> Double { v * dx / dt }
    public func kinematicViscosity(toLattice nu: Double) -> Double { nu * dt / (dx * dx) }
    public func time(toLattice t: Double) -> Double { t / dt }
    public func force(toSI f: Double) -> Double { f * rho * dx * dx * dx * dx / (dt * dt) } // per unit depth handled by caller

    /// tau for a physical kinematic viscosity.
    public func tau(nu: Double) -> Double { 3.0 * kinematicViscosity(toLattice: nu) + 0.5 }

    public struct Envelope {
        public let mach: Double
        public let tau: Double
        public var ok: Bool { mach <= 0.17 && tau > 0.5 && tau < 1.3 }
        public var warnings: [String] {
            var w: [String] = []
            if mach > 0.17 { w.append(String(format: "Ma=%.3f > 0.17: O(Ma²) compressibility error exceeds ~1%%", mach)) }
            if tau <= 0.5 { w.append("tau <= 0.5: unstable without LES") }
            if tau >= 1.3 { w.append(String(format: "tau=%.2f >= 1.3: accuracy degrades (over-relaxed)", tau)) }
            return w
        }
    }

    public func envelope(speed: Double, nu: Double) -> Envelope {
        Envelope(mach: velocity(toLattice: speed) * 3.0.squareRoot(), tau: tau(nu: nu))
    }
}
