import SwiftUI
import MetalKit
import KarmanCore

// The instrument, M3: case picker (vortex street / cavity / 3D sphere),
// SI-units + envelope readout, live QoIs with a drag sparkline, |u| slice
// visualization. Compute and render share one queue (two-queue at M4).

@main
struct KarmanApp: App {
    @StateObject private var controller = SimController()
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some Scene {
        WindowGroup("karman (working title)") {
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
        }
        .frame(minWidth: 980, minHeight: 380)
        .onChange(of: controller.selectedCase) { controller.reset() }
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
        (colorize, quad) = try! gpu.makeVizPipelines(precision: .fp32, pixelFormat: .bgra8Unorm)
        fieldTex = Self.makeFieldTexture(device: gpu.device, sim: active.sim)
        super.init()
        setupLine = active.setupLine
        envelopeLine = Self.envelopeText(active.envelope)
        if let secs = ProcessInfo.processInfo.environment["KARMAN_APP_SECONDS"],
           let t = Double(secs) {
            if let c = ProcessInfo.processInfo.environment["KARMAN_APP_CASE"],
               let fc = FlowCase.allCases.first(where: { $0.rawValue.lowercased().contains(c) }) {
                selectedCase = fc
                reset()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(t))
                print("AUTOTEST \(self?.statsLine ?? "") | \(self?.qoiLine ?? "")")
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
                envelope: units.envelope(speed: 1.0, nu: 1e-3),
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
                envelope: units.envelope(speed: 0.03, nu: 1.5e-5),
                probe: { sim in
                    let f = try sim.probeForce(xRange: sp.boxX, yRange: sp.boxY)
                    return (sp.dragCoefficient(f), 0)
                },
                strouhalD: nil, strouhalU: nil,
                qoiStatic: { _ in String(format: "C_D ref (Schiller–Naumann) %.3f", sp.cdRef) })
        }
    }

    static func envelopeText(_ e: UnitScales.Envelope) -> String {
        let ok = e.ok ? "✓ in envelope" : "⚠ " + e.warnings.joined(separator: "; ")
        return String(format: "Ma %.3f · τ %.3f · %@", e.mach, e.tau, ok)
    }

    static func makeFieldTexture(device: MTLDevice, sim: Simulation) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                         width: sim.nx, height: sim.ny,
                                                         mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    func reset() {
        do {
            active = try Self.build(selectedCase, gpu: gpu)
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
