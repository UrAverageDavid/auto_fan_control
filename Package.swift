// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AutoFanControl", platforms: [.macOS("26.0")],
    products: [.executable(name: "AutoFanControl", targets: ["AutoFanControl"]),
               .executable(name: "FanHelper", targets: ["FanHelper"]),
               .executable(name: "fanctl", targets: ["fanctl"])],
    targets: [
        .target(name: "FanCore"),
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "FanHardware", dependencies: ["FanCore", "CSMC"]),
        .target(name: "FanIPC", dependencies: ["FanCore"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "AutoFanControl", dependencies: ["FanCore", "FanHardware", "FanIPC"]),
        .executableTarget(name: "FanHelper", dependencies: ["FanCore", "FanHardware", "FanIPC", "CSMC"]),
        .executableTarget(name: "fanctl", dependencies: ["FanCore", "FanHardware"]),
        .testTarget(name: "FanCoreTests", dependencies: ["FanCore"])
    ], swiftLanguageModes: [.v5])
