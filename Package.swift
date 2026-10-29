// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BridgeDrop",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "BridgeDropCore", targets: ["BridgeDropCore"]),
        .executable(name: "BridgeDrop", targets: ["BridgeDropMac"]),
        .executable(name: "bridgedrop-check", targets: ["BridgeDropCheck"])
    ],
    targets: [
        .target(name: "BridgeDropCore"),
        .executableTarget(name: "BridgeDropMac", dependencies: ["BridgeDropCore"], path: "App"),
        .executableTarget(name: "BridgeDropCheck", dependencies: ["BridgeDropCore"], path: "Sources/BridgeDropCheck"),
        .testTarget(name: "BridgeDropCoreTests", dependencies: ["BridgeDropCore"])
    ]
)
