import SwiftUI
import MetalKit
import KarmanCore

// The instrument, M3a skeleton: the Kármán vortex street running live —
// compute and render on one queue, |u| colormap, play/pause, live stats.

@main
struct KarmanApp: App {
    @StateObject private var controller = SimController()
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some Scene {
        WindowGroup("karman — vortex street (working title)") {
            ContentView().environmentObject(controller)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var controller: SimController
    var body: some View {
        VStack(spacing: 0) {
            MetalView()
                .aspectRatio(CGFloat(controller.aspect), contentMode: .fit)
            HStack(spacing: 16) {
                Button(controller.running ? "Pause" : "Run") { controller.running.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Reset") { controller.reset() }
                Slider(value: $controller.stepsPerFrameSetting, in: 10...400, step: 2) {
                    Text("steps/frame")
                }.frame(width: 220)
                Text(controller.stats)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
        }
        .frame(minWidth: 900, minHeight: 300)
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

@MainActor
final class SimController: NSObject, ObservableObject, MTKViewDelegate {
    let gpu: GPU
    private var vsCase: VortexStreetCase
    private var colorize: MTLComputePipelineState
    private var quad: MTLRenderPipelineState
    private var fieldTex: MTLTexture

    @Published var running = true
    @Published var stepsPerFrameSetting: Double = 120
    @Published var stats = "starting…"

    private var frameCount = 0
    private var lastStatsTime = CACurrentMediaTime()
    private var stepsSinceStats = 0
    private var cdHistory: [(t: Double, cd: Double, cl: Double)] = []

    var aspect: Double {
        Double(vsCase.sim.nx) / Double(vsCase.sim.ny)
    }

    override init() {
        gpu = try! GPU()
        vsCase = try! VortexStreetCase(gpu: gpu, D: 40, uinMax: 0.075)
        (colorize, quad) = try! gpu.makeVizPipelines(precision: .fp32, pixelFormat: .bgra8Unorm)
        fieldTex = Self.makeFieldTexture(device: gpu.device, sim: vsCase.sim)
        super.init()
        if let secs = ProcessInfo.processInfo.environment["KARMAN_APP_SECONDS"],
           let t = Double(secs) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(t))
                print("AUTOTEST \(self?.stats ?? "no stats")")
                exit(0)
            }
        }
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
            vsCase = try VortexStreetCase(gpu: gpu, D: 40, uinMax: 0.075)
            fieldTex = Self.makeFieldTexture(device: gpu.device, sim: vsCase.sim)
            cdHistory.removeAll()
        } catch {
            stats = "reset failed: \(error)"
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawOnMain(in: view) }
    }

    private func drawOnMain(in view: MTKView) {
        let sim = vsCase.sim
        guard let cb = gpu.queue.makeCommandBuffer() else { return }

        if let enc = cb.makeComputeCommandEncoder() {
            if running {
                let steps = max(2, Int(stepsPerFrameSetting)) & ~1
                sim.encode(steps: steps, on: enc)
                stepsSinceStats += steps
            }
            sim.encodeMoments(on: enc)
            enc.setComputePipelineState(colorize)
            enc.setBuffer(sim.momentsBuffer, offset: 0, index: 0)
            enc.setBuffer(sim.flagsBuffer, offset: 0, index: 1)
            enc.setBuffer(sim.epsBuffer, offset: 0, index: 2)
            var v = VizParams(nx: UInt32(sim.nx), ny: UInt32(sim.ny), nz: UInt32(sim.nz),
                              zSlice: 0, uref: vsCase.uMax * 1.6,
                              useEps: sim.usesEpsField ? 1 : 0)
            enc.setBytes(&v, length: MemoryLayout<VizParams>.stride, index: 3)
            enc.setTexture(fieldTex, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            enc.dispatchThreads(MTLSize(width: sim.nx, height: sim.ny, depth: 1),
                                threadsPerThreadgroup: tg)
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
        cb.commit()

        frameCount += 1
        // Live force probe (~12 Hz): the shedding is ~2.6 Hz real-time at
        // these settings — 4 Hz sampling aliased the C_L crossings and the
        // St readout was garbage (measured 0.114 vs 0.30).
        if running && frameCount % 5 == 0 {
            if let f = try? sim.probeForce(xRange: vsCase.boxX, yRange: vsCase.boxY) {
                let denom = vsCase.uMean * vsCase.uMean * Double(vsCase.D)
                let cd = 2.0 * f.x / denom
                let cl = 2.0 * f.y / denom
                cdHistory.append((Double(sim.stepsDone), cd, cl))
                if cdHistory.count > 200 { cdHistory.removeFirst() }
                stepsSinceStats += 2
            }
        }
        let now = CACurrentMediaTime()
        if now - lastStatsTime > 0.5 {
            let fps = Double(frameCount) / (now - lastStatsTime)
            let sps = Double(stepsSinceStats) / (now - lastStatsTime)
            let mlups = sps * Double(sim.cells) / 1e6
            var line = String(format: "%.0f fps · %.0f steps/s · %.0f MLUPS · step %d",
                              fps, sps, mlups, sim.stepsDone)
            if let last = cdHistory.last {
                line += String(format: " · C_D %.3f · C_L %+.3f", last.cd, last.cl)
            }
            if let st = strouhal() { line += String(format: " · St %.3f", st) }
            stats = line
            frameCount = 0; stepsSinceStats = 0; lastStatsTime = now
        }
    }

    /// Strouhal estimate from C_L zero upcrossings in the probe history.
    private func strouhal() -> Double? {
        var crossings: [Double] = []
        for k in 1..<cdHistory.count
        where cdHistory[k - 1].cl < 0 && cdHistory[k].cl >= 0 {
            let a = cdHistory[k - 1], b = cdHistory[k]
            let frac = -a.cl / (b.cl - a.cl)
            crossings.append(a.t + frac * (b.t - a.t))
        }
        guard crossings.count >= 5 else { return nil }
        let period = (crossings.last! - crossings.first!) / Double(crossings.count - 1)
        return Double(vsCase.D) / (period * vsCase.uMean)
    }
}
