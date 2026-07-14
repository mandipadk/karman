// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "strouhal",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "StrouhalCore",
            path: "Sources/StrouhalCore",
            resources: [.copy("Kernels.metal")]
        ),
        .executableTarget(
            name: "strouhal",
            dependencies: ["StrouhalCore"],
            path: "Sources/strouhal"
        ),
        .executableTarget(
            name: "StrouhalApp",
            dependencies: ["StrouhalCore"],
            path: "Sources/StrouhalApp"
        )
    ]
)
