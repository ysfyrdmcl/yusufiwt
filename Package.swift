// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentControl",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "AgentDomain", targets: ["AgentDomain"]),
        .library(name: "AgentProtocol", targets: ["AgentProtocol"]),
        .library(name: "AgentPersistence", targets: ["AgentPersistence"]),
        .library(name: "AgentLocalIPC", targets: ["AgentLocalIPC"]),
        .library(name: "AgentHookKit", targets: ["AgentHookKit"]),
        .library(name: "AgentCodexAdapter", targets: ["AgentCodexAdapter"]),
        .library(name: "AgentMacUI", targets: ["AgentMacUI"]),
        .library(name: "BuildSupport", targets: ["BuildSupport"]),
        .executable(name: "agentcontrol-hook", targets: ["AgentControlHook"]),
        .executable(name: "fake-agent-simulator", targets: ["FakeAgentSimulator"]),
        .executable(name: "protocol-inspector", targets: ["ProtocolInspector"])
    ],
    targets: [
        .target(
            name: "AgentDomain",
            path: "Packages/AgentControlKit/Sources/AgentDomain"
        ),
        .target(
            name: "BuildSupport",
            dependencies: ["AgentDomain"],
            path: "Packages/AgentControlKit/Sources/BuildSupport"
        ),
        .target(
            name: "AgentProtocol",
            dependencies: ["AgentDomain"],
            path: "Packages/AgentControlKit/Sources/AgentProtocol",
            resources: [.process("JSONSchema")]
        ),
        .target(
            name: "AgentPersistence",
            dependencies: ["AgentDomain", "AgentProtocol"],
            path: "Packages/AgentControlKit/Sources/AgentPersistence",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "AgentLocalIPC",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentPersistence"],
            path: "Packages/AgentControlKit/Sources/AgentLocalIPC",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("ServiceManagement")]
        ),
        .target(
            name: "AgentHookKit",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentLocalIPC"],
            path: "Packages/AgentControlKit/Sources/AgentHookKit"
        ),
        .target(
            name: "AgentCodexAdapter",
            dependencies: ["AgentDomain", "AgentProtocol"],
            path: "Packages/AgentControlKit/Sources/AgentCodexAdapter"
        ),
        .target(
            name: "AgentMacUI",
            dependencies: ["AgentDomain", "AgentPersistence", "AgentLocalIPC"],
            path: "Packages/AgentControlKit/Sources/AgentMacUI"
        ),
        .executableTarget(
            name: "AgentControlHook",
            dependencies: ["AgentHookKit", "AgentLocalIPC", "AgentProtocol"],
            path: "Tools/AgentControlHook"
        ),
        .executableTarget(
            name: "FakeAgentSimulator",
            dependencies: ["AgentHookKit", "AgentLocalIPC"],
            path: "Tools/FakeAgentSimulator"
        ),
        .executableTarget(
            name: "ProtocolInspector",
            dependencies: ["AgentHookKit", "AgentLocalIPC"],
            path: "Tools/ProtocolInspector"
        ),
        .testTarget(
            name: "AgentDomainTests",
            dependencies: ["AgentDomain"],
            path: "Packages/AgentControlKit/Tests/AgentDomainTests",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "AgentProtocolTests",
            dependencies: ["AgentDomain", "AgentProtocol"],
            path: "Packages/AgentControlKit/Tests/AgentProtocolTests",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "AgentPersistenceTests",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentPersistence"],
            path: "Packages/AgentControlKit/Tests/AgentPersistenceTests"
        ),
        .testTarget(
            name: "AgentLocalIPCTests",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentPersistence", "AgentLocalIPC"],
            path: "Packages/AgentControlKit/Tests/AgentLocalIPCTests"
        ),
        .testTarget(
            name: "AgentHookKitTests",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentLocalIPC", "AgentHookKit"],
            path: "Packages/AgentControlKit/Tests/AgentHookKitTests",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "AgentCodexAdapterTests",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentCodexAdapter"],
            path: "Packages/AgentControlKit/Tests/AgentCodexAdapterTests",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "AgentMacUITests",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentPersistence", "AgentLocalIPC", "AgentMacUI"],
            path: "Packages/AgentControlKit/Tests/AgentMacUITests"
        ),
        .testTarget(
            name: "BuildSupportTests",
            dependencies: ["AgentDomain", "BuildSupport"],
            path: "Packages/AgentControlKit/Tests/BuildSupportTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
