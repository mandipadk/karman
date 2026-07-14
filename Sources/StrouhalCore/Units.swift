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
        /// Cells across the body/feature, when the case has one.
        public let cellsPerFeature: Int?
        /// Reynolds number of the case, when defined.
        public let re: Double?

        public var ok: Bool { warnings.isEmpty }

        public var warnings: [String] {
            var w: [String] = []
            if mach > 0.17 {
                w.append(String(format: "Ma %.3f > 0.17 — O(Ma²) compressibility error above ~1%%", mach))
            }
            if tau <= 0.5 {
                w.append("τ ≤ 0.5 — unstable")
            } else if tau < 0.51 {
                w.append(String(format: "τ %.4f — under-resolved; the answer leans on the LES model, not the grid", tau))
            }
            if tau >= 1.3 {
                w.append(String(format: "τ %.2f ≥ 1.3 — over-relaxed, accuracy degrades", tau))
            }
            // Boundary-layer resolution: a bluff body's laminar BL thickness
            // scales as D/sqrt(Re), so resolving it needs O(sqrt(Re)) cells
            // across the body. Far below that the near-wall flow is modeled
            // rather than computed — say so instead of printing a confident
            // drag coefficient.
            if let n = cellsPerFeature, let re, re > 1e3 {
                let needed = 2.0 * re.squareRoot()
                if Double(n) < needed {
                    w.append(String(format: "%d cells across the body at Re %.0f — boundary layer NOT resolved (want ≳%.0f); forces are indicative only",
                                    n, re, needed))
                }
            }
            return w
        }
    }

    public func envelope(speed: Double, nu: Double,
                         cellsPerFeature: Int? = nil) -> Envelope {
        let re = cellsPerFeature.map { speed * dx * Double($0) / nu }
        return Envelope(mach: velocity(toLattice: speed) * 3.0.squareRoot(),
                        tau: tau(nu: nu), cellsPerFeature: cellsPerFeature, re: re)
    }
}
