import XCTest
@testable import XIsland

final class OpenCodePluginConfigurationTests: XCTestCase {
    func testPluginPathUsesOnlyAbsoluteValidXDGConfigHome() {
        XCTAssertEqual(OpenCodePluginConfiguration.pluginURL(homeDirectory: "/Users/test", environment: [:]).path,
                       "/Users/test/.config/opencode/plugins/xisland.js")
        XCTAssertEqual(OpenCodePluginConfiguration.pluginURL(homeDirectory: "/Users/test", environment: ["XDG_CONFIG_HOME": "/custom/config"]).path,
                       "/custom/config/opencode/plugins/xisland.js")
        for invalid in ["relative", "~/config", "/tmp/config\0other"] {
            XCTAssertEqual(OpenCodePluginConfiguration.pluginURL(homeDirectory: "/Users/test", environment: ["XDG_CONFIG_HOME": invalid]).path,
                           "/Users/test/.config/opencode/plugins/xisland.js")
        }
    }

    func testBridgePathIsValidatedAndEncodedAsOneJavaScriptString() throws {
        for invalid in ["", "di-bridge", "~/bin/di-bridge", "/bin/di\0bridge"] {
            XCTAssertThrowsError(try OpenCodePluginConfiguration.source(bridgePath: invalid))
        }
        let path = "/tmp/O'Brien/\"quoted\"/$(touch sentinel)`no-exec`\\line\n/di-bridge"
        let source = try OpenCodePluginConfiguration.source(bridgePath: path)
        let line = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.hasPrefix("const BRIDGE = ") })
        let json = String(line.dropFirst("const BRIDGE = ".count).dropLast())
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(json.utf8)), path)
    }

    func testOwnershipRecognizesOnlyCompleteSourceAndExactLegacyTemplate() throws {
        let source = try OpenCodePluginConfiguration.source(bridgePath: "/bin/di-bridge")
        XCTAssertTrue(OpenCodePluginConfiguration.isOwnedSource(source))
        XCTAssertTrue(OpenCodePluginConfiguration.isOwnedSource(Self.legacyPlugin))
        XCTAssertTrue(OpenCodePluginConfiguration.isOwnedSource(" \n" + Self.legacyPlugin.replacingOccurrences(of: "\n", with: "\r\n") + "\n\t"))
        XCTAssertFalse(OpenCodePluginConfiguration.isOwnedSource(Self.legacyPlugin + "\nconsole.log(\"user extension\");"))
        XCTAssertFalse(OpenCodePluginConfiguration.isOwnedSource(Self.legacyPlugin.replacingOccurrences(of: "di-bridge", with: "my-bridge")))
        XCTAssertFalse(OpenCodePluginConfiguration.isOwnedSource("// User plugin\n" + Self.legacyPlugin))
        XCTAssertFalse(OpenCodePluginConfiguration.isOwnedSource("// User plugin\n" + source))
        XCTAssertFalse(OpenCodePluginConfiguration.isOwnedSource("export default () => {}; // di-bridge"))
    }

    func testObservationalEventsPreserveNativeSessionAndToolIDs() throws { try runMock("events") }
    func testNativeRepliesUseModernAndLegacyInjectedSDKs() throws { try runMock("sdk") }
    func testFailedOrMissingBridgeNeverFabricatesNativeDecisions() throws { try runMock("failures") }
    func testNativeReplyCancelsOnlyItsChildWithoutPosting() throws { try runMock("cancellation") }
    func testRequestsAreFIFOWithinSessionAndIndependentAcrossSessions() throws { try runMock("queues") }
    func testConcurrentEventsKeepSessionOrderAndDoNotReviveDeletedSessions() throws { try runMock("ordering") }
    func testMultipleQuestionsPreserveOrderAndUnsupportedQuestionsStayNative() throws { try runMock("questions") }
    func testUTF8ChunksStayIntactAndInvalidOrOversizedBytesNeverReply() throws { try runMock("utf8") }
    func testDisposeKillsPendingChildrenAndStopsFurtherBridgeWork() throws { try runMock("dispose") }

    private func runMock(_ scenario: String) throws {
        let paths = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        guard let node = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("未安装 Node，跳过 OpenCode 插件宿主模拟；无需安装依赖。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-opencode-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var completedSuccessfully = false
        defer { if completedSuccessfully { try? FileManager.default.removeItem(at: directory) } }
        let bridge = directory.appendingPathComponent("di-bridge 'quoted' $(touch sentinel)`touch sentinel2`")
        let output = directory.appendingPathComponent("events.jsonl")
        try OpenCodePluginConfiguration.source(bridgePath: bridge.path)
            .write(to: directory.appendingPathComponent("plugin.mjs"), atomically: true, encoding: .utf8)
        try ("#!\(node)\n" + Self.fakeBridge).write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        let runner = directory.appendingPathComponent("runner.mjs")
        try Self.mockRuntime.write(to: runner, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [runner.path, scenario, bridge.path, output.path]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["XISLAND_OPENCODE_TEST_OUTPUT"] = output.path
        environment["XISLAND_OPENCODE_TEST_DIRECTORY"] = directory.path
        process.environment = environment
        // 失败时保留现场；诊断写文件，避免大段事件快照塞满 stderr 管道。
        let errorLog = directory.appendingPathComponent("stderr.log")
        try Data().write(to: errorLog)
        let errors = try FileHandle(forWritingTo: errorLog)
        defer { try? errors.close() }
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let diagnostics = try String(contentsOf: errorLog, encoding: .utf8)
        completedSuccessfully = process.terminationStatus == 0
        XCTAssertEqual(process.terminationStatus, 0,
                       "\(scenario); artifacts: \(directory.path)\n" + diagnostics)
    }

    private static let fakeBridge = #"""
    const fs = require("node:fs");
    const path = require("node:path");
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      const payload = JSON.parse(input), id = payload.native_request_id;
      fs.appendFileSync(process.env.XISLAND_OPENCODE_TEST_OUTPUT,
        JSON.stringify({ pid: process.pid, args: process.argv.slice(2), payload }) + "\n");
      if (payload.native_event === "session.created" && payload.session_id === "ordering-delayed") {
        const gate = path.join(process.env.XISLAND_OPENCODE_TEST_DIRECTORY, encodeURIComponent("created:" + payload.session_id) + ".json");
        const timer = setInterval(() => {
          if (!fs.existsSync(gate)) return;
          clearInterval(timer);
          process.stdout.write("{}");
        }, 10);
        return;
      }
      if (!["permission.asked", "question.asked"].includes(payload.native_event)) return;
      if (id.startsWith("utf8-")) {
        if (id === "utf8-invalid" || id === "utf8-incomplete") {
          process.stdout.write(Buffer.concat([Buffer.from('{"answer":"'),
            Buffer.from(id === "utf8-invalid" ? [0xff] : [0xe4, 0xb8]), Buffer.from('"}') ]));
          return;
        }
        if (id === "utf8-oversize") {
          process.stdout.write(JSON.stringify({ answer: "A", padding: "中".repeat(400000) }));
          return;
        }
        const answer = "路径/中文🙂";
        const bytes = Buffer.from(JSON.stringify(payload.allow_multiple_answers ? { answers: [answer] } : { answer }));
        if (id.includes("split")) {
          let offset = 0;
          const timer = setInterval(() => {
            process.stdout.write(bytes.subarray(offset, ++offset));
            if (offset === bytes.length) clearInterval(timer);
          }, 2);
        } else { process.stdout.write(bytes); }
        return;
      }
      if (id === "bad-json") { process.stdout.write("{broken"); return; }
      if (id === "failed-exit") { process.stdout.write('{"decision":"allow"}'); process.exitCode = 7; return; }
      if (id === "empty-result") return;
      if (id === "invalid-decision") { process.stdout.write('{"decision":"approve"}'); return; }
      if (id.startsWith("hold-")) {
        const gate = path.join(process.env.XISLAND_OPENCODE_TEST_DIRECTORY, encodeURIComponent(id) + ".json");
        const timer = setInterval(() => {
          if (!fs.existsSync(gate)) return;
          clearInterval(timer);
          process.stdout.write(fs.readFileSync(gate, "utf8"));
        }, 10);
        return;
      }
      const response = payload.native_event === "permission.asked"
        ? { decision: id === "deny" ? "deny" : "allow" }
        : payload.allow_multiple_answers ? { answers: id.startsWith("multi-utf8-") ? ["A", "中".repeat(2729) + (id.endsWith("over") ? "abcde" : "abcd")] : id === "multi-duplicate" ? ["A", "A"] : id === "multi-unknown" ? ["unknown"] : id === "multi-custom" ? ["A", "custom"] : payload.options }
        : { answer: ["invalid-answer", "free-text"].includes(id) ? "not-an-option" : payload.options.at(-1) };
      process.stdout.write(JSON.stringify(response));
    });
    """#

    private static let mockRuntime = #"""
    import assert from "node:assert/strict";
    import fs from "node:fs";
    import path from "node:path";
    import childProcess from "node:child_process";
    import { syncBuiltinESMExports } from "node:module";

    const [scenario, bridge, output] = process.argv.slice(2);
    const directory = path.dirname(output), instances = [], calls = [], spawns = [];
    globalThis.fetch = () => { throw new Error("Plugin must use the injected SDK transport"); };
    const originalSpawn = childProcess.spawn;
    // 只观察真实 spawn 的生命周期；不替换子进程或它的 stdin/stdout。
    childProcess.spawn = (...args) => {
      const child = originalSpawn(...args), record = { args, child, closed: false, error: null, code: null, signal: null };
      spawns.push(record);
      child.once("error", error => { record.error = error.code; });
      child.once("exit", (code, signal) => { record.code = code; record.signal = signal; });
      child.once("close", () => { record.closed = true; });
      return child;
    };
    syncBuiltinESMExports();
    const { default: plugin } = await import("./plugin.mjs");
    const watchdog = setTimeout(() => {
      for (const record of spawns) if (!record.closed) record.child.kill("SIGKILL");
      process.stderr.write("OpenCode mock runtime timed out: " + scenario + "\n");
      process.exit(1);
    }, 20000);

    const records = () => fs.existsSync(output) ? fs.readFileSync(output, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];
    const matching = (event, id) => records().filter(record => record.payload.native_event === event
      && (id === undefined || record.payload.native_request_id === id));
    const waitFor = async (predicate, label) => {
      const end = Date.now() + 5000;
      while (!predicate()) {
        assert(Date.now() < end, "Timed out waiting for " + label);
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    };
    const dead = pid => {
      try { process.kill(pid, 0); return false; } catch (error) { if (error.code === "ESRCH") return true; throw error; }
    };
    const invoke = (hooks, type, properties) => hooks.event({ event: { type, properties } });
    const permission = (hooks, sessionID, id, extra = {}) => invoke(hooks, "permission.asked", {
      sessionID, id, permission: "external_directory", patterns: ["/outside/*"], metadata: { reason: "fixture" }, ...extra,
    });
    const question = (hooks, sessionID, id, questions = [{ question: "Choose", options: [{ label: "First" }, { label: "Second" }] }]) =>
      invoke(hooks, "question.asked", { sessionID, id, questions });
    const release = (id, response) => fs.writeFileSync(path.join(directory, encodeURIComponent(id) + ".json"), JSON.stringify(response));
    const sdkRecord = (method, parameters, options = parameters) => {
      assert(options.signal instanceof AbortSignal);
      assert.equal(options.throwOnError, true);
      calls.push({ method, parameters, options });
      return Promise.resolve({ data: true });
    };
    const modernClient = () => ({
      permission: { reply: (parameters, options) => sdkRecord("permission", parameters, options) },
      question: { reply: (parameters, options) => sdkRecord("question", parameters, options) },
    });
    const create = async (client = modernClient()) => {
      const hooks = await plugin({ client, directory: "/workspace/default" });
      instances.push(hooks);
      return hooks;
    };
    const requestID = call => call.parameters.requestID ?? call.parameters.path?.requestID ?? call.parameters.path?.permissionID;

    async function events() {
      const hooks = await create();
      const sid = "session-A / 中文 '$()", other = "session-B", callID = "call-ID / ' $()";
      await invoke(hooks, "session.created", { info: { id: sid, directory: "/workspace/one" } });
      await invoke(hooks, "session.created", { info: { id: other, directory: "/workspace/two" } });
      await hooks["chat.message"]({ sessionID: sid, model: { modelID: "fixture-model" } }, {
        parts: [{ type: "text", text: "中文\n' $(touch sentinel3)" }, { type: "text", text: "hidden", synthetic: true }],
      });
      await Promise.all([
        hooks["tool.execute.before"]({ sessionID: sid, callID, tool: "bash" }, { args: { command: "echo '$HOME'" } }),
        hooks["tool.execute.before"]({ sessionID: other, callID: "other-call", tool: "read" }, { args: { path: "other.txt" } }),
      ]);
      await hooks["tool.execute.after"]({ sessionID: sid, callID, tool: "bash", args: { command: "echo '$HOME'" } }, { output: "fixture result" });
      await invoke(hooks, "message.updated", { info: { id: "message-user", role: "user" } });
      await invoke(hooks, "message.part.updated", { part: { type: "text", messageID: "message-user", sessionID: sid, text: "not a reply", time: { end: 1 } } });
      await invoke(hooks, "message.updated", { info: { id: "message-assistant", role: "assistant" } });
      await invoke(hooks, "message.part.updated", { part: { type: "text", messageID: "message-assistant", sessionID: sid, text: "Real reply", time: { end: 1 } } });
      await invoke(hooks, "session.status", { sessionID: sid, status: { type: "idle" } });

      assert.deepEqual(matching("session.created").map(record => record.payload.session_id), [sid, other]);
      assert.equal(matching("prompt.submitted")[0].payload.prompt, "中文\n' $(touch sentinel3)");
      const start = matching("tool.started").find(record => record.payload.session_id === sid);
      assert.equal(start.payload.tool_use_id, callID);
      assert.deepEqual(start.payload.tool_input, { command: "echo '$HOME'" });
      assert.equal(start.payload.cwd, "/workspace/one");
      const finish = matching("tool.completed")[0];
      assert.equal(finish.payload.tool_use_id, callID);
      assert.equal(finish.payload.session_id, sid);
      assert.equal(finish.payload.tool_response, "fixture result");
      assert.equal(matching("tool.started").find(record => record.payload.session_id === other).payload.cwd, "/workspace/two");
      assert.deepEqual(matching("assistant.message").map(record => record.payload.message), ["Real reply"]);
      assert.equal(matching("session.idle")[0].payload.session_id, sid);
      assert.equal(calls.length, 0);
    }

    async function sdk() {
      const hooks = await create();
      await invoke(hooks, "session.created", { info: { id: "modern", directory: "/workspace/modern" } });
      await permission(hooks, "modern", "allow");
      await permission(hooks, "modern", "deny");
      await question(hooks, "modern", "question-modern");
      await waitFor(() => calls.length === 3, "modern SDK replies");
      assert.deepEqual(calls.map(call => call.method), ["permission", "permission", "question"]);
      assert.deepEqual(calls.slice(0, 2).map(call => call.parameters.reply), ["once", "reject"]);
      // Display metadata must not reroute requests away from the injected instance.
      assert(calls.every(call => call.parameters.directory === "/workspace/default"));
      assert.deepEqual(calls[2].parameters.answers, [["Second"]]);
      const asked = matching("permission.asked", "allow")[0];
      assert.equal(asked.payload.native_request_kind, "permission");
      assert.equal(asked.payload.session_id, "modern");
      assert.deepEqual(asked.payload.patterns, ["/outside/*"]);

      const legacy = await create({
        postSessionIdPermissionsPermissionId: parameters => sdkRecord("v1-permission", parameters),
        _client: { post: parameters => sdkRecord("transport", parameters) },
      });
      const sid = "session /? 中文", id = "request /? # 中文";
      await invoke(legacy, "session.created", { info: { id: sid, directory: "/workspace/legacy space" } });
      await permission(legacy, sid, id);
      await question(legacy, sid, "question /? # 中文");
      await waitFor(() => calls.length === 5, "injected v1 SDK replies");
      assert.equal(calls[3].method, "v1-permission");
      assert.deepEqual(calls[3].parameters.path, { id: sid, permissionID: id });
      assert.deepEqual(calls[3].parameters.body, { response: "once" });
      assert.deepEqual(calls[3].parameters.query, { directory: "/workspace/default" });
      assert.equal(calls[4].parameters.url, "/question/{requestID}/reply");
      assert.deepEqual(calls[4].parameters.path, { requestID: "question /? # 中文" });
      assert.deepEqual(calls[4].parameters.query, { directory: "/workspace/default" });
      assert.deepEqual(calls[4].parameters.body, { answers: [["Second"]] });
      assert.equal(calls[4].parameters.headers["Content-Type"], "application/json");
    }

    async function failures() {
      const hooks = await create();
      for (const id of ["bad-json", "failed-exit", "empty-result", "invalid-decision"]) {
        await permission(hooks, "failed", id);
        await waitFor(() => matching("interaction.unavailable", id).length === 1, id + " unavailable");
        assert.equal(calls.length, 0, "Failed bridge must not approve or reject " + id);
        assert.equal(matching("interaction.resolved", id).length, 1);
      }
      const beforeMissing = spawns.length;
      fs.renameSync(bridge, bridge + ".saved");
      try {
        await permission(hooks, "missing", "missing-bridge");
        await waitFor(() => spawns.slice(beforeMissing).some(record => record.error === "ENOENT" && record.closed),
          "missing bridge spawn failure");
        assert.equal(calls.length, 0);
      } finally { fs.renameSync(bridge + ".saved", bridge); }
      await permission(hooks, "missing", "working-again");
      await waitFor(() => calls.length === 1, "recovery after missing bridge");
      assert.equal(requestID(calls[0]), "working-again");
    }

    async function cancellation() {
      const hooks = await create();
      await permission(hooks, "cancel-permission", "hold-permission");
      await question(hooks, "cancel-question", "hold-question");
      await waitFor(() => matching("permission.asked", "hold-permission").length && matching("question.asked", "hold-question").length,
        "both live interactive children");
      const permissionPID = matching("permission.asked", "hold-permission")[0].pid;
      const questionPID = matching("question.asked", "hold-question")[0].pid;
      await invoke(hooks, "permission.replied", { sessionID: "cancel-permission", requestID: "hold-permission" });
      await waitFor(() => dead(permissionPID), "permission child cancellation");
      assert.equal(dead(questionPID), false, "Different session/kind must remain pending");
      await invoke(hooks, "question.replied", { sessionID: "cancel-question", requestID: "hold-question" });
      await waitFor(() => dead(questionPID), "question child cancellation");
      assert.equal(calls.length, 0);
      assert.equal(matching("interaction.resolved", "hold-permission")[0].payload.native_request_kind, "permission");
      assert.equal(matching("interaction.resolved", "hold-question")[0].payload.native_request_kind, "question");
      await permission(hooks, "same-id", "hold-shared");
      await question(hooks, "same-id", "hold-shared");
      await waitFor(() => matching("permission.asked", "hold-shared").length === 1, "same-ID permission starts first");
      const sharedPID = matching("permission.asked", "hold-shared")[0].pid;
      await invoke(hooks, "question.replied", { sessionID: "same-id", requestID: "hold-shared" });
      assert.equal(dead(sharedPID), false, "Same ID in another kind must not cancel the active permission");
      assert.equal(matching("question.asked", "hold-shared").length, 0);
      await invoke(hooks, "permission.replied", { sessionID: "same-id", permissionID: "hold-shared" });
      await waitFor(() => dead(sharedPID), "legacy permissionID resolution cancels matching child");
      assert.equal(calls.length, 0);
      await permission(hooks, "same-id", "after-shared");
      await waitFor(() => calls.length === 1, "lane skips its externally resolved queued question");
      assert.equal(requestID(calls[0]), "after-shared");
      assert.equal(matching("question.asked", "hold-shared").length, 0);
      await permission(hooks, "cancel-permission", "hold-permission");
      await question(hooks, "cancel-question", "hold-question");
      await permission(hooks, "cancel-permission", "after-cancellation");
      await waitFor(() => calls.length === 2, "lane after external cancellation");
      assert.equal(requestID(calls[1]), "after-cancellation");
      assert.equal(matching("permission.asked", "hold-permission").length, 1);
      assert.equal(matching("question.asked", "hold-question").length, 1);
    }

    async function queues() {
      const hooks = await create();
      await permission(hooks, "one", "hold-first");
      await permission(hooks, "one", "second");
      await permission(hooks, "one", "second");
      await question(hooks, "one", "third");
      await permission(hooks, "two", "independent");
      await waitFor(() => matching("permission.asked", "hold-first").length && calls.some(call => requestID(call) === "independent"),
        "independent session while first lane is blocked");
      assert.equal(matching("permission.asked", "second").length, 0);
      assert.equal(matching("question.asked", "third").length, 0);
      assert.deepEqual(calls.map(requestID), ["independent"]);
      release("hold-first", { decision: "allow" });
      await waitFor(() => calls.length === 4, "FIFO lane completion");
      assert.deepEqual(calls.map(requestID), ["independent", "hold-first", "second", "third"]);
      assert.equal(matching("permission.asked", "second").length, 1);
      assert.deepEqual(records().filter(record => record.payload.session_id === "one"
        && ["permission.asked", "question.asked"].includes(record.payload.native_event)).map(record => record.payload.native_request_id),
        ["hold-first", "second", "third"]);
    }

    async function questions() {
      const hooks = await create();
      await question(hooks, "questions", "multi-question", [
        { question: "First question", options: [{ label: "A" }, { label: "B" }] },
        { question: "Second question", options: [{ label: "C" }, { label: "D" }] },
      ]);
      await waitFor(() => calls.length === 1, "multi-question reply");
      assert.deepEqual(calls[0].parameters.answers, [["B"], ["D"]]);
      const prompts = matching("question.asked", "multi-question");
      assert.deepEqual(prompts.map(record => record.payload.question), ["[1/2] First question", "[2/2] Second question"]);
      assert(prompts.every(record => record.payload.native_request_kind === "question"));
      assert.deepEqual(prompts.map(record => record.payload.options), [["A", "B"], ["C", "D"]]);

      await question(hooks, "questions", "multi-select", [{ question: "Pick several", multiple: true, options: [{ label: "A" }, { label: "B" }] }]);
      await question(hooks, "questions", "no-options", [{ question: "Free text", custom: false, options: [] }]);
      await question(hooks, "questions", "invalid-answer", [{ question: "Pick", custom: false, options: [{ label: "A" }] }]);
      await permission(hooks, "questions", "after-unsupported");
      await waitFor(() => calls.length === 3, "lane after unsupported question inputs");
      assert.equal(requestID(calls[2]), "after-unsupported");
      assert.deepEqual(calls[1].parameters.answers, [["A", "B"]]);
      assert.equal(matching("question.asked", "multi-select")[0].payload.allow_multiple_answers, true);
      assert.equal(matching("question.asked", "no-options").length, 0);
      for (const id of ["no-options", "invalid-answer"]) {
        assert.equal(matching("interaction.unavailable", id).length, 1);
        assert.equal(calls.some(call => requestID(call) === id), false);
      }
      await question(hooks, "questions", "free-text", [{ question: "Enter path", options: [] }]);
      await waitFor(() => calls.length === 4, "free text reply");
      assert.deepEqual(calls[3].parameters.answers, [["not-an-option"]]);
      assert.equal(matching("question.asked", "free-text")[0].payload.allow_custom_answer, true);
      assert.equal(matching("question.asked", "invalid-answer")[0].payload.allow_custom_answer, false);
      for (const id of ["multi-duplicate", "multi-unknown", "multi-custom"]) {
        await question(hooks, "questions", id, [{ question: "Pick", multiple: true, custom: id === "multi-custom", options: [{ label: "A" }, { label: "B" }] }]);
      }
      await waitFor(() => calls.length === 5, "multi custom answer");
      assert.deepEqual(calls[4].parameters.answers, [["A", "custom"]]);
      for (const id of ["multi-utf8-limit", "multi-utf8-over"]) {
        await question(hooks, "questions", id, [{ question: "UTF8 limit", multiple: true, options: [{ label: "A" }] }]);
      }
      await waitFor(() => calls.length === 6 && matching("interaction.unavailable", "multi-utf8-over").length === 1, "UTF8 boundaries");
      assert.equal(calls[5].parameters.answers[0].reduce((n, value) => n + Buffer.byteLength(value, "utf8"), 0), 8192);
      assert.equal(calls.some(call => requestID(call) === "multi-utf8-over"), false);
      for (const id of ["multi-duplicate", "multi-unknown"]) {
        assert.equal(matching("interaction.unavailable", id).length, 1);
        assert.equal(calls.some(call => requestID(call) === id), false);
      }
    }

    async function utf8() {
      const hooks = await create();
      const ids = ["utf8-whole-single", "utf8-split-single", "utf8-whole-multiple", "utf8-split-multiple"];
      for (const id of ids) {
        await question(hooks, "utf8", id, [{ question: "输入路径", multiple: id.endsWith("multiple"), options: [] }]);
      }
      await waitFor(() => calls.length === 4, "UTF8 answers");
      assert.deepEqual(calls.map(requestID), ids);
      assert(calls.every(call => JSON.stringify(call.parameters.answers) === JSON.stringify([["路径/中文🙂"]])));
      const rejected = ["utf8-invalid", "utf8-incomplete", "utf8-oversize"];
      for (const id of rejected) {
        await question(hooks, "utf8", id, [{ question: "Do not corrupt text", options: [{ label: "A" }] }]);
      }
      await permission(hooks, "utf8", "after-utf8");
      await waitFor(() => calls.length === 5, "lane after rejected UTF8");
      assert.equal(requestID(calls[4]), "after-utf8");
      for (const id of rejected) {
        assert.equal(matching("interaction.unavailable", id).length, 1);
        assert(!calls.some(call => requestID(call) === id));
      }
    }

    async function ordering() {
      // 新建的 Node 夹具先完成一次真实启动，避免文件首次执行开销占用产品的 1500 ms 观察时限。
      // 正式事件仍由插件启动真实子进程；预热不进入插件队列，也不写入正式事件日志。
      const readinessOutput = path.join(directory, "readiness-events.jsonl"), readinessStart = performance.now();
      const readiness = childProcess.spawn(bridge, ["--agent", "opencode", "--adapter", "opencode_plugin", "--hook", "fixture.ready"], {
        shell: false, stdio: ["pipe", "pipe", "ignore"],
        env: { ...process.env, XISLAND_OPENCODE_TEST_OUTPUT: readinessOutput },
      });
      const readinessRecord = spawns.at(-1);
      readiness.stdin.once("error", error => { readinessRecord.error ??= error.code ?? error.message; });
      readiness.stdin.end(JSON.stringify({ native_event: "fixture.ready", session_id: "fixture-readiness" }));
      await waitFor(() => readinessRecord.closed, "fixture bridge readiness");
      assert.equal(readinessRecord.error, null);
      assert.equal(readinessRecord.code, 0);
      assert.equal(readinessRecord.signal, null);
      assert.equal(JSON.parse(fs.readFileSync(readinessOutput, "utf8")).payload.native_event, "fixture.ready");
      fs.writeFileSync(path.join(directory, "readiness.json"), JSON.stringify({
        nodeVersion: process.version, pid: readiness.pid, milliseconds: performance.now() - readinessStart,
      }));

      const hooks = await create(), sid = "ordering-delayed";
      // 宿主并发派发 event；不等待 session.created 返回便提交同会话审批。
      const creation = invoke(hooks, "session.created", { info: { id: sid, directory: "/workspace/ordering" } });
      await permission(hooks, sid, "hold-after-created");
      await permission(hooks, "ordering-other", "ordering-independent");
      await waitFor(() => matching("session.created").some(record => record.payload.session_id === sid)
        && calls.some(call => requestID(call) === "ordering-independent"), "another session progresses while created is blocked");
      const creationPID = matching("session.created").find(record => record.payload.session_id === sid).pid;
      assert.equal(dead(creationPID), false, "Creation must still be held by its gate");
      assert.equal(spawns.filter(record => record.args[1].at(-1) === "permission.asked").length, 1,
        "Only the independent session may start an interactive child before creation completes");
      assert.equal(matching("permission.asked", "hold-after-created").length, 0,
        "Interactive child must wait for earlier observations in its session");
      release("created:" + sid, {});
      await creation;
      await waitFor(() => matching("permission.asked", "hold-after-created").length === 1, "approval starts after session creation completes");
      const approvalPID = matching("permission.asked", "hold-after-created")[0].pid;
      assert.equal(dead(creationPID), true);

      // resolved 必须能取消正在等待答案的子进程，不能排在该交互后面。
      const resolution = invoke(hooks, "permission.replied", { sessionID: sid, requestID: "hold-after-created" });
      await waitFor(() => dead(approvalPID) && matching("interaction.resolved", "hold-after-created").length === 1,
        "native resolution bypasses the interactive wait");
      await resolution;
      assert.deepEqual(calls.map(requestID), ["ordering-independent"]);

      await invoke(hooks, "session.deleted", { info: { id: sid } });
      const deletedRecords = records().filter(record => record.payload.session_id === sid).length;
      await Promise.all([
        hooks["tool.execute.before"]({ sessionID: sid, callID: "late-tool", tool: "bash" }, { args: {} }),
        hooks["tool.execute.after"]({ sessionID: sid, callID: "late-tool", tool: "bash", args: {} }, { output: "late result" }),
        permission(hooks, sid, "late-permission"),
        question(hooks, sid, "late-question"),
        invoke(hooks, "session.updated", { info: { id: sid, directory: "/workspace/late" } }),
        invoke(hooks, "session.status", { sessionID: sid, status: { type: "busy" } }),
      ]);
      await permission(hooks, "ordering-other", "after-deletion-barrier");
      await waitFor(() => calls.some(call => requestID(call) === "after-deletion-barrier"), "other session still progresses after deletion");
      assert.equal(records().filter(record => record.payload.session_id === sid).length, deletedRecords,
        "Late observations or requests must not recreate a deleted session");

      await invoke(hooks, "session.created", { info: { id: sid, directory: "/workspace/recreated" } });
      await permission(hooks, sid, "after-created-revival");
      await waitFor(() => calls.some(call => requestID(call) === "after-created-revival"), "explicit session creation reopens the session");
      await invoke(hooks, "session.deleted", { info: { id: sid } });
      await hooks["chat.message"]({ sessionID: sid }, { parts: [{ type: "text", text: "New user turn" }] });
      await permission(hooks, sid, "after-chat-revival");
      await waitFor(() => calls.some(call => requestID(call) === "after-chat-revival"), "new user turn reopens the session");
      assert.deepEqual(calls.map(requestID), ["ordering-independent", "after-deletion-barrier", "after-created-revival", "after-chat-revival"]);
      assert.equal(matching("permission.asked", "late-permission").length, 0);
      assert.equal(matching("question.asked", "late-question").length, 0);
      assert.equal(records().some(record => record.payload.tool_use_id === "late-tool"), false);
    }

    async function dispose() {
      const hooks = await create();
      await permission(hooks, "first", "hold-dispose-permission");
      await question(hooks, "second", "hold-dispose-question");
      await permission(hooks, "first", "must-not-start");
      await waitFor(() => matching("permission.asked", "hold-dispose-permission").length && matching("question.asked", "hold-dispose-question").length,
        "children before disposal");
      const pids = records().map(record => record.pid);
      await hooks.dispose();
      await waitFor(() => pids.every(dead), "all disposed children exit");
      assert.equal(matching("interaction.resolved", "hold-dispose-permission").length, 1);
      assert.equal(matching("interaction.resolved", "hold-dispose-question").length, 1);
      assert.equal(matching("interaction.resolved", "must-not-start").length, 0);
      const previousSpawns = spawns.length;
      await permission(hooks, "first", "after-dispose");
      await hooks["chat.message"]({ sessionID: "first" }, { parts: [{ type: "text", text: "ignored" }] });
      await hooks["tool.execute.before"]({ sessionID: "first", tool: "bash", callID: "ignored" }, { args: {} });
      await hooks.dispose();
      assert.equal(spawns.length, previousSpawns);
      assert.equal(matching("permission.asked", "must-not-start").length, 0);
      assert.equal(calls.length, 0);
    }

    try {
      await ({ events, sdk, failures, cancellation, queues, ordering, questions, utf8, dispose })[scenario]();
      for (const record of spawns) {
        assert.equal(record.args[0], bridge);
        assert.equal(record.args[2].shell, false);
        assert.deepEqual(record.args[1].slice(0, 5), ["--agent", "opencode", "--adapter", "opencode_plugin", "--hook"]);
      }
      for (const sentinel of ["sentinel", "sentinel2", "sentinel3"]) assert.equal(fs.existsSync(path.join(directory, sentinel)), false);
    } catch (error) {
      let observedEvents;
      try { observedEvents = records(); } catch (readError) { observedEvents = { readError: String(readError) }; }
      // 清理前记录首个失败，区分子进程限时退出、漏事件和跨会话回复停滞。
      process.stderr.write("OpenCode mock failure: " + JSON.stringify({
        scenario, nodeVersion: process.version, nodeExecutable: process.execPath, failure: error.stack ?? String(error),
        children: spawns.map(({ args, child, closed, error, code, signal }) => ({
          hook: args[1].at(-1), pid: child.pid ?? null, closed, error, code, signal,
        })),
        events: observedEvents, replyIDs: calls.map(requestID),
      }) + "\n");
      throw error;
    } finally {
      for (const hooks of instances) await hooks.dispose();
      for (const record of spawns) if (!record.closed) record.child.kill("SIGKILL");
      await waitFor(() => spawns.every(record => record.closed), "all bridge children closed");
      clearTimeout(watchdog);
    }
    """#

    // 固定的旧生成器源码；内部空白参与所有权 SHA，不能格式化。
    private static let legacyPlugin = #"""
    import { spawn, execSync } from "child_process";
    import { homedir } from "os";
    const BRIDGE = homedir() + "/.xisland/bin/di-bridge";
    function sendViaBridge(hookType, sessionId, data) {
      try {
        const stdin = JSON.stringify({ ...data, session_id: sessionId });
        execSync(`${BRIDGE} --agent opencode --hook ${hookType} --session ${sessionId}`, {
          input: stdin, timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
        });
      } catch {}
    }
    function sendInteractive(hookType, sessionId, data) {
      return new Promise((resolve) => {
        try {
          const child = spawn(BRIDGE, ["--agent","opencode","--hook",hookType,"--session",sessionId],
            { stdio: ["pipe","pipe","pipe"] });
          child.stdin.write(JSON.stringify(data)); child.stdin.end();
          let stdout = "";
          child.stdout.on("data", (d) => { stdout += d.toString(); });
          child.on("close", (code) => resolve({ exitCode: code, output: stdout.trim() }));
          child.on("error", () => resolve(null));
          setTimeout(() => { child.kill(); resolve(null); }, 300000);
        } catch { resolve(null); }
      });
    }
    // One active question bridge per session; kill the old one when a newer event
    // arrives so only the latest rid ever gets replied to.
    const activeQ = new Map();
    // After the user answers, cache the answer briefly so that follow-up duplicate
    // events (same question, same options) from OpenCode get auto-replied without
    // showing the question panel again.
    const answeredQ = new Map(); // sid -> { answer, opts, ts }
    const answeringQ = new Set(); // sids with an active askSequentially loop
    export default async ({ client, serverUrl }) => {
      const serverPort = serverUrl ? parseInt(serverUrl.port) || 4096 : 4096;
      const internalFetch = client?._client?.getConfig?.()?.fetch || null;
      const msgRoles = new Map(), sessions = new Map(), sessionCwd = new Map();
      function getSession(sid) {
        if (!sessions.has(sid)) sessions.set(sid, { lastUserText: "", lastAssistantText: "" });
        return sessions.get(sid);
      }
      function handleEvent(ev) {
        const t = ev.type, p = ev.properties || {};
        if (t === "session.created" && p.info) {
          sessionCwd.set(p.info.id, p.info.directory || "");
          sendViaBridge("session_start", `opencode-${p.info.id}`, { cwd: p.info.directory || "", terminal: process.env.TERM_PROGRAM || "Terminal" });
          return;
        }
        if (t === "session.deleted" && p.info) { sessions.delete(p.info.id); sessionCwd.delete(p.info.id); sendViaBridge("session_end", `opencode-${p.info.id}`, {}); return; }
        if (t === "session.updated" && p.info) {
          if (p.info.directory) sessionCwd.set(p.info.id, p.info.directory);
          if (p.info.time?.archived) { sessions.delete(p.info.id); sessionCwd.delete(p.info.id); sendViaBridge("session_end", `opencode-${p.info.id}`, {}); }
          return;
        }
        if (t === "permission.asked" && p.id && p.sessionID) {
          const rid = p.id, sid = `opencode-${p.sessionID}`;
          const permRaw = (p.permission||"unknown");
          const perm = permRaw.toLowerCase();
          const tn = permRaw.charAt(0).toUpperCase()+permRaw.slice(1);
          const pts = p.patterns||[];
          let desc = tn;
          if (p.permission==="bash"&&pts.length) desc = "Run: "+pts.join(" && ");
          else if ((p.permission==="edit"||p.permission==="write")&&pts.length) desc = tn+": "+pts[0];
          else if (pts.length) desc = tn+": "+pts.join(", ");
          const questionLike = perm.includes("ask") || perm.includes("question") || perm.includes("input");
          if (questionLike) {
            const opts = pts.filter(Boolean).map(String);
            if (internalFetch) {
              sendInteractive("question", sid, { question: desc || "Question", options: opts });
            } else {
              sendViaBridge("question", sid, { question: desc || "Question", options: opts });
            }
            return;
          }
          if ((perm === "unknown" || perm === "") && !pts.length) {
            return;
          }
          if (internalFetch) {
            sendInteractive("PermissionRequest", sid, { tool_name:tn, description:desc, file_path:pts[0]||"" })
              .then(async (r)=>{ if(!r)return; try{ await internalFetch(new Request(`http://localhost:${serverPort}/permission/${rid}/reply`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({reply:r.exitCode===0?"once":"reject"})}));}catch{} });
          } else { sendViaBridge("PermissionRequest", sid, { tool_name:tn, description:desc, file_path:pts[0]||"" }); }
          return;
        }
        if (t === "permission.replied" && p.sessionID) { sendViaBridge("PostToolUse",`opencode-${p.sessionID}`,{tool_name:"Permission"}); return; }
        if (t === "question.asked" && p.id && p.sessionID) {
          const rid = p.id, sid = `opencode-${p.sessionID}`;
          const qs = p.questions||[];
          const allQt = qs.map(q=>q.question||q.header||"").filter(Boolean).join("\n");
          if (!allQt.trim() || (allQt.trim() === "Question" && !qs.some(q=>(q.options||[]).length))) return;
          if (!internalFetch) {
            const opts = qs.flatMap(q=>(q.options||[]).map(o=>o.label||o.description||"")).filter(Boolean);
            sendViaBridge("question", sid, { question:allQt, options:opts });
            return;
          }
          // If we're already walking through a multi-question batch for this
          // session, ignore the re-fired event from OpenCode.
          if (answeringQ.has(sid)) {
            return;
          }
          // Dedup: if we just answered the exact same batch, auto-reply.
          const prev = answeredQ.get(sid);
          const allOpts = qs.flatMap(q=>(q.options||[]).map(o=>o.label||o.description||"")).filter(Boolean);
          if (prev && Date.now()-prev.ts < 2000 && prev.rid === rid) return;
          // Kill any previous bridge for this session.
          const prevBridge = activeQ.get(sid);
          if (prevBridge) { try { prevBridge.kill("SIGTERM"); } catch {} activeQ.delete(sid); }
          // Walk through questions one at a time via X Island.
          async function askSequentially() {
            answeringQ.add(sid);
            try {
              const answers = [];
              for (let i = 0; i < qs.length; i++) {
                const q = qs[i];
                const qText = (q.header ? q.header + ": " : "") + (q.question || "");
                const qOpts = (q.options||[]).map(o=>o.label||o.description||"").filter(Boolean);
                if (!qText.trim() && !qOpts.length) { answers.push([""]); continue; }
                const label = qs.length > 1 ? `[${i+1}/${qs.length}] ${qText}` : qText;
                const answer = await new Promise((resolve) => {
                  const child = spawn(BRIDGE, ["--agent","opencode","--hook","question","--session",sid], { stdio:["pipe","pipe","pipe"] });
                  activeQ.set(sid, child);
                  child.stdin.write(JSON.stringify({ question: label, options: qOpts })); child.stdin.end();
                  let out = "";
                  child.stdout.on("data", d => { out += d.toString(); });
                  child.on("close", () => { if (activeQ.get(sid)===child) activeQ.delete(sid); resolve(out.trim()); });
                  child.on("error", () => { if (activeQ.get(sid)===child) activeQ.delete(sid); resolve(""); });
                  setTimeout(() => { try { child.kill(); } catch {} }, 300000);
                });
                if (!answer) return;
                answers.push([answer]);
              }
              answeredQ.set(sid, { rid, opts: allOpts, ts: Date.now() });
              try { await internalFetch(new Request(`http://localhost:${serverPort}/question/${rid}/reply`, { method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify({answers}) })); } catch {}
            } finally { answeringQ.delete(sid); }
          }
          askSequentially().catch(()=>{ answeringQ.delete(sid); });
          return;
        }
        if ((t==="question.replied"||t==="question.rejected") && p.sessionID) { sendViaBridge("notification",`opencode-${p.sessionID}`,{status:t==="question.replied"?"Question answered":"Question dismissed"}); return; }
        if (t === "message.updated" && p.info?.id && p.info?.sessionID) { msgRoles.set(p.info.id, { role: p.info.role, sessionID: p.info.sessionID }); if (msgRoles.size > 200) msgRoles.delete(msgRoles.keys().next().value); return; }
        if (t === "message.part.updated" && p.part?.type === "text" && p.part?.messageID) {
          const meta = msgRoles.get(p.part.messageID); if (!meta) return;
          const s = getSession(meta.sessionID), text = p.part.text || "";
          if (meta.role === "user" && text) { s.lastUserText = text; sendViaBridge("session_start", `opencode-${meta.sessionID}`, { prompt: text, cwd: sessionCwd.get(meta.sessionID) || "", terminal: process.env.TERM_PROGRAM || "Terminal" }); }
          else if (meta.role === "assistant" && text) { s.lastAssistantText = text; sendViaBridge("notification", `opencode-${meta.sessionID}`, { status: text }); }
          return;
        }
        if (t === "message.part.updated" && p.part?.type === "tool" && p.part?.sessionID) {
          const st = p.part.state?.status, toolName = (p.part.tool || "unknown").charAt(0).toUpperCase() + (p.part.tool || "unknown").slice(1);
          if (st === "running" || st === "pending") sendViaBridge("PreToolUse", `opencode-${p.part.sessionID}`, { tool_name: toolName, tool_input: p.part.state?.input || {} });
          else if (st === "completed" || st === "error") sendViaBridge("PostToolUse", `opencode-${p.part.sessionID}`, { tool_name: toolName });
          return;
        }
        if (t === "session.status" && p.sessionID && p.status?.type === "idle") {
          const s = getSession(p.sessionID);
          sendViaBridge("notification", `opencode-${p.sessionID}`, { status: "idle", message: s.lastAssistantText || "idle" });
        }
      }
      return { "event": async ({ event }) => { try { handleEvent(event); } catch {} } };
    };
    """#
}
