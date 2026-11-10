// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EqualizerForMac",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "EqualizerMac", targets: ["EqualizerMac"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "CEQ", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("CoreAudio")]),
        .target(name: "EQCore", dependencies: ["CEQ"], resources: [.process("Resources")]),
        .executableTarget(name: "EqualizerMac", dependencies: ["EQCore", "CEQ", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreAudio"), .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "CEQTests", dependencies: ["CEQ"]),
        .testTarget(name: "EQCoreTests", dependencies: ["EQCore"], resources: [.copy("Fixtures")]),
    ]
)
