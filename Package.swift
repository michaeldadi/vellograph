// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MacDiffStudioCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "DiffCore", targets: ["DiffCore"]),
        .library(name: "GitCore", targets: ["GitCore"]),
        .library(name: "FolderCore", targets: ["FolderCore"]),
    ],
    targets: [
        .target(name: "DiffCore"),
        .target(name: "GitCore", dependencies: ["DiffCore"]),
        .target(name: "FolderCore"),
        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore"]),
        .testTarget(name: "GitCoreTests", dependencies: ["GitCore"]),
    ]
)

