import Foundation
import XCTest
@testable import XIsland

@MainActor
final class IntegrationSetupPerformanceTests: XCTestCase {
    /// 只测临时文件扫描与主 Actor 心跳；不包含 AppKit 发现、真实客户端或端到端交互。
    func testTwoHundredExtensionFixturePreservesResultsWhileYieldingMainActor() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("integration-200-extensions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for index in 0..<200 {
            let directory = home.appendingPathComponent(".vscode/extensions/fixture-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest = ["publisher": index == 0 ? "github" : "fixture",
                "name": index == 0 ? "copilot" : "extension-\(index)",
                "description": String(repeating: "isolated-fixture ", count: 1024)]
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("package.json"))
        }
        XCTAssertEqual(IntegrationSetupDiscovery.installedExtensionIDs(home: home).count, 200)
        let environment = IntegrationSetupDiscovery.Environment(homeDirectory: home, path: "",
            applicationURL: { _ in nil }, isExecutable: { _ in false }, extensionIDs: nil, hasConfiguration: { _ in false })
        let expected = IntegrationSetupDiscovery.scan(environment: environment)
        XCTAssertEqual(expected.filter(\.installed).map(\.agent), [.copilot])

        for background in [false, true] {
            var scans: [Double] = []
            var heartbeats: [Double] = []
            for _ in 0..<20 {
                var ready = false
                let heartbeat = Task { @MainActor in
                    ready = true
                    let started = ContinuousClock.now
                    try? await Task.sleep(for: .milliseconds(1))
                    return milliseconds(started.duration(to: .now))
                }
                while !ready { await Task.yield() }
                let started = ContinuousClock.now
                let entries = background
                    ? await IntegrationSetupDiscovery.scanInBackground(environment: environment)
                    : IntegrationSetupDiscovery.scan(environment: environment)
                scans.append(milliseconds(started.duration(to: .now)))
                heartbeats.append(await heartbeat.value)
                XCTAssertEqual(entries.map(\.fingerprint), expected.map(\.fingerprint))
                XCTAssertEqual(entries.filter(\.installed).map(\.agent), [.copilot])
            }
            print("INTEGRATION_200_EXTENSIONS background=\(background) scan_p95_ms=\(scans.sorted()[18]) heartbeat_p95_ms=\(heartbeats.sorted()[18]) heartbeat_max_ms=\(heartbeats.max() ?? 0)")
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
