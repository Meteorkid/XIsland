// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DIShared"),
        .executableTarget(name: "XIsland", dependencies: ["DIShared"], path: "Sources/DynamicIsland"),
        .executableTarget(name: "DIBridge", dependencies: ["DIShared"]),
        .executableTarget(
            name: "XIslandUITestDriver",
            dependencies: [],
            path: "Sources/XIslandUITestDriver"
        ),
        .testTarget(name: "XIslandTests", dependencies: ["XIsland", "DIBridge", "XIslandUITestDriver"]),
    ]
)
