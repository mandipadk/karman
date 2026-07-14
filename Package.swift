// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "karman",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "KarmanCore",
            path: "Sources/KarmanCore",
            resources: [.copy("Kernels.metal")]
        ),
        .executableTarget(
            name: "karman",
            dependencies: ["KarmanCore"],
            path: "Sources/karman"
        ),
        .executableTarget(
            name: "KarmanApp",
            dependencies: ["KarmanCore"],
            path: "Sources/KarmanApp"
        )
    ]
)
