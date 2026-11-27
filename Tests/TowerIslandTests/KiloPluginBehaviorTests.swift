import Foundation
import XCTest
@testable import XIsland

/// 用 Node 加载生成的插件，替换桥接为日志脚本，验证 hooks 的真实触发形状与参数。
final class KiloPluginBehaviorTests: XCTestCase {
    private static let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]

    func testHooksSpawnTheKiloBridgeContract() throws {
        guard let node = Self.nodeCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("node is unavailable")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-kilo-behavior-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = directory.appendingPathComponent("events.jsonl")
        let bridge = directory.appendingPathComponent("fake-bridge")
        try """
        #!\(node)
        const fs = require("node:fs");
        let input = "";
        process.stdin.on("data", chunk => { input += chunk; });
        process.stdin.on("end", () => {
          const record = { args: process.argv.slice(2), payload: JSON.parse(input) };
          fs.appendFileSync(process.env.KILO_LOG, JSON.stringify(record) + "\\n");
          process.exit(0);
        });
        """.write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)

        let plugin = directory.appendingPathComponent("xisland.mjs")
        try KiloPluginConfiguration.source(bridgePath: bridge.path).write(to: plugin, atomically: true, encoding: .utf8)

        let harness = directory.appendingPathComponent("harness.mjs")
        try """
        import plugin from "./xisland.mjs";
        const hooks = await plugin.server({ directory: "/tmp/kilo-work" });
        await hooks["chat.message"]({ sessionID: "s1", model: { modelID: "kilo-model" } },
          { parts: [{ type: "text", text: "修复测试" }] });
        await hooks["tool.execute.before"]({ sessionID: "s1", tool: "bash", callID: "c1" }, { args: { command: "ls" } });
        await hooks["tool.execute.after"]({ sessionID: "s1", tool: "bash", callID: "c1" },
          { args: { command: "ls" }, output: "ok" });
        await hooks.event({ event: { type: "session.created", properties: { info: { id: "s1", directory: "/tmp/kilo-work" } } } });
        await hooks.event({ event: { type: "permission.asked", properties: { sessionID: "s1" } } });
        await hooks.event({ event: { type: "session.deleted", properties: { sessionID: "s1" } } });
        hooks.dispose();
        console.log("done");
        """.write(to: harness, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [harness.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["KILO_LOG": log.path]) { $1 }
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(decoding: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self))

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(lines.count, 6)
        let events = lines.compactMap { ($0["args"] as? [String]) }
        XCTAssertEqual(events.map { $0.last }, ["prompt.submitted", "tool.started", "tool.completed",
                                                 "session.created", "status.update", "session.deleted"])
        for args in events {
            XCTAssertTrue(args.contains("--agent"))
            XCTAssertTrue(args.contains("kilo_code"))
            XCTAssertTrue(args.contains("--adapter"))
            XCTAssertTrue(args.contains("kilo_plugin"))
        }
        let payloads = lines.compactMap { ($0["payload"] as? [String: Any]) }
        XCTAssertEqual(payloads.first?["prompt"] as? String, "修复测试")
        XCTAssertEqual(payloads.first?["native_event"] as? String, "prompt.submitted")
        XCTAssertEqual(payloads[1]["tool_name"] as? String, "bash")
        XCTAssertEqual(payloads[2]["tool_response"] as? String, "ok")
        XCTAssertEqual(payloads[4]["state"] as? String, "waitingPermission")
        XCTAssertEqual(payloads[5]["native_event"] as? String, "session.deleted")
        XCTAssertTrue(payloads.allSatisfy { $0["session_id"] as? String == "s1" && $0["agent_type"] == nil })
    }
}
