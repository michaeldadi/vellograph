// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "VellographCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "DiffCore", targets: ["DiffCore"]),
        .library(name: "SyntaxCore", targets: ["SyntaxCore"]),
        .library(name: "GitCore", targets: ["GitCore"]),
        .library(name: "FolderCore", targets: ["FolderCore"]),
        .library(name: "DocumentCore", targets: ["DocumentCore"]),
        .library(name: "ImageCore", targets: ["ImageCore"]),
        .library(name: "IPCBridge", targets: ["IPCBridge"]),
        .executable(name: "vellograph", targets: ["VellographCLI"]),
        .executable(name: "vellograph-bench", targets: ["VellographBench"]),
    ],
    targets: [
        .target(name: "DiffCore"),
        .target(name: "SyntaxCore"),
        .target(name: "GitCore", dependencies: ["DiffCore"]),
        .target(name: "FolderCore"),
        .target(name: "DocumentCore", dependencies: ["DiffCore"]),
        .target(name: "ImageCore"),
        .target(name: "IPCBridge"),
        .executableTarget(name: "VellographCLI", dependencies: ["IPCBridge", "GitCore"]),
        .executableTarget(name: "VellographBench", dependencies: ["DiffCore", "FolderCore", "ImageCore"]),
        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore"]),
        .testTarget(name: "SyntaxCoreTests", dependencies: ["SyntaxCore"]),
        .testTarget(name: "GitCoreTests", dependencies: ["GitCore"]),
        .testTarget(name: "DocumentCoreTests", dependencies: ["DocumentCore", "DiffCore"]),
        .testTarget(name: "ImageCoreTests", dependencies: ["ImageCore"]),
        .testTarget(name: "FolderCoreTests", dependencies: ["FolderCore"]),
        .testTarget(name: "IPCBridgeTests", dependencies: ["IPCBridge"]),
    ]
)

