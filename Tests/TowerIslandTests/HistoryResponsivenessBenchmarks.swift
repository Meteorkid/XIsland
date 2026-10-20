import XCTest
import SwiftData
import Darwin
import DIShared
@testable import XIsland

@MainActor
final class HistoryResponsivenessBenchmarks: XCTestCase {
    func testBackgroundHistoryKeepsMainActorAvailable() async throws {
        guard let output = ProcessInfo.processInfo.environment["X_ISLAND_ASYNC_HISTORY_BENCHMARK"] else {
            throw XCTSkip("按需测量后台历史与主线程心跳")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-async-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SessionPersistenceManager(), session = AgentSession(id: "large", agentType: .codex)
        XCTAssertTrue(manager.setupContainer(storeURL: root.appendingPathComponent("history.store")))
        session.events = (0..<50_000).map { ToolEvent(tool: "Read", input: "fixture-\($0)", isComplete: true) }
        XCTAssertTrue(manager.save(session: session))
        var lags: [Double] = [], last = ProcessInfo.processInfo.systemUptime
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                lags.append(max(0, (now - last - 0.001) * 1000)); last = now
            }
        }
        await Task.yield()
        let before = processResources()
        let started = ProcessInfo.processInfo.systemUptime
        let statistics = try await manager.statisticsAsync(timeRange: .all)
        let statisticsMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        XCTAssertEqual(statistics.totalCount, 1)
        let exportStart = ProcessInfo.processInfo.systemUptime
        let count = try await manager.exportHistoryAsync(to: root.appendingPathComponent("export.json"))
        XCTAssertEqual(count, 1)
        let exportMS = (ProcessInfo.processInfo.systemUptime - exportStart) * 1000
        heartbeat.cancel()
        let after = processResources()
        let sorted = lags.sorted()
        XCTAssertFalse(sorted.isEmpty)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let report: [String: Any] = ["scope": "Release actor-backed SQLite statistics/export, 50000 tool events; MainActor 1ms heartbeat, not UI frame rate",
            "statisticsMS": statisticsMS, "exportMS": exportMS, "heartbeatSamples": lags.count,
            "heartbeatP95MS": p95, "heartbeatMaxMS": sorted.last ?? 0,
            "cpuSeconds": after.cpu - before.cpu, "physicalFootprintBytes": after.memory,
            "interruptWakeups": after.wakeups - before.wakeups, "packageIdleWakeups": after.idleWakeups - before.idleWakeups]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}

private func processResources() -> (cpu: Double, memory: UInt64, wakeups: UInt64, idleWakeups: UInt64) {
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    precondition(status == 0)
    var timebase = mach_timebase_info_data_t()
    precondition(mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom > 0)
    // rusage_info 的 CPU 时间是 Mach ticks；Apple Silicon 的时基不一定是 1:1。
    let cpuSeconds = Double(usage.ri_user_time + usage.ri_system_time)
        * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    return (cpuSeconds,
            usage.ri_phys_footprint, usage.ri_interrupt_wkups, usage.ri_pkg_idle_wkups)
}

final class ProcessResourceMetricsTests: XCTestCase {
    func testCPUTimeAgreesWithGetrusageAfterMeasuredWork() {
        func cpuSeconds() -> Double {
            var usage = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let before = processResources().cpu, referenceBefore = cpuSeconds()
        let start = ProcessInfo.processInfo.systemUptime
        var result = 0.0
        while ProcessInfo.processInfo.systemUptime - start < 0.15 {
            for value in 1...10_000 { result += Double(value).squareRoot() }
        }
        let measured = processResources().cpu - before
        let reference = cpuSeconds() - referenceBefore
        XCTAssertGreaterThan(result, 0)
        XCTAssertGreaterThan(reference, 0.02)
        XCTAssertEqual(measured, reference, accuracy: max(0.01, reference * 0.05))
    }
}

@MainActor
final class HistoryLongRunTests: XCTestCase {
    func testContinuousHistoryLoad() async throws {
        guard let output = ProcessInfo.processInfo.environment["X_ISLAND_SOAK_DIRECTORY"] else {
            throw XCTSkip("显式启动连续长稳负载")
        }
        let seconds = Double(ProcessInfo.processInfo.environment["X_ISLAND_SOAK_SECONDS"] ?? "28800") ?? 28800
        guard seconds > 0 else { return XCTFail("长稳时间必须为正数") }
        executionTimeAllowance = seconds + 600
        XCTAssertTrue(AppPreferences.isIsolated)
        let root = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = SessionPersistenceManager(usesBackgroundWrites: true), session = AgentSession(id: "soak", agentType: .codex)
        XCTAssertTrue(manager.setupContainer(storeURL: root.appendingPathComponent("history.store")))
        let start = ProcessInfo.processInfo.systemUptime, startedAt = Date()
        let resourcesBefore = processResources()
        var samples: [[String: Any]] = [], count = 0
        func record(_ completed: Bool) throws {
            let metrics = processResources()
            samples.append(["elapsedSeconds": ProcessInfo.processInfo.systemUptime - start, "events": count,
                            "wallElapsedSeconds": Date().timeIntervalSince(startedAt),
                            "physicalFootprintBytes": metrics.memory, "cpuSeconds": metrics.cpu - resourcesBefore.cpu,
                            "interruptWakeups": metrics.wakeups - resourcesBefore.wakeups])
            let report: [String: Any] = ["startedAt": ISO8601DateFormatter().string(from: startedAt),
                "requestedSeconds": seconds, "completed": completed, "events": count, "samples": samples,
                "scope": "Continuous real-clock synthetic background SQLite checkpoint/read workload; no vendor or production data"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("progress.json"), options: .atomic)
            print("HISTORY_SOAK elapsed=\(Int(ProcessInfo.processInfo.systemUptime - start)) events=\(count) completed=\(completed)")
            fflush(stdout)
        }
        try record(false)
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            try Task.checkCancellation()
            session.appendEvent(ToolEvent(tool: "Read", input: "fixture-\(count)", result: String(repeating: "x", count: 64), isComplete: true))
            guard await manager.saveAsync(session: session) else {
                throw NSError(domain: "XIslandSoak", code: 1, userInfo: [NSLocalizedDescriptionKey: manager.lastSaveError ?? "History save failed"])
            }
            count += 1
            if count % 60 == 0 {
                let statistics = try await manager.statisticsAsync(timeRange: .all)
                guard statistics.totalCount == 1 else { throw NSError(domain: "XIslandSoak", code: 2) }
                try record(false)
            }
            try await Task.sleep(for: .seconds(1))
        }
        let final = try XCTUnwrap(manager.restoreSession(sessionId: session.id))
        XCTAssertEqual(final.events.count, count)
        XCTAssertEqual(Set(final.events.map(\.id)).count, count)
        guard final.events.count == count, Set(final.events.map(\.id)).count == count,
              count >= Int(seconds * 0.8) else { throw NSError(domain: "XIslandSoak", code: 3) }
        guard abs(Date().timeIntervalSince(startedAt) - (ProcessInfo.processInfo.systemUptime - start)) < 60 else {
            throw NSError(domain: "XIslandSoak", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Sleep or a wall-clock discontinuity interrupted the continuous run."])
        }
        let exported = try await manager.exportHistoryAsync(to: root.appendingPathComponent("history.json"))
        XCTAssertEqual(exported, 1)
        try record(true)
    }
}


/// 真实生产消息入口的后台检查点；回调延迟是模拟交互服务时间，不宣称显示器FPS。
@MainActor
final class BackgroundCheckpointPerformanceTests: XCTestCase {
    func testProductionCheckpointKeepsMainActorResponsive() async throws {
        guard let output = ProcessInfo.processInfo.environment["X_ISLAND_CHECKPOINT_BENCHMARK"] else {
            throw XCTSkip("显式启用后台检查点性能基准")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xi-checkpoint-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var rows: [[String: Any]] = []
        for count in [0, 1_000, 10_000, 50_000] {
            let persistence = SessionPersistenceManager(usesBackgroundWrites: true)
            XCTAssertTrue(persistence.setupContainer(storeURL: root.appendingPathComponent("\(count).store")))
            let session = AgentSession(id: "codex-checkpoint-\(count)", agentType: .codex)
            session.events = (0..<count).map { ToolEvent(tool: "Read", input: "fixture-\($0)", isComplete: true) }
            let seed = await persistence.saveAsync(session: session)
            XCTAssertTrue(seed)
            let manager = SessionManager()
            manager.persistenceManager = persistence
            manager.sessions = [session]
            var callbackMS: [Double] = [], checkpointMS: [Double] = []
            var last = ProcessInfo.processInfo.systemUptime
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    callbackMS.append(max(0, (now - last - 0.001) * 1000))
                    manager.searchText = callbackMS.count.isMultiple(of: 2) ? "fixture" : ""
                    last = now
                }
            }
            await Task.yield()
            let before = processResources()
            for iteration in 0..<5 {
                session.appendEvent(ToolEvent(tool: "Read", input: "tail-\(iteration)", isComplete: true))
                var message = DIMessage(type: .sessionStart, sessionId: session.id)
                message.agentType = "codex"
                message.prompt = "checkpoint-\(iteration)"
                let start = ProcessInfo.processInfo.systemUptime
                manager.handleMessage(message)
                let saved = await manager.drainPersistenceOperations()
                XCTAssertTrue(saved)
                checkpointMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            heartbeat.cancel()
            await heartbeat.value
            let after = processResources()
            let sorted = callbackMS.sorted()
            XCTAssertFalse(sorted.isEmpty)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            XCTAssertLessThan(p95, 100, "后台保存仍阻塞主执行器")
            let restored = try XCTUnwrap(persistence.restoreSession(sessionId: session.id))
            XCTAssertEqual(restored.events.count, count + 5)
            XCTAssertEqual(Set(restored.events.map(\.id)).count, count + 5)
            XCTAssertEqual(manager.handledMessageCount, 5)
            rows.append(["eventsBeforeAppend": count, "checkpointMS": checkpointMS,
                "checkpointWallP95MS": checkpointMS.sorted().last!, "mainActorCallbackP95MS": p95,
                "mainActorCallbackMaxMS": sorted.last!, "callbackSamples": sorted.count,
                "cpuSeconds": after.cpu - before.cpu, "physicalFootprintBytes": after.memory,
                "interruptWakeups": after.wakeups - before.wakeups])
        }
        let report: [String: Any] = ["scope": "Release production SessionManager message-to-durable-checkpoint pipeline; 1ms MainActor callbacks update observable search state; not native input latency or display FPS",
            "results": rows, "samplesPerSize": 5]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
