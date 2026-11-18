// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CapturistKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CapturistCore", targets: ["CapturistCore"]),
        .library(name: "CapturistStore", targets: ["CapturistStore"]),
        .library(name: "CapturistMCP", targets: ["CapturistMCP"]),
        .executable(name: "capturist", targets: ["capturist-cli"]),
    ],
    targets: [
        .target(name: "CapturistCore"),
        .target(
            name: "CapturistStore",
            dependencies: ["CapturistCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "CapturistMCP", dependencies: ["CapturistCore", "CapturistStore"]),
        .executableTarget(
            name: "capturist-cli",
            dependencies: ["CapturistCore", "CapturistStore", "CapturistMCP"]
        ),
        .testTarget(name: "CapturistCoreTests", dependencies: ["CapturistCore"]),
        .testTarget(name: "CapturistStoreTests", dependencies: ["CapturistStore"]),
        .testTarget(name: "CapturistMCPTests", dependencies: ["CapturistMCP", "CapturistStore"]),
    ]
)
