import XCTest
@testable import XIsland

final class PiPluginConfigurationTests: XCTestCase {
    func testGlobalPathAndExplicitOwnershipMarker() throws {
        XCTAssertEqual(PiPluginConfiguration.pluginURL(homeDirectory: "/Users/test").path,
                       "/Users/test/.pi/agent/extensions/xisland.ts")
        let source = try PiPluginConfiguration.source(bridgePath: "/bin/di-bridge")
        XCTAssertTrue(PiPluginConfiguration.isOwnedSource(source))
        XCTAssertFalse(PiPluginConfiguration.isOwnedSource("// My custom di-bridge plugin\nexport default {}"))
        XCTAssertFalse(PiPluginConfiguration.isOwnedSource("// User plugin\n" + source))
    }

    func testPathValidationAndJSONEncoding() throws {
        for path in ["di-bridge", "~/di-bridge", "/tmp/di\0bridge", ""] {
            XCTAssertThrowsError(try PiPluginConfiguration.source(bridgePath: path))
        }
        let path = "/tmp/O'Brien/\"quoted\"/$(no-exec)\\line\n/di-bridge"
        let source = try PiPluginConfiguration.source(bridgePath: path)
        let line = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.hasPrefix("const BRIDGE = ") })
        let json = String(line.dropFirst("const BRIDGE = ".count).dropLast())
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(json.utf8)), path)
        XCTAssertFalse(source.contains("pi.on(\"tool_call\""))
        XCTAssertFalse(source.contains("pi.on(\"session_switch\""))
        XCTAssertFalse(source.contains("ctx.ui.confirm"))
    }

    func testGeneratedExtensionWithNodeMockRuntime() throws {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("未安装 Node，跳过 Pi 扩展宿主模拟。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-pi-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = directory.appendingPathComponent("di-bridge 'quoted' $(no-exec)")
        let output = directory.appendingPathComponent("events.jsonl")
        try PiPluginConfiguration.source(bridgePath: bridge.path)
            .write(to: directory.appendingPathComponent("plugin.mjs"), atomically: true, encoding: .utf8)
        let fakeBridge = """
        #!\(node)
        const fs = require('node:fs');
        let input = '';
        process.stdin.setEncoding('utf8');
        process.stdin.on('data', chunk => input += chunk);
        process.stdin.on('end', () => fs.appendFileSync(process.env.XISLAND_PI_TEST_OUTPUT,
          JSON.stringify({ args: process.argv.slice(2), payload: JSON.parse(input) }) + '\\n'));
        """
        try fakeBridge.write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        let runner = directory.appendingPathComponent("runner.mjs")
        try Self.mockRuntime.write(to: runner, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [runner.path, bridge.path, output.path]
        var environment = ProcessInfo.processInfo.environment
        environment["XISLAND_PI_TEST_OUTPUT"] = output.path
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private static let mockRuntime = #"""
    import assert from "node:assert/strict";
    import fs from "node:fs";
    import plugin from "./plugin.mjs";
    const [bridge, output] = process.argv.slice(2);
    const callbacks = new Map();
    plugin({ on: (event, callback) => callbacks.set(event, callback) });
    assert.deepEqual([...callbacks.keys()].sort(), [
      "agent_end", "agent_settled", "agent_start", "before_agent_start", "session_shutdown", "session_start",
      "tool_execution_end", "tool_execution_start",
    ]);
    const context = (id, extra = {}) => ({
      sessionManager: { getSessionId: () => id }, cwd: "/workspace/" + id, isIdle: () => true, ...extra,
    });
    const a = context("session-A", { model: { id: "glm-5.3", provider: "zai" } });
    const b = context("session-B");
    const invoke = (name, event, ctx) => callbacks.get(name)(event, ctx);
    await invoke("session_start", { reason: "startup" }, a);
    const prompt = "中文\n'$HOME' $(no-exec)";
    assert.equal(await invoke("before_agent_start", { prompt }, a), undefined);
    assert.equal(await invoke("agent_start", {}, a), undefined);
    await Promise.all([
      invoke("tool_execution_start", { toolCallId: "tool-A", toolName: "bash", args: { command: "echo a" } }, a),
      invoke("tool_execution_start", { toolCallId: "tool-B", toolName: "read", args: { path: "file.txt" } }, b),
    ]);
    await invoke("tool_execution_end", { toolCallId: "tool-A", toolName: "bash", result: { content: "error" }, isError: true }, a);
    await invoke("agent_end", { messages: [{ role: "assistant", content: "x".repeat(20 * 1024 * 1024) }] }, a);
    await invoke("agent_settled", {}, context("session-A", { isIdle: () => false }));
    await invoke("agent_settled", {}, a);
    await invoke("session_shutdown", { reason: "resume", targetSessionFile: "/sessions/B.jsonl" }, a);
    await invoke("session_start", { reason: "resume", previousSessionFile: "/sessions/A.jsonl" }, b);
    const records = () => fs.readFileSync(output, "utf8").trim().split("\n").map(JSON.parse);
    const captured = records();
    assert.equal(captured.length, 10);
    const byEvent = name => captured.filter(item => item.payload.native_event === name);
    assert.equal(byEvent("before_agent_start")[0].payload.prompt, prompt);
    assert.equal(byEvent("before_agent_start")[0].payload.model, "glm-5.3");
    assert.equal(byEvent("session_start")[0].payload.model, "glm-5.3");
    assert.equal(byEvent("session_start")[1].payload.model, undefined);
    assert.deepEqual(byEvent("tool_execution_start").map(item => item.payload.tool_use_id).sort(), ["tool-A", "tool-B"]);
    assert.equal(byEvent("tool_execution_end")[0].payload.native_status, "error");
    assert.equal(byEvent("agent_end")[0].payload.hook_event_name, "AgentEnd");
    assert.equal("messages" in byEvent("agent_end")[0].payload, false);
    assert(JSON.stringify(byEvent("agent_end")[0]).length < 2048);
    assert.equal(byEvent("agent_settled").length, 1);
    assert.equal(byEvent("agent_settled")[0].payload.hook_event_name, "Stop");
    assert.equal(byEvent("session_shutdown")[0].args[3], "session_end");
    assert.equal(byEvent("session_shutdown")[0].payload.session_id, "session-A");
    assert.equal(byEvent("session_start")[1].payload.session_id, "session-B");
    assert(captured.every(item => item.payload.cwd === "/workspace/" + item.payload.session_id));
    assert(captured.filter(item => item.args[3] === "session_end").length === 1);

    const controller = new AbortController(); controller.abort();
    await invoke("tool_execution_start", { toolCallId: "cancelled", toolName: "bash", args: {} }, context("session-A", { signal: controller.signal }));
    assert.equal(records().length, 10);
    await invoke("agent_settled", {}, context("session-A", { signal: controller.signal }));
    assert.equal(records().length, 11);
    await invoke("session_start", {}, context(""));
    assert.equal(records().length, 11);
    fs.unlinkSync(bridge);
    assert.equal(await invoke("agent_start", {}, a), undefined);
    console.log("Pi extension mock runtime passed");
    """#
}
