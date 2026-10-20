import XCTest
import SwiftData
import Darwin
@testable import XIsland

/// 显式Release基准；数值来自被测操作与进程资源采样，不使用XCTest套件耗时。
@MainActor
final class HistoryPerformanceBenchmarks: XCTestCase {
    func testHistoryOperationBaseline() throws {
        guard let output = ProcessInfo.processInfo.environment["X_ISLAND_HISTORY_BENCHMARK"] else {
            throw XCTSkip("按需运行历史性能基准")
        }
        XCTAssertTrue(AppPreferences.isIsolated)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var results: [[String: Any]] = []
        for count in [0, 1000, 10000, 50000] {
            let manager = SessionPersistenceManager()
            XCTAssertTrue(manager.setupContainer(storeURL: folder.appendingPathComponent("\(count).store")))
            let session = AgentSession(id: "benchmark-\(count)", agentType: .codex)
            session.events = (0..<count).map { index in
                var event = ToolEvent(tool: "Read", input: "fixture-\(index)")
                event.isComplete = true
                event.result = String(repeating: "x", count: 64)
                return event
            }
            let seedStart = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(manager.save(session: session))
            let seedMS = (ProcessInfo.processInfo.systemUptime - seedStart) * 1000
            var appendMS: [Double] = []
            var before = rusage(), after = rusage()
            getrusage(RUSAGE_SELF, &before)
            for _ in 0..<5 {
                session.appendEvent(ToolEvent(tool: "Read", input: "tail"))
                let start = ProcessInfo.processInfo.systemUptime
                XCTAssertTrue(manager.save(session: session))
                appendMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            getrusage(RUSAGE_SELF, &after)
            let cpu = Double(after.ru_utime.tv_sec - before.ru_utime.tv_sec)
                + Double(after.ru_utime.tv_usec - before.ru_utime.tv_usec) / 1_000_000
                + Double(after.ru_stime.tv_sec - before.ru_stime.tv_sec)
                + Double(after.ru_stime.tv_usec - before.ru_stime.tv_usec) / 1_000_000
            let statisticsStart = ProcessInfo.processInfo.systemUptime
            let statistics = try HistoryStatistics.load(from: manager, timeRange: .all)
            let statisticsMS = (ProcessInfo.processInfo.systemUptime - statisticsStart) * 1000
            XCTAssertEqual(statistics.totalCount, 1)
            let exportStart = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(try HistoryArchiveExporter.export(from: manager, to: folder.appendingPathComponent("\(count).json")), 1)
            let exportMS = (ProcessInfo.processInfo.systemUptime - exportStart) * 1000
            results.append(["eventsBeforeAppend": count, "initialSaveMS": seedMS,
                            "appendSaveMS": appendMS, "appendP95MS": appendMS.sorted().last!,
                            "appendCPUSeconds": cpu, "maxRSSBytes": after.ru_maxrss,
                            "voluntaryContextSwitches": after.ru_nvcsw - before.ru_nvcsw,
                            "involuntaryContextSwitches": after.ru_nivcsw - before.ru_nivcsw,
                            "statisticsMS": statisticsMS, "exportMS": exportMS])
        }
        let report: [String: Any] = ["scope": "Release isolated SQLite history operations; synchronous MainActor occupation, not end-to-end UI latency or FPS",
            "date": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "sampleCountPerSize": 5, "results": results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
