import SwiftUI
import MetalKit
import StrouhalCore

// The instrument, M3: case picker (vortex street / cavity / 3D sphere),
// SI-units + envelope readout, live QoIs with a drag sparkline, |u| slice
// visualization. Compute and render share one queue (two-queue at M4).

@main
struct StrouhalApp: App {
    @StateObject private var controller = SimController()
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some Scene {
        WindowGroup("Strouhal") {
            ContentView().environmentObject(controller)
        }
    }
}

enum FlowCase: String, CaseIterable, Identifiable {
    case street = "Vortex street (2D, Re 100)"
    case cavity = "Lid cavity (2D, Re 1000)"
    case sphere = "Sphere wake (3D, Re 100)"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var controller: SimController
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Case", selection: $controller.selectedCase) {
                    ForEach(FlowCase.allCases) { c in Text(c.rawValue).tag(c) }
                }
                .frame(width: 320)
                Button(controller.running ? "Pause" : "Run") { controller.running.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Reset") { controller.reset() }
                Slider(value: $controller.budgetMs, in: 2...30, step: 1) {
                    Text("GPU budget/frame (ms)")
                }.frame(width: 220)
                Button("Import STL…") { controller.beginImport() }
                Button("Export QoIs…") { controller.exportCSV() }
                    .disabled(!controller.hasHistory)
                Button(controller.hardening ? "Hardening…" : "Harden this number") {
                    controller.harden()
                }
                .disabled(controller.hardening || !controller.canHarden)
                Spacer()
            }
            .padding(10)
            MetalView()
                .aspectRatio(CGFloat(controller.aspect), contentMode: .fit)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.setupLine)
                    Text(controller.envelopeLine)
                }
                .font(.system(.caption, design: .monospaced))
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.statsLine)
                    Text(controller.qoiLine)
                }
                .font(.system(.caption, design: .monospaced))
                SparklineView(values: controller.sparkline)
                    .frame(width: 180, height: 34)
                Spacer()
            }
            .padding(10)
            Divider()
            TruthPanel()
                .padding(10)
        }
        .frame(minWidth: 980, minHeight: 380)
        .onChange(of: controller.selectedCase) { controller.selectBuiltin() }
        .fileImporter(isPresented: $controller.showImporter,
                      allowedContentTypes: [.data, .item]) { result in
            if case .success(let url) = result { controller.stlChosen(url) }
        }
        .sheet(isPresented: $controller.showUnitsSheet) {
            UnitsSheet().environmentObject(controller)
        }
    }
}

/// The mandatory units prompt: STL carries no units, and a silent unit
/// error would poison every number downstream of a verification-first tool.
struct UnitsSheet: View {
    @EnvironmentObject var controller: SimController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("STL has no units — define the physics")
                .font(.headline)
            Form {
                TextField("Body length along x (m)", value: $controller.stlLengthM, format: .number)
                TextField("Flow speed (m/s)", value: $controller.stlSpeedMS, format: .number)
                Picker("Fluid", selection: $controller.stlFluid) {
                    Text("Air (ν = 1.5e-5 m²/s)").tag(0)
                    Text("Water (ν = 1.0e-6 m²/s)").tag(1)
                }
            }
            Text(controller.stlPreview)
                .font(.system(.caption, design: .monospaced))
            HStack {
                Spacer()
                Button("Cancel") { controller.showUnitsSheet = false }
                Button("Run") { controller.buildCustom() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}

/// The truth panel: what the number is worth. Empty until you harden it —
/// because an error bar the tool has not earned is worse than none.
struct TruthPanel: View {
    @EnvironmentObject var controller: SimController
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Truth").font(.headline)
                if controller.hardening {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(controller.hardenStatus)
                            .font(.system(.caption, design: .monospaced))
                    }
                } else if let h = controller.headline {
                    Text(h)
                        .font(.system(.body, design: .monospaced).bold())
                        .foregroundStyle(controller.outsideDomain ? .orange : .primary)
                    ForEach(controller.truthLines, id: \.self) { line in
                        Text(line).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button("Save credibility report…") { controller.saveReport() }
                        .padding(.top, 2)
                } else if controller.canHarden {
                    Text("Press “Harden this number” to run a resolution ladder and a Mach anchor (minutes) and earn an error bar.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This case has no ladderable QoI yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

struct SparklineView: View {
    let values: [Double]
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 2,
                  let lo = values.min(), let hi = values.max(), hi > lo else { return }
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = size.height * (1 - CGFloat((v - lo) / (hi - lo)))
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(.cyan), lineWidth: 1.2)
        }
        .background(Color.black.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct MetalView: NSViewRepresentable {
    @EnvironmentObject var controller: SimController
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: controller.gpu.device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.delegate = controller
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {}
}

/// Multiplicative feedback on total frame GPU time: a per-step EMA death-
/// spirals on small cases (fixed per-frame overhead pollutes the estimate);
/// steering step COUNT against the measured whole-buffer time is
/// overhead-agnostic and converges to the budget from either side.
final class CostTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: Int = 20
    func record(seconds: Double, steps encoded: Int, budget: Double) {
        guard encoded > 0, seconds > 0 else { return }
        lock.lock()
        if seconds < budget * 0.8 { steps = min(4000, Int(Double(steps) * 1.25) & ~1 + 2) }
        else if seconds > budget { steps = max(2, Int(Double(steps) * 0.75) & ~1) }
        lock.unlock()
    }
    var stepsPerFrame: Int {
        lock.lock(); defer { lock.unlock() }
        return steps
    }
}

/// One running case: the simulation plus everything the UI needs to read it.
struct ActiveCase {
    let sim: Simulation
    let uref: Float
    let zSlice: Int
    let setupLine: String
    let envelope: UnitScales.Envelope
    let probe: ((Simulation) throws -> (cd: Double, cl: Double))?
    let strouhalD: Double?   // D/(period·uMean) inputs when St applies
    let strouhalU: Double?
    let qoiStatic: ((Simulation) -> String)?
}

@MainActor
final class SimController: NSObject, ObservableObject, MTKViewDelegate {
    let gpu: GPU
    private var active: ActiveCase
    private var colorize: MTLComputePipelineState
    private var quad: MTLRenderPipelineState
    private var fieldTex: MTLTexture

    @Published var selectedCase: FlowCase = .street
    @Published var running = true
    @Published var budgetMs: Double = 12
    // STL import flow
    @Published var showImporter = false
    @Published var showUnitsSheet = false
    @Published var stlLengthM: Double = 0.1
    @Published var stlSpeedMS: Double = 0.5
    @Published var stlFluid: Int = 0
    private var stlURL: URL?
    private var stlMesh: StlMesh?
    // Truth panel
    @Published var hardening = false
    @Published var hardenStatus = ""
    @Published var headline: String?
    @Published var truthLines: [String] = []
    @Published var outsideDomain = false
    private var lastRun: CredibilityRun?
    /// Only cases with a ladderable definition can be hardened.
    var canHarden: Bool { selectedCase == .street && stlMesh == nil }
    /// Rebuilds the current case (builtin picker choice or imported STL).
    private var currentBuilder: (() throws -> ActiveCase)!
    var hasHistory: Bool { !history.isEmpty }
    var stlPreview: String {
        guard let mesh = stlMesh else { return "" }
        let nu = stlFluid == 0 ? 1.5e-5 : 1.0e-6
        let re = stlSpeedMS * stlLengthM / nu
        let ext = mesh.boundsMax - mesh.boundsMin
        return String(format: "%d triangles · extent %.2g × %.2g × %.2g (mesh units) · Re %.0f%@",
                      mesh.triangles.count, ext.x, ext.y, ext.z, re,
                      re > 5e4 ? " ⚠ high Re: LES will be enabled" : "")
    }
    @Published var statsLine = "starting…"
    @Published var qoiLine = ""
    @Published var setupLine = ""
    @Published var envelopeLine = ""
    @Published var sparkline: [Double] = []

    private var frameCount = 0
    private var lastStatsTime = CACurrentMediaTime()
    private var lastProbeTime = CACurrentMediaTime()
    private var stepsSinceStats = 0
    private var history: [(t: Double, cd: Double, cl: Double)] = []
    /// Seconds of GPU time per simulation step (EMA), measured from command
    /// buffer timestamps — drives adaptive steps-per-frame so a 192³ case
    /// doesn't encode a multi-second (watchdog-fodder) command buffer.
    private let stepCost = CostTracker()

    var aspect: Double { Double(active.sim.nx) / Double(active.sim.ny) }

    override init() {
        gpu = try! GPU()
        active = try! Self.build(.street, gpu: gpu)
        currentBuilder = { [gpu] in try Self.build(.street, gpu: gpu) }
        (colorize, quad) = try! gpu.makeVizPipelines(precision: .fp32, pixelFormat: .bgra8Unorm)
        fieldTex = Self.makeFieldTexture(device: gpu.device, sim: active.sim)
        super.init()
        setupLine = active.setupLine
        envelopeLine = Self.envelopeText(active.envelope)
        if let secs = ProcessInfo.processInfo.environment["STROUHAL_APP_SECONDS"],
           let t = Double(secs) {
            if let c = ProcessInfo.processInfo.environment["STROUHAL_APP_CASE"],
               let fc = FlowCase.allCases.first(where: { $0.rawValue.lowercased().contains(c) }) {
                selectedCase = fc
                selectBuiltin()
            }
            if ProcessInfo.processInfo.environment["STROUHAL_APP_HARDEN"] != nil {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.harden()
                }
            }
            if let stl = ProcessInfo.processInfo.environment["STROUHAL_APP_STL"] {
                stlChosen(URL(fileURLWithPath: stl))
                showUnitsSheet = false
                buildCustom()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(t))
                print("AUTOTEST \(self?.statsLine ?? "") | \(self?.qoiLine ?? "")")
                print("SETUP    \(self?.setupLine ?? "")")
                print("ENVELOPE \(self?.envelopeLine ?? "")")
                if let h = self?.headline { print("TRUTH    \(h)") }
                for l in self?.truthLines ?? [] { print("         \(l)") }
                exit(0)
            }
        }
    }

    static func build(_ c: FlowCase, gpu: GPU) throws -> ActiveCase {
        switch c {
        case .street:
            let vs = try VortexStreetCase(gpu: gpu, D: 40, uinMax: 0.075)
            // The DFG 2D-2 SI definition: D = 0.1 m, U_mean = 1 m/s, nu = 1e-3 m²/s.
            let units = UnitScales(length: 0.1, cells: vs.D, speed: 1.0,
                                   latticeSpeed: vs.uMean, density: 1.0)
            return ActiveCase(
                sim: vs.sim, uref: vs.uMax * 1.6, zSlice: 0,
                setupLine: "DFG 2D-2 · D 0.1 m · U 1.0 m/s · Re 100 · \(vs.sim.nx)×\(vs.sim.ny)",
                envelope: units.envelope(speed: 1.0, nu: 1e-3, cellsPerFeature: vs.D),
                probe: { sim in
                    let f = try sim.probeForce(xRange: vs.boxX, yRange: vs.boxY)
                    let d = vs.uMean * vs.uMean * Double(vs.D)
                    return (2 * f.x / d, 2 * f.y / d)
                },
                strouhalD: Double(vs.D), strouhalU: vs.uMean, qoiStatic: nil)
        case .cavity:
            let cv = try CavityCase(gpu: gpu, n: 256, re: 1000)
            let units = UnitScales(length: 1.0, cells: cv.n, speed: 1.0,
                                   latticeSpeed: Double(cv.ulid), density: 1.0)
            return ActiveCase(
                sim: cv.sim, uref: cv.ulid, zSlice: 0,
                setupLine: "Ghia cavity · L 1 m · U_lid 1 m/s · Re 1000 · \(cv.sim.nx)²",
                envelope: units.envelope(speed: 1.0, nu: 1.0 / 1000.0),
                probe: nil, strouhalD: nil, strouhalU: nil,
                qoiStatic: { sim in
                    // u at the cavity center vs Ghia's -0.06080 (Re=1000)
                    guard let m = try? sim.probeMoments() else { return "" }
                    let n = cv.n
                    let u = (m[(n / 2) * sim.nx + n / 2].x + m[(n / 2 + 1) * sim.nx + n / 2].x)
                          / 2 / cv.ulid
                    return String(format: "u_center %+.4f (Ghia −0.0608)", u)
                })
        case .sphere:
            let sp = try SphereCase(gpu: gpu, D: 48, size: (192, 192, 192))
            // SI framing: a 5 cm sphere in air at Re 100.
            let units = UnitScales(length: 0.05, cells: sp.D, speed: 0.03,
                                   latticeSpeed: sp.u, density: 1.2)
            return ActiveCase(
                sim: sp.sim, uref: Float(sp.u) * 1.8, zSlice: sp.sim.nz / 2,
                setupLine: "Sphere wake · D 5 cm · U 0.03 m/s (air) · Re 100 · 192³",
                envelope: units.envelope(speed: 0.03, nu: 1.5e-5, cellsPerFeature: sp.D),
                probe: { sim in
                    let f = try sim.probeForce(xRange: sp.boxX, yRange: sp.boxY)
                    return (sp.dragCoefficient(f), 0)
                },
                strouhalD: nil, strouhalU: nil,
                qoiStatic: { _ in String(format: "C_D ref (Schiller–Naumann) %.3f", sp.cdRef) })
        }
    }

    static func envelopeText(_ e: UnitScales.Envelope) -> String {
        let head = String(format: "Ma %.3f · τ %.4f", e.mach, e.tau)
        return e.ok ? head + " · ✓ within the method's validity envelope"
                    : head + " · ⚠ " + e.warnings.joined(separator: " · ")
    }

    static func makeFieldTexture(device: MTLDevice, sim: Simulation) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                         width: sim.nx, height: sim.ny,
                                                         mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    func selectBuiltin() {
        let c = selectedCase
        currentBuilder = { [gpu] in try Self.build(c, gpu: gpu) }
        reset()
    }

    func beginImport() { showImporter = true }

    func stlChosen(_ url: URL) {
        do {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            stlMesh = try StlMesh(binarySTL: Data(contentsOf: url))
            stlURL = url
            showUnitsSheet = true
        } catch {
            statsLine = "STL load failed: \(error)"
        }
    }

    func buildCustom() {
        guard let mesh = stlMesh else { return }
        showUnitsSheet = false
        let name = stlURL?.lastPathComponent ?? "custom"
        let lengthM = stlLengthM, speedMS = stlSpeedMS
        let nu = stlFluid == 0 ? 1.5e-5 : 1.0e-6
        currentBuilder = { [gpu] in
            try Self.buildSTLCase(gpu: gpu, mesh: mesh, name: name,
                                  lengthM: lengthM, speedMS: speedMS, nuSI: nu)
        }
        reset()
    }

    /// Run the resolution ladder + Mach anchor on a BACKGROUND GPU queue so
    /// the live view keeps animating. (This is the use case that finally
    /// justifies a second command queue — M3's rendering never needed one.)
    func harden() {
        guard canHarden else { return }
        hardening = true
        hardenStatus = "starting…"
        headline = nil
        truthLines = []
        let ladderCase = StreetLadder()
        Task.detached(priority: .userInitiated) {
            do {
                let bgGPU = try GPU()   // its own device queue: never blocks the render loop
                let run = try Ladder.credibility(gpu: bgGPU, case: ladderCase,
                                                 qoi: "mean C_D",
                                                 resolutions: [32, 48, 64]) { msg in
                    Task { @MainActor in self.hardenStatus = msg }
                }
                await MainActor.run { self.finishHarden(run) }
            } catch {
                await MainActor.run {
                    self.hardening = false
                    self.hardenStatus = "failed: \(error)"
                }
            }
        }
    }

    private func finishHarden(_ run: CredibilityRun) {
        lastRun = run
        hardening = false
        let b = run.budget
        headline = b.headline
        if case .outside = b.verdict { outsideDomain = true } else { outsideDomain = false }
        var lines: [String] = []
        lines.append(String(format: "u_num %.4f · u_stat %.4f · u_Ma %.4f  →  U(φ) = k·√Σu² with k = 2",
                            b.uNum, b.uStat, b.uMa))
        lines.append("ladder: " + run.rungs.map { String(format: "%d→%.4f", $0.cellsPerFeature, $0.value) }
                        .joined(separator: "  ")
                     + String(format: "   half-Mach: %.4f→%.4f", run.machBaseline, run.machHalf))
        switch b.verdict {
        case .inside(let a): lines.append("validation domain: inside — \(a)")
        case .nearEdge(let a, let f): lines.append(String(format: "validation domain: near edge of %@ — bar inflated ×%.2f", a, f))
        case .outside(let r): lines.append("validation domain: OUTSIDE — " + r.joined(separator: "; "))
        }
        lines.append(String(format: "no Richardson/GCI (invalid for scale-resolving runs) · no model-form uncertainty · %.0f s", run.wallSeconds))
        for n in b.notes where !n.isEmpty && !n.hasPrefix("u_num =") { lines.append("⚠ " + n) }
        truthLines = lines
    }

    func saveReport() {
        guard let run = lastRun else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "credibility-report.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let md = CredibilityReport.markdown(run, buildGates: Self.buildGates)
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The gates this build passes — embedded in every report.
    static let buildGates = [
        "Ghia cavity Re=1000: centerline RMS 0.0039 of u_lid",
        "Poiseuille (TRT Λ=3/16): wall error 4.3e-7",
        "Taylor–Green: observed order 1.96",
        "Schäfer–Turek 2D-1: C_D within 0.16% (NT curved boundaries)",
        "Schäfer–Turek 2D-2: St 0.2996, max C_L 0.9998",
        "Determinism: run-twice state digests identical",
    ]

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "strouhal-qoi.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = "step,C_D,C_L\n"
        for h in history {
            csv += String(format: "%.0f,%.6f,%.6f\n", h.t, h.cd, h.cl)
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Flow past an imported body: uniform inflow, periodic lateral, NT body
    /// from the voxelized mesh, sponge before the outlet. LES enables itself
    /// when the Reynolds number pushes tau against the stability floor.
    static func buildSTLCase(gpu: GPU, mesh: StlMesh, name: String,
                             lengthM: Double, speedMS: Double, nuSI: Double) throws -> ActiveCase {
        let re = speedMS * lengthM / nuSI
        let D = 48 // cells along the body's longest axis
        let ext = mesh.boundsMax - mesh.boundsMin
        let maxExt = max(ext.x, max(ext.y, ext.z))
        let scale = Float(D) / maxExt
        let (nx, ny, nz) = (192, 128, 128)
        let u: Float = 0.05
        let nuLat = Double(u) * Double(D) / re
        var tau = 3.0 * nuLat + 0.5
        var cSmago: Float = 0
        if tau < 0.52 { cSmago = 0.04; }
        tau = max(tau, 0.5005)
        let (wp, wm) = Simulation.trtOmegas(tau: tau, lambda: 3.0 / 16.0)
        let sim = try Simulation(gpu: gpu, nx: nx, ny: ny, nz: nz,
                                 omega: wp, omegaMinus: wm,
                                 uin: u, rampSteps: 8000, cSmago: cSmago,
                                 wantsForces: true) { x, _, _ in
            (x == 0 || x == nx - 1) ? .inflow : .fluid
        }
        sim.inflowUniform = true
        let meshCenter = (mesh.boundsMin + mesh.boundsMax) * 0.5
        let target = SIMD3<Float>(Float(D) * 1.5, Float(ny) / 2, Float(nz) / 2)
        let eps = meshSolidFractions(mesh: mesh, nx: nx, ny: ny, nz: nz,
                                     scale: scale, offset: target - meshCenter * scale)
        try sim.setSolidFractions(eps)
        sim.sponge = (x0: Float(nx - 1 - D), width: Float(D), tau: 1.0)
        // Projected frontal area + the body's bounding box in cells. The probe
        // box MUST exclude the inlet/outlet velocity walls: they are moving-wall
        // cells whose (large, upstream-directed) momentum exchange would swamp
        // the body force — measured C_D = -4.06 before this was scoped.
        var area = 0.0
        var bx0 = nx, bx1 = -1, by0 = ny, by1 = -1
        for z in 0..<nz { for y in 0..<ny {
            var m: Float = 0
            for x in 0..<nx {
                let e = eps[(z * ny + y) * nx + x]
                if e > 0 {
                    bx0 = min(bx0, x); bx1 = max(bx1, x)
                    by0 = min(by0, y); by1 = max(by1, y)
                }
                m = max(m, e)
            }
            area += Double(m)
        }}
        guard bx1 >= bx0, by1 >= by0 else {
            throw StrouhalError.message("mesh voxelized to nothing — check units/scale")
        }
        let units = UnitScales(length: lengthM, cells: D, speed: speedMS,
                               latticeSpeed: Double(u), density: 1.2)
        let pad = 3
        let boxX = max(1, bx0 - pad)...min(nx - 2, bx1 + pad)
        let boxY = max(0, by0 - pad)...min(ny - 1, by1 + pad)
        return ActiveCase(
            sim: sim, uref: u * 1.8, zSlice: nz / 2,
            setupLine: String(format: "%@ · L %.3g m · U %.3g m/s · Re %.0f · %d×%d×%d%@",
                              name, lengthM, speedMS, re, nx, ny, nz,
                              cSmago > 0 ? " · LES" : ""),
            envelope: units.envelope(speed: speedMS, nu: nuSI, cellsPerFeature: D),
            probe: { sim in
                let f = try sim.probeForce(xRange: boxX, yRange: boxY)
                return (2 * f.x / (Double(u) * Double(u) * area), 0)
            },
            strouhalD: nil, strouhalU: nil,
            qoiStatic: { _ in String(format: "A_proj %.0f cells²", area) })
    }

    func reset() {
        do {
            active = try currentBuilder()
            fieldTex = Self.makeFieldTexture(device: gpu.device, sim: active.sim)
            history.removeAll()
            sparkline = []
            qoiLine = ""
            setupLine = active.setupLine
            envelopeLine = Self.envelopeText(active.envelope)
        } catch {
            statsLine = "case build failed: \(error)"
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawOnMain(in: view) }
    }

    private func drawOnMain(in view: MTKView) {
        let sim = active.sim
        guard let cb = gpu.queue.makeCommandBuffer() else { return }

        var encodedSteps = 0
        if let enc = cb.makeComputeCommandEncoder() {
            if running {
                let steps = stepCost.stepsPerFrame
                encodedSteps = steps
                sim.encode(steps: steps, on: enc)
                stepsSinceStats += steps
            }
            // Viz costs a full-domain moments pass — at 7M cells that is the
            // difference between 27 and 30+ fps. Half-rate viz for big cases.
            let vizStride = sim.cells > 4_000_000 ? 2 : 1
            if frameCount % vizStride == 0 {
            sim.encodeMoments(on: enc)
            enc.setComputePipelineState(colorize)
            enc.setBuffer(sim.momentsBuffer, offset: 0, index: 0)
            enc.setBuffer(sim.flagsBuffer, offset: 0, index: 1)
            enc.setBuffer(sim.epsBuffer, offset: 0, index: 2)
            var v = VizParams(nx: UInt32(sim.nx), ny: UInt32(sim.ny), nz: UInt32(sim.nz),
                              zSlice: UInt32(active.zSlice), uref: active.uref,
                              useEps: sim.usesEpsField ? 1 : 0)
            enc.setBytes(&v, length: MemoryLayout<VizParams>.stride, index: 3)
            enc.setTexture(fieldTex, index: 0)
            enc.dispatchThreads(MTLSize(width: sim.nx, height: sim.ny, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
            enc.endEncoding()
        }

        if let rpd = view.currentRenderPassDescriptor,
           let renc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            renc.setRenderPipelineState(quad)
            renc.setFragmentTexture(fieldTex, index: 0)
            renc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            renc.endEncoding()
        }
        if let drawable = view.currentDrawable { cb.present(drawable) }
        let tracker = stepCost
        let nSteps = encodedSteps
        let budget = budgetMs
        cb.addCompletedHandler { cb in
            if let err = cb.error {
                print("command buffer error: \(err.localizedDescription)")
            }
            if nSteps > 0 {
                tracker.record(seconds: cb.gpuEndTime - cb.gpuStartTime,
                               steps: nSteps, budget: budget / 1000.0)
            }
        }
        cb.commit()

        frameCount += 1
        // Live force probe (~10 Hz wall time; frame-count cadence stalled
        // large cases, and 4 Hz aliased the ~2.6 Hz shedding signal).
        let nowP = CACurrentMediaTime()
        if running, nowP - lastProbeTime > 0.1, let probe = active.probe {
            lastProbeTime = nowP
            if let f = try? probe(sim) {
                history.append((Double(sim.stepsDone), f.cd, f.cl))
                if history.count > 240 { history.removeFirst() }
                stepsSinceStats += 2
                sparkline = history.map(\.cd)
            }
        }
        let now = CACurrentMediaTime()
        if now - lastStatsTime > 0.5 {
            let fps = Double(frameCount) / (now - lastStatsTime)
            let sps = Double(stepsSinceStats) / (now - lastStatsTime)
            let mlups = sps * Double(sim.cells) / 1e6
            statsLine = String(format: "%.0f fps · %.0f steps/s · %.0f MLUPS · step %d",
                               fps, sps, mlups, sim.stepsDone)
            var q = ""
            if let last = history.last {
                q = String(format: "C_D %.3f", last.cd)
                if active.strouhalD != nil { q += String(format: " · C_L %+.3f", last.cl) }
                if let st = strouhal() { q += String(format: " · St %.3f", st) }
            }
            if let staticQoI = active.qoiStatic {
                if !q.isEmpty { q += " · " }
                q += staticQoI(sim)
            }
            qoiLine = q
            frameCount = 0; stepsSinceStats = 0; lastStatsTime = now
        }
    }

    private func strouhal() -> Double? {
        guard let d = active.strouhalD, let u = active.strouhalU else { return nil }
        var crossings: [Double] = []
        for k in 1..<history.count where history[k - 1].cl < 0 && history[k].cl >= 0 {
            let a = history[k - 1], b = history[k]
            crossings.append(a.t - a.cl * (b.t - a.t) / (b.cl - a.cl))
        }
        guard crossings.count >= 5 else { return nil }
        let period = (crossings.last! - crossings.first!) / Double(crossings.count - 1)
        return d / (period * u)
    }
}
