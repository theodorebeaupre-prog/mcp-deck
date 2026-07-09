// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MCPDeckCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MCPDeckCore", targets: ["MCPDeckCore"])
    ],
    targets: [
        .target(
            name: "MCPDeckCore",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "MCPDeckCoreTests",
            dependencies: ["MCPDeckCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
