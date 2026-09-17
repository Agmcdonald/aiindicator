// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BlinkStatus",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BlinkStatusCore", targets: ["BlinkStatusCore"]),
        .executable(name: "blink-statusd", targets: ["blink-statusd"]),
    ],
    targets: [
        .target(name: "BlinkStatusCore"),
        .executableTarget(name: "blink-statusd", dependencies: ["BlinkStatusCore"]),
        .testTarget(name: "BlinkStatusCoreTests", dependencies: ["BlinkStatusCore", "blink-statusd"]),
    ]
)
