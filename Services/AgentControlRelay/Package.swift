// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentControlRelay",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentControlRelay", targets: ["AgentControlRelay"]),
        .executable(name: "agentcontrol-relay", targets: ["Run"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.12.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.10.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.8.0"),
        .package(url: "https://github.com/vapor/redis.git", from: "4.11.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0")
    ],
    targets: [
        .target(
            name: "AgentControlRelay",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Redis", package: "redis"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .executableTarget(name: "Run", dependencies: ["AgentControlRelay"]),
        .testTarget(
            name: "AgentControlRelayTests",
            dependencies: [
                "AgentControlRelay",
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "Crypto", package: "swift-crypto")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
