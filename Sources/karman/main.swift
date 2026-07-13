import Foundation

// karman CLI — M0 spike driver.
//   karman selftest              parity/indexing proofs
//   karman bench [n]             MLUPS benchmark (default 256)
//   karman cavity [re] [n]       Ghia validation (default 1000, 256)
//   karman determinism           run-twice digest gate
//   karman m0                    all M0 gates + summary

func printResult(_ r: GateResult) {
    print("\(r.passed ? "PASS" : "FAIL")  \(r.name)")
    for line in r.detail.split(separator: "\n") {
        print("      \(line)")
    }
}

func main() throws {
    let args = CommandLine.arguments.dropFirst()
    let cmd = args.first ?? "m0"
    let gpu = try GPU()
    print("device: \(gpu.device.name)")

    var results: [GateResult] = []
    let wall = Date()

    switch cmd {
    case "selftest":
        results = try runSelftest(gpu: gpu)
    case "bench":
        let n = args.dropFirst().first.flatMap { Int($0) } ?? 256
        results = [try runBench(gpu: gpu, n: n)]
    case "cavity":
        let re = args.dropFirst().first.flatMap { Double($0) } ?? 1000
        let n = args.dropFirst(2).first.flatMap { Int($0) } ?? 256
        let maxSteps = re <= 100 ? 100_000 : 1_200_000
        let run = try cavity(gpu: gpu, n: n, re: re, maxSteps: maxSteps)
        print(String(format: "mass drift: %.3e", run.sim.massSum()))
        results = [try ghiaComparison(run: run, re: re)]
    case "determinism":
        results = [try runDeterminism(gpu: gpu)]
    case "m0":
        print("— selftest —")
        results += try runSelftest(gpu: gpu)
        results.forEach(printResult)
        guard results.allSatisfy(\.passed) else { break }

        print("— determinism —")
        let det = try runDeterminism(gpu: gpu)
        printResult(det)
        results.append(det)

        print("— bench 256³ —")
        let bench = try runBench(gpu: gpu, n: 256)
        printResult(bench)
        results.append(bench)

        print("— cavity Re=100 (smoke) —")
        let run100 = try cavity(gpu: gpu, n: 128, re: 100, maxSteps: 100_000)
        let g100 = try ghiaComparison(run: run100, re: 100)
        printResult(g100)
        results.append(g100)

        print("— cavity Re=1000 (gate) —")
        let run1000 = try cavity(gpu: gpu, n: 256, re: 1000, maxSteps: 1_200_000)
        let g1000 = try ghiaComparison(run: run1000, re: 1000)
        printResult(g1000)
        results.append(g1000)
    default:
        print("unknown command \(cmd)")
        exit(2)
    }

    if cmd != "m0" { results.forEach(printResult) }
    let passed = results.filter(\.passed).count
    print(String(format: "\n%d/%d gates passed in %.1fs wall",
                 passed, results.count, -wall.timeIntervalSinceNow))
    exit(passed == results.count ? 0 : 1)
}

do {
    try main()
} catch {
    print("error: \(error)")
    exit(1)
}
