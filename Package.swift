// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "aisland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "aisland", targets: ["AislandApp"]),
        .executable(name: "island-shim", targets: ["IslandShim"]),
        .executable(name: "islandctl", targets: ["IslandCtl"]),
    ],
    targets: [
        // Shared wire types between the app, the hook shim, and islandctl. Keep tiny:
        // the shim must cold-start fast on every hook invocation.
        .target(name: "IslandProtocol"),
        .executableTarget(name: "IslandShim", dependencies: ["IslandProtocol"]),
        .target(name: "IslandCore", dependencies: ["IslandProtocol"]),
        .target(name: "TerminalJump", dependencies: ["IslandProtocol"]),
        .target(name: "NotchUI", dependencies: ["IslandCore"]),
        .executableTarget(name: "AislandApp", dependencies: ["NotchUI", "IslandCore", "TerminalJump"]),
        .executableTarget(name: "IslandCtl", dependencies: ["IslandProtocol", "IslandCore"]),
        .testTarget(name: "IslandProtocolTests", dependencies: ["IslandProtocol"]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
        .testTarget(name: "NotchUITests", dependencies: ["NotchUI"]),
    ]
)
