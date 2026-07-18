// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentControlKit",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "AgentDomain", targets: ["AgentDomain"]),
        .library(name: "AgentProtocol", targets: ["AgentProtocol"]),
        .library(name: "AgentPersistence", targets: ["AgentPersistence"]),
        .library(name: "AgentLocalIPC", targets: ["AgentLocalIPC"]),
        .library(name: "AgentHookKit", targets: ["AgentHookKit"]),
        .library(name: "AgentCodexAdapter", targets: ["AgentCodexAdapter"]),
        .library(name: "AgentMacUI", targets: ["AgentMacUI"]),
        .library(name: "BuildSupport", targets: ["BuildSupport"])
    ],
    targets: [
        .target(name: "AgentDomain"),
        .target(name: "AgentProtocol", dependencies: ["AgentDomain"], resources: [.process("JSONSchema")]),
        .target(name: "AgentPersistence", dependencies: ["AgentDomain", "AgentProtocol"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(
            name: "AgentLocalIPC",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentPersistence"],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("ServiceManagement")]
        ),
        .target(name: "AgentHookKit", dependencies: ["AgentDomain", "AgentProtocol", "AgentLocalIPC"]),
        .target(name: "AgentCodexAdapter", dependencies: ["AgentDomain", "AgentProtocol"]),
        .target(name: "AgentMacUI", dependencies: ["AgentDomain", "AgentPersistence", "AgentLocalIPC"]),
        .target(name: "BuildSupport", dependencies: ["AgentDomain"]),
        .testTarget(name: "AgentDomainTests", dependencies: ["AgentDomain"], resources: [.process("Fixtures")]),
        .testTarget(name: "AgentProtocolTests", dependencies: ["AgentDomain", "AgentProtocol"], resources: [.process("Fixtures")]),
        .testTarget(name: "AgentPersistenceTests", dependencies: ["AgentDomain", "AgentProtocol", "AgentPersistence"]),
        .testTarget(name: "AgentLocalIPCTests", dependencies: ["AgentDomain", "AgentProtocol", "AgentPersistence", "AgentLocalIPC"]),
        .testTarget(
            name: "AgentHookKitTests",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentLocalIPC", "AgentHookKit"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "AgentCodexAdapterTests",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentCodexAdapter"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "AgentMacUITests",
            dependencies: ["AgentDomain", "AgentProtocol", "AgentPersistence", "AgentLocalIPC", "AgentMacUI"]
        ),
        .testTarget(name: "BuildSupportTests", dependencies: ["AgentDomain", "BuildSupport"])
    ],
    swiftLanguageModes: [.v6]
)
