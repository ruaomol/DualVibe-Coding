// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DualVibeCoding",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PS5VibeCoding", targets: ["PS5VibeCodingApp"])
    ],
    targets: [
        .target(name: "CSonic", path: "ThirdParty/AgentRemote/CSonic"),
        .target(
            name: "AgentRemoteBridge",
            dependencies: ["CSonic"],
            path: "ThirdParty/AgentRemote/Sources"
        ),
        .executableTarget(
            name: "PS5VibeCodingApp",
            dependencies: ["AgentRemoteBridge"],
            path: "Sources/PS5VibeCodingApp",
            resources: [.process("Resources")]
        )
    ]
)
