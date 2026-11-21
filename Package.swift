// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DualVibeCoding",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DualVibeCoding", targets: ["DualVibeCodingApp"])
    ],
    targets: [
        .target(name: "CSonic", path: "ThirdParty/AgentRemote/CSonic"),
        .target(
            name: "AgentRemoteBridge",
            dependencies: ["CSonic"],
            path: "ThirdParty/AgentRemote/Sources"
        ),
        .executableTarget(
            name: "DualVibeCodingApp",
            dependencies: ["AgentRemoteBridge"],
            path: "Sources/DualVibeCodingApp",
            resources: [.process("Resources")]
        )
    ]
)
