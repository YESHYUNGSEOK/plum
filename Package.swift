// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Plum",
    platforms: [.macOS(.v14)],
    targets: [
        // Built from source by scripts/build-vt.sh (libghostty-vt 1.0.1).
        .binaryTarget(name: "GhosttyVt", path: "Vendor/GhosttyVt.xcframework"),
        .target(name: "CPty"),
        .target(name: "PlumKit", dependencies: ["GhosttyVt", "CPty"]),
        .executableTarget(name: "Plum", dependencies: ["PlumKit"]),
        .testTarget(name: "PlumKitTests", dependencies: ["PlumKit"]),
    ]
)
