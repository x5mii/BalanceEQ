// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EqualizerForMac",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "EqualizerMac", targets: ["EqualizerMac"])],
    targets: [
        .target(name: "CEQ", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("CoreAudio")]),
        .target(name: "EQCore", dependencies: ["CEQ"]),
        .executableTarget(name: "EqualizerMac", dependencies: ["EQCore", "CEQ"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreAudio")]),
        .testTarget(name: "CEQTests", dependencies: ["CEQ"]),
        .testTarget(name: "EQCoreTests", dependencies: ["EQCore"]),
    ]
)
