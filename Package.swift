// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexRelay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "codex-relay", targets: ["CodexRelay"]),
        .executable(name: "CodexRelayMenu", targets: ["CodexRelayMenu"]),
    ],
    targets: [
        .executableTarget(name: "CodexRelay"),
        .target(
            name: "CodexUsageCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CodexRelayMenu",
            dependencies: ["CodexUsageCore"]
        ),
        .testTarget(name: "CodexRelayTests", dependencies: ["CodexRelay"]),
        .testTarget(
            name: "CodexRelayMenuTests",
            dependencies: ["CodexRelayMenu", "CodexUsageCore"]
        ),
        .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"]),
    ]
)
