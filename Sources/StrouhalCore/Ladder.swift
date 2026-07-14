import Foundation

/// Runs the extra simulations an honest error bar needs — a resolution ladder
/// plus a half-Mach anchor — and assembles the budget. This is the thing the
/// incumbents price as a paid add-on and practitioners therefore skip: on this
/// hardware it is minutes, so it is the default, not an upsell.
public struct CredibilityRun: Sendable {
    public let qoi: String
    public let budget: UncertaintyBudget
    public let rungs: [LadderRung]
    public let numNote: String
    public let observedOrder: Double?
    public let statBatches: Int
    public let statLag1: Double
    public let machBaseline: Double
    public let machHalf: Double
    public let wallSeconds: Double
    public let digest: String
    public let setup: String
}

/// A case the ladder can rebuild at an arbitrary resolution and Mach number.
/// (The vortex street is the reference implementation; STL bodies conform too.)
public protocol LadderableCase {
    /// Human-readable setup, for the report.
    var setupDescription: String { get }
    /// Reynolds number, Mach number, geometry class — for the validation domain.
    var re: Double { get }
    var geometryClass: String { get }
    /// Build a variant at `cellsPerFeature` resolution and `machScale` × the
    /// baseline lattice velocity; return (sim, a probe for the QoI, steps to
    /// discard as transient, steps to sample, sampling stride).
    func variant(gpu: GPU, cellsPerFeature: Int, machScale: Double) throws -> LadderVariant
}

public struct LadderVariant {
    public let sim: Simulation
    public let mach: Double
    public let probe: (Simulation) throws -> Double
    public let transientSteps: Int
    public let sampleSteps: Int
    public let stride: Int
    public init(sim: Simulation, mach: Double,
                probe: @escaping (Simulation) throws -> Double,
                transientSteps: Int, sampleSteps: Int, stride: Int) {
        self.sim = sim; self.mach = mach; self.probe = probe
        self.transientSteps = transientSteps; self.sampleSteps = sampleSteps
        self.stride = stride
    }
}

public enum Ladder {
    /// Run one variant and return its time-averaged QoI with statistics.
    public static func measure(_ v: LadderVariant, qoi name: String) throws
        -> (series: QoISeries, stat: StatUncertainty, digest: String) {
        try v.sim.run(steps: v.transientSteps & ~1)
        var series = QoISeries(name: name)
        var taken = 0
        while taken < v.sampleSteps {
            let chunk = max(2, v.stride - 2) & ~1
            try v.sim.run(steps: chunk)
            let value = try v.probe(v.sim)   // probe advances 2 steps
            taken += chunk + 2
            series.append(step: Double(v.sim.stepsDone), value: value)
        }
        // Discard the first half of the sampled record: even after the nominal
        // transient, slow drifts remain, and a batch-means CI over a drifting
        // record understates the true uncertainty.
        let tail = series.stationaryTail(discarding: 0.5)
        return (tail, StatUncertainty(series: tail), v.sim.stateDigest)
    }

    /// The full credibility run: N resolutions + a half-Mach anchor.
    public static func credibility(gpu: GPU, case c: LadderableCase, qoi name: String,
                                   resolutions: [Int],
                                   progress: ((String) -> Void)? = nil) throws -> CredibilityRun {
        let t0 = Date()
        var rungs: [LadderRung] = []
        var finestStat: StatUncertainty? = nil
        var finestDigest = ""
        var finestMach = 0.0

        for n in resolutions.sorted() {
            progress?("resolution \(n) cells/feature…")
            let v = try c.variant(gpu: gpu, cellsPerFeature: n, machScale: 1.0)
            let (series, stat, digest) = try measure(v, qoi: name)
            rungs.append(LadderRung(cellsPerFeature: n, value: series.mean,
                                    stat: stat.halfWidth95))
            if n == resolutions.max() {
                finestStat = stat
                finestDigest = digest
                finestMach = v.mach
            }
        }

        progress?("half-Mach anchor…")
        let finest = resolutions.max()!
        let vHalf = try c.variant(gpu: gpu, cellsPerFeature: finest, machScale: 0.5)
        let (halfSeries, _, _) = try measure(vHalf, qoi: name)

        let num = NumUncertainty(rungs: rungs)
        let stat = finestStat!
        let mach = MachUncertainty(baseline: rungs.last!.value, halfMach: halfSeries.mean)
        let verdict = ValidationDomain.classify(re: c.re, mach: finestMach,
                                                cellsPerFeature: finest,
                                                geometry: c.geometryClass)
        var notes: [String] = [num.note]
        if !stat.trustworthy {
            notes.append(String(format: "statistics weak: %d batches, lag-1 ρ = %.2f — average over more shedding cycles",
                                stat.batches, stat.lag1))
        }
        let budget = UncertaintyBudget(qoi: name, value: rungs.last!.value,
                                       uNum: num.uNum, uStat: stat.halfWidth95,
                                       uMa: mach.uMa, verdict: verdict, notes: notes)
        return CredibilityRun(qoi: name, budget: budget, rungs: rungs,
                              numNote: num.note, observedOrder: num.observedOrder,
                              statBatches: stat.batches, statLag1: stat.lag1,
                              machBaseline: mach.baseline, machHalf: mach.halfMach,
                              wallSeconds: -t0.timeIntervalSinceNow,
                              digest: finestDigest, setup: c.setupDescription)
    }
}

// MARK: - Report

public enum CredibilityReport {
    /// Markdown, in ASME V&V 20 vocabulary (the standard the FDA recognizes),
    /// with the parts we cannot estimate named as such.
    public static func markdown(_ r: CredibilityRun, buildGates: [String]) -> String {
        var s = "# Credibility report — \(r.qoi)\n\n"
        s += "_Generated by Strouhal · \(ISO8601DateFormatter().string(from: Date()))_\n\n"
        s += "## Result\n\n"
        s += "**\(r.budget.headline)**\n\n"
        s += "\(r.setup)\n\n"

        s += "## Uncertainty budget\n\n"
        s += "U(φ) = k·√(u_num² + u_stat² + u_Ma²), k = 2 (≈95%)\n\n"
        s += "| Component | Value | Basis |\n|---|---|---|\n"
        s += String(format: "| u_num (discretization) | %.4f | %@ |\n", r.budget.uNum, r.numNote)
        s += String(format: "| u_stat (time average) | %.4f | non-overlapping batch means, %d batches, lag-1 ρ = %.2f |\n",
                    r.budget.uStat, r.statBatches, r.statLag1)
        s += String(format: "| u_Ma (compressibility) | %.4f | half-Mach anchor: %.4f → %.4f, O(Ma²) extrapolation |\n",
                    r.budget.uMa, r.machBaseline, r.machHalf)
        switch r.budget.verdict {
        case .inside(let a):
            s += String(format: "| **U(φ) (k=2)** | **%.4f** | inside the validated domain (%@) |\n",
                        r.budget.combined, a)
        case .nearEdge(let a, let f):
            s += String(format: "| **U(φ) (k=2)** | **%.4f** | near the edge of the validated domain (%@); inflated ×%.2f |\n",
                        r.budget.combined, a, f)
        case .outside:
            s += "| **U(φ)** | **not published** | outside the validated domain — see below |\n"
        }
        s += "\n"

        s += "## Resolution ladder\n\n| cells/feature | φ | u_stat |\n|---|---|---|\n"
        for rung in r.rungs {
            s += String(format: "| %d | %.4f | %.4f |\n", rung.cellsPerFeature, rung.value, rung.stat)
        }
        if let o = r.observedOrder {
            s += String(format: "\nObserved order of convergence: **%.2f** — reported as a diagnostic only. ", o)
            s += "It is **not** used to build the error bar: Richardson extrapolation assumes monotone convergence at a fitted order, which scale-resolving simulations do not guarantee (discretization and subgrid-model error are coupled). No GCI is claimed.\n"
        } else {
            s += "\nNo observed order reported: the ladder is not monotone-convergent, so a fitted order would be meaningless.\n"
        }
        s += "\n"

        s += "## Validation domain\n\n"
        switch r.budget.verdict {
        case .inside(let a):
            s += "This run lies **inside** the domain validated by: \(a).\n"
        case .nearEdge(let a, let f):
            s += String(format: "This run lies **near the edge** of the domain validated by: %@. The uncertainty is inflated by ×%.2f with extrapolation distance, per Oberkampf & Roy.\n", a, f)
        case .outside(let reasons):
            s += "**This run lies OUTSIDE the validated domain.** No calibrated uncertainty is published, because none is defensible.\n\n"
            for reason in reasons { s += "- \(reason)\n" }
            s += "\nThe numbers above are the solver's output; they are not a measurement with a warranty.\n"
        }
        s += "\n"

        if !r.budget.notes.isEmpty {
            s += "## Notes\n\n"
            for n in r.budget.notes where !n.isEmpty { s += "- \(n)\n" }
            s += "\n"
        }

        s += "## Solver verification (this build)\n\n"
        for g in buildGates { s += "- \(g)\n" }
        s += "\n"

        s += "## Reproducibility\n\n"
        s += "- Final state digest (SHA-256): `\(r.digest)`\n"
        s += String(format: "- Total wall time for the full credibility run: %.1f s\n", r.wallSeconds)
        s += "- Same machine, same build, same settings ⇒ bitwise-identical state and identical QoIs.\n\n"

        s += "## What this report does not claim\n\n"
        s += "- **No model-form uncertainty.** The subgrid/collision closure's own error is not bounded here; that needs multi-model variation (Klein 2005), which this run does not perform.\n"
        s += "- **No Grid Convergence Index.** See above — invalid for scale-resolving runs.\n"
        s += "- Numerical uncertainty being small does **not** mean the answer is right: in the FDA nozzle round-robin, u_num was under 1% while the model was ~33% off experiment. Validation against data is the only cure, and the validation-domain section above is where that cure is (or is not) claimed.\n"
        return s
    }
}
