// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XIsland",
    platforms: [.macOS(.v14), .iOS(.v17)],
    targets: [
        .target(name: "DIShared"),
        .target(name: "UpdateSecurity"),
        // macOS / iOS / watchOS 共用的伴端协议。刻意不依赖 AppKit/UIKit，
        // 也刻意不依赖业务模型——伴端只接收它需要的字段。
        .target(name: "CompanionShared"),
        .target(name: "MeteorLicenseCore"),
        .executableTarget(name: "XIsland", dependencies: ["DIShared", "CompanionShared", "MeteorLicenseCore", "UpdateSecurity"], path: "Sources/DynamicIsland"),
        .executableTarget(name: "DIBridge", dependencies: ["DIShared"]),
        .executableTarget(
            name: "XIslandUITestDriver",
            dependencies: [],
            path: "Sources/XIslandUITestDriver"
        ),
        .executableTarget(
            name: "XIslandUpdateVerifier",
            dependencies: ["UpdateSecurity"],
            path: "Sources/UpdateVerifier"
        ),
        .testTarget(name: "XIslandTests", dependencies: ["XIsland", "DIBridge", "XIslandUITestDriver", "CompanionShared", "UpdateSecurity"], path: "Tests/TowerIslandTests"),
        .testTarget(name: "MeteorLicenseCoreTests", dependencies: ["MeteorLicenseCore"]),
    ]
)
