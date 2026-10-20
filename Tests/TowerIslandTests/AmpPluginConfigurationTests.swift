import XCTest
import Darwin
@testable import XIsland

final class AmpPluginConfigurationTests: XCTestCase {
    func testOwnershipPreservesExactLegacyTemplateButRejectsUserEdits() {
        XCTAssertTrue(AmpPluginConfiguration.isOwnedSource(Self.legacyPlugin))
        XCTAssertTrue(AmpPluginConfiguration.isOwnedSource(" \n" + Self.legacyPlugin.replacingOccurrences(of: "\n", with: "\r\n") + "\n\t"))
        XCTAssertFalse(AmpPluginConfiguration.isOwnedSource(Self.legacyPlugin + "\nconsole.log(\"user extension\");"))
        XCTAssertFalse(AmpPluginConfiguration.isOwnedSource(Self.legacyPlugin.replacingOccurrences(of: "di-bridge", with: "user-bridge")))
    }

    // 固定于 1845472 之前的完整生成器模板，避免迁移认领依赖当前实现。
    private static let legacyPlugin = #"""
    import { execSync } from "child_process";
    import { homedir } from "os";
    const BRIDGE = homedir() + "/.xisland/bin/di-bridge";
    function send(hookType: string, sessionId: string, data: Record<string, any>) {
      try {
        const stdin = JSON.stringify({ ...data, session_id: sessionId });
        execSync(`${BRIDGE} --agent amp --hook ${hookType} --session ${sessionId}`, {
          input: stdin, timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
        });
      } catch {}
    }
    export default {
      onSessionStart: (ctx: { sessionId: string }) => {
        send("session_start", ctx.sessionId, { terminal: process.env.TERM_PROGRAM || "Terminal" });
      },
      onSessionEnd: (ctx: { sessionId: string }) => {
        send("session_end", ctx.sessionId, {});
      },
      onAgentStart: (ctx: { sessionId: string; task: string }) => {
        send("session_start", ctx.sessionId, { prompt: ctx.task });
      },
      onAgentEnd: (ctx: { sessionId: string }) => {
        send("session_end", ctx.sessionId, {});
      },
      onToolCall: (ctx: { sessionId: string; tool: string; input: any }) => {
        send("PreToolUse", ctx.sessionId, { tool_name: ctx.tool, tool_input: ctx.input });
      },
      onToolResult: (ctx: { sessionId: string; tool: string; result: any }) => {
        send("PostToolUse", ctx.sessionId, { tool_name: ctx.tool, result: ctx.result });
      },
    };
    """#

    func testPluginPathHonorsOnlyAbsoluteXDGConfigHome() {
        XCTAssertEqual(AmpPluginConfiguration.pluginURL(homeDirectory: "/home/test", environment: [:]).path,
                       "/home/test/.config/amp/plugins/xisland.ts")
        XCTAssertEqual(AmpPluginConfiguration.pluginURL(homeDirectory: "/home/test", environment: ["XDG_CONFIG_HOME": "/custom/config"]).path,
                       "/custom/config/amp/plugins/xisland.ts")
        XCTAssertEqual(AmpPluginConfiguration.pluginURL(homeDirectory: "/home/test", environment: ["XDG_CONFIG_HOME": "relative"]).path,
                       "/home/test/.config/amp/plugins/xisland.ts")
    }

    func testOwnershipDoesNotMatchUserPluginMentioningBridge() throws {
        let source = try AmpPluginConfiguration.source(bridgePath: "/bin/di-bridge")
        XCTAssertTrue(AmpPluginConfiguration.isOwnedSource(source))
        XCTAssertFalse(AmpPluginConfiguration.isOwnedSource("export default function(amp) { /* di-bridge */ }"))
        XCTAssertFalse(AmpPluginConfiguration.isOwnedSource("import { execSync } from 'child_process'; // di-bridge"))
        XCTAssertThrowsError(try AmpPluginConfiguration.source(bridgePath: "di-bridge"))
        XCTAssertThrowsError(try AmpPluginConfiguration.source(bridgePath: "/bin/di\0bridge"))
    }

    func testBridgePathIsEncodedAsOneJavaScriptString() throws {
        let path = "/tmp/O'Brien/\"quoted\"/$(no-exec)`no-exec`\\newline\n/di-bridge"
        let source = try AmpPluginConfiguration.source(bridgePath: path)
        let line = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.hasPrefix("const BRIDGE = ") })
        let json = String(line.dropFirst("const BRIDGE = ".count).dropLast())
        let decoded = try JSONDecoder().decode(String.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, path)
        XCTAssertTrue(source.contains("shell: false"))
        XCTAssertFalse(source.contains("execSync"))
    }

    func testSourceUsesDocumentedFunctionAndObservationalEventsOnly() throws {
        let source = try AmpPluginConfiguration.source(bridgePath: "/bin/di-bridge")
        XCTAssertTrue(source.contains("export default function (amp)"))
        for event in ["session.start", "agent.start", "tool.result", "agent.end"] {
            XCTAssertTrue(source.contains("amp.on(\"\(event)\""))
        }
        XCTAssertFalse(source.contains("amp.on(\"tool.call\""))
        XCTAssertFalse(source.contains("amp.on(\"session.end\""))
        XCTAssertFalse(source.contains("action: \"allow\""))
        XCTAssertFalse(source.contains("ctx.ui.confirm"))
        XCTAssertFalse(source.contains("process.cwd()"))
    }

    func testGeneratedPluginWithNodeMockRuntime() throws {
        let node = try nodeExecutable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-amp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var completedSuccessfully = false
        defer { if completedSuccessfully { try? FileManager.default.removeItem(at: directory) } }

        let plugin = directory.appendingPathComponent("plugin.mjs")
        let bridge = directory.appendingPathComponent("di-bridge 'quoted' $(no-exec)")
        let output = directory.appendingPathComponent("events.jsonl")
        let runner = directory.appendingPathComponent("runner.mjs")
        try AmpPluginConfiguration.source(bridgePath: bridge.path).write(to: plugin, atomically: true, encoding: .utf8)
        let fakeBridge = """
        #!\(node.path)
        if (process.argv[2] === '--fixture-ready') process.exit(0);
        const fs = require('node:fs');
        let input = '';
        process.stdin.setEncoding('utf8');
        process.stdin.on('data', chunk => input += chunk);
        process.stdin.on('end', () => {
          const payload = JSON.parse(input);
          const append = () => fs.appendFileSync(process.env.XISLAND_AMP_TEST_OUTPUT,
            JSON.stringify({ args: process.argv.slice(2), payload }) + '\\n');
          if (payload.message_id === 'slow-fixture') setTimeout(append, 3000);
          else append();
        });
        """
        try fakeBridge.write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        // 新建可执行脚本的首次启动可能在进入 JS 前停顿；就绪探测不进入产品事件通道。
        let ready = Process()
        ready.executableURL = bridge
        ready.arguments = ["--fixture-ready"]
        ready.standardInput = FileHandle.nullDevice
        ready.standardOutput = FileHandle.nullDevice
        ready.standardError = FileHandle.nullDevice
        let readyDone = DispatchSemaphore(value: 0)
        ready.terminationHandler = { _ in readyDone.signal() }
        try ready.run()
        guard readyDone.wait(timeout: .now() + 10) == .success else {
            kill(ready.processIdentifier, SIGKILL)
            _ = readyDone.wait(timeout: .now() + 1)
            XCTFail("Amp fixture failed readiness; retained at \(directory.path)")
            return
        }
        guard ready.terminationStatus == 0 else {
            XCTFail("Amp fixture readiness exited \(ready.terminationStatus); retained at \(directory.path)")
            return
        }
        try Self.mockRuntime.write(to: runner, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = node
        process.arguments = [runner.path, bridge.path, output.path]
        var environment = ProcessInfo.processInfo.environment
        environment["XISLAND_AMP_TEST_OUTPUT"] = output.path
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        completedSuccessfully = process.terminationStatus == 0
        XCTAssertEqual(process.terminationStatus, 0, "\(errorText)\nFixture retained at: \(directory.path)")
    }

    private func nodeExecutable() throws -> URL {
        let paths = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw XCTSkip("未安装 Node，跳过插件宿主模拟；无需为此安装依赖。")
    }

    private static let mockRuntime = #"""
    import assert from "node:assert/strict";
    import fs from "node:fs";
    import plugin from "./plugin.mjs";
    const [bridge, output] = process.argv.slice(2);
    const callbacks = new Map();
    const logs = [];
    let dispose;
    const logger = { log: message => logs.push(message) };
    plugin({
      on: (event, callback) => callbacks.set(event, callback),
      onDispose: callback => dispose = callback,
      logger,
      system: { executor: { kind: "local" } },
    });
    assert.deepEqual([...callbacks.keys()].sort(), ["agent.end", "agent.start", "session.start", "tool.result"]);
    const ctx = id => ({ thread: { id }, logger, system: { executor: { kind: "local" } } });
    const threadA = "thread-A ' $(no-exec)";
    const threadB = "thread-B";
    const prompt = "引号\"、换行\n与 $(touch sentinel) 都是普通数据";
    await callbacks.get("session.start")({ thread: { id: threadA } }, ctx(threadA));
    const starts = await Promise.all([
      callbacks.get("agent.start")({ thread: { id: threadA }, id: "message-A", message: prompt }, ctx(threadA)),
      callbacks.get("agent.start")({ thread: { id: threadB }, id: "message-B", message: "B prompt" }, ctx(threadB)),
    ]);
    assert.deepEqual(starts, [undefined, undefined]);
    const result = await callbacks.get("tool.result")({
      thread: { id: threadA }, toolUseID: "tool-A", tool: "Bash",
      input: { command: "printf '%s' '$HOME'" }, status: "error", output: { text: "failed" }, error: "fixture error",
    }, ctx(threadA));
    assert.equal(result, undefined);
    const end = await callbacks.get("agent.end")({
      thread: { id: threadB }, id: "message-B", status: "cancelled", messages: [{ fixture: "x".repeat(20 * 1024 * 1024) }],
    }, ctx(threadB));
    assert.equal(end, undefined);
    const records = fs.readFileSync(output, "utf8").trim().split("\n").map(JSON.parse);
    assert.equal(records.length, 5, JSON.stringify({ received: records.map(item => item.payload.native_event), diagnostics: logs }));
    const record = event => records.find(item => item.payload.native_event === event);
    assert.equal(record("session.start").payload.session_id, threadA);
    assert.equal(record("session.start").payload.hook_event_name, "SessionStart");
    const startA = records.find(item => item.payload.message_id === "message-A");
    assert.equal(startA.payload.prompt, prompt);
    assert.equal(startA.payload.hook_event_name, "UserPromptSubmit");
    assert.deepEqual(startA.args, ["--agent", "amp", "--hook", "UserPromptSubmit", "--session", threadA]);
    assert.equal(record("tool.result").payload.tool_use_id, "tool-A");
    assert.equal(record("tool.result").payload.native_status, "error");
    assert.deepEqual(record("tool.result").payload.tool_response, { text: "failed" });
    assert.equal(record("tool.result").args[3], "toolcomplete");
    assert.equal(record("agent.end").payload.hook_event_name, "Stop");
    assert.equal(record("agent.end").payload.native_status, "cancelled");
    assert.equal(record("agent.end").payload.session_id, threadB);
    assert.equal("messages" in record("agent.end").payload, false);
    assert(JSON.stringify(record("agent.end")).length < 2048);
    assert(records.every(item => !item.args.includes("session_end") && !("cwd" in item.payload)));

    await callbacks.get("session.start")({}, { logger });
    await callbacks.get("session.start")({ thread: { id: threadA } }, ctx(threadB));
    await callbacks.get("session.start")({ thread: { id: threadA } }, {
      ...ctx(threadA), system: { executor: { kind: "orb" } },
    });
    const circular = {}; circular.self = circular;
    await callbacks.get("tool.result")({ thread: { id: threadA }, toolUseID: "circular", tool: "Bash", input: circular }, ctx(threadA));
    assert.equal(fs.readFileSync(output, "utf8").trim().split("\n").length, 5);
    assert(logs.some(message => message.includes("missing-thread-id")));
    assert(logs.some(message => message.includes("thread-id-mismatch")));
    assert(logs.some(message => message.includes("remote-executor")));
    assert(logs.some(message => message.includes("invalid-payload")));
    await callbacks.get("agent.start")({ thread: { id: threadA }, id: "slow-fixture", message: prompt }, ctx(threadA));
    assert(logs.some(message => message.includes("bridge-timeout")));
    assert.equal(fs.readFileSync(output, "utf8").trim().split("\n").length, 5);
    fs.unlinkSync(bridge);
    assert.equal(await callbacks.get("agent.start")({ thread: { id: threadA }, id: "after-removal", message: prompt }, ctx(threadA)), undefined);
    assert(logs.some(message => message.includes("spawn-error")));
    assert(logs.every(message => !message.includes(prompt) && !message.includes(threadA)));
    dispose();
    console.log("Amp plugin mock runtime passed");
    """#
}
