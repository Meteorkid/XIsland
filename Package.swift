// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DIShared"),
        .target(name: "MeteorLicenseCore"),
        .executableTarget(name: "XIsland", dependencies: ["DIShared", "MeteorLicenseCore"], path: "Sources/DynamicIsland"),
        .executableTarget(name: "DIBridge", dependencies: ["DIShared"]),
        .executableTarget(
            name: "XIslandUITestDriver",
            dependencies: [],
            path: "Sources/XIslandUITestDriver"
        ),
        .testTarget(name: "XIslandTests", dependencies: ["XIsland", "DIBridge", "XIslandUITestDriver"], path: "Tests/TowerIslandTests"),
        .testTarget(name: "MeteorLicenseCoreTests", dependencies: ["MeteorLicenseCore"]),
    ]
)
