// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "karman",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "karman",
            path: "Sources/karman",
            resources: [.copy("Kernels.metal")]
        )
    ]
)
