import Darwin
import XCTest
@testable import XIsland

final class CodexHookTrustProbeTests: XCTestCase {
    private let first = "'/bin/di-bridge' --agent codex --hook session_start || true"
    private let second = "'/bin/di-bridge' --agent codex --hook Stop || true"

    func testTrustedEnabledExactCommandsAreGranted() throws {
        let snapshot = try parse([hook(first), hook(second)])
        XCTAssertEqual(snapshot.state, .granted)
        XCTAssertEqual(snapshot.configuredCount, 2)
        XCTAssertEqual(snapshot.trustedCount, 2)
        XCTAssertEqual(snapshot.fingerprint?.count, 64)
        XCTAssertNil(snapshot.reason)
    }

    func testUntrustedAndModifiedCommandsRequireAuthorization() throws {
        for status in ["untrusted", "modified"] {
            let snapshot = try parse([hook(first), hook(second, status: status)])
            XCTAssertEqual(snapshot.state, .required)
            XCTAssertEqual(snapshot.configuredCount, 2)
            XCTAssertEqual(snapshot.trustedCount, 1)
        }
    }

    func testOtherHooksDoNotAffectTrustOrFingerprint() throws {
        let owned = [hook(first), hook(second)]
        let baseline = try parse(owned)
        let unrelated = [hook("echo \(first)", status: "untrusted"),
                         hook("'/bin/di-bridge-helper' --agent codex --hook Stop", status: "modified"),
                         hook("custom-hook", status: "managed")]
        let result = try parse(owned + unrelated)
        XCTAssertEqual(result.state, .granted)
        XCTAssertEqual(result.configuredCount, 2)
        XCTAssertEqual(result.fingerprint, baseline.fingerprint)
        XCTAssertFalse(result.reason?.contains("custom-hook") ?? false)
    }

    func testMentioningExpectedCommandDoesNotCountAsConfigured() throws {
        let snapshot = try parse([hook(first), hook("echo \(second)")])
        XCTAssertEqual(snapshot.state, .unavailable)
        XCTAssertEqual(snapshot.configuredCount, 1)
        XCTAssertNil(snapshot.fingerprint)
    }

    func testFingerprintTracksDefinitionAndIgnoresOrderOrTrustState() throws {
        let baseline = try parse([hook(first), hook(second)])
        let reordered = try parse([hook(second, status: "modified"), hook(first, status: "untrusted")])
        XCTAssertEqual(baseline.fingerprint, reordered.fingerprint)
        var changed = hook(second)
        changed["currentHash"] = "changed-definition"
        XCTAssertNotEqual(baseline.fingerprint, try parse([hook(first), changed]).fingerprint)
    }

    func testMissingDuplicateDisabledAndManagedCannotBeGranted() throws {
        var disabled = hook(second)
        disabled["enabled"] = false
        var managed = hook(second)
        managed["isManaged"] = true
        for hooks in [[hook(first)], [hook(first), hook(second), hook(second)],
                      [hook(first), disabled], [hook(first), managed],
                      [hook(first), hook(second, status: "managed")]] {
            let snapshot = try parse(hooks)
            XCTAssertEqual(snapshot.state, .unavailable)
            XCTAssertNil(snapshot.fingerprint)
        }
    }

    func testIncompleteOrWrongTypeOwnedMetadataCannotBeGranted() throws {
        let badFields: [(String, Any?)] = [
            ("enabled", nil), ("enabled", 1), ("enabled", "true"),
            ("isManaged", nil), ("isManaged", 0),
            ("handlerType", "prompt"), ("handlerType", nil),
            ("trustStatus", "approved"), ("trustStatus", nil),
            ("currentHash", nil), ("currentHash", ""), ("currentHash", 42),
        ]
        for (key, value) in badFields {
            var invalid = hook(second)
            invalid[key] = value
            XCTAssertEqual(try parse([hook(first), invalid]).state, .unavailable, key)
        }
    }

    func testConfigurationErrorsAreNotLeakedAndCannotBeGranted() throws {
        var entry = entry([hook(first), hook(second)])
        entry["errors"] = [["message": "private-third-party-command", "path": "/private/other"]]
        let result = try CodexHookTrustProbe.parse(response: ["data": [entry]], expectedCommands: [first, second])
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertFalse(result.reason?.contains("private") ?? false)
    }

    func testMalformedOrMultipleWorkspaceResultsAreRejected() {
        let valid = entry([hook(first), hook(second)])
        for response: [String: Any] in [[:], ["data": []], ["data": [valid, valid]],
                                       ["data": [["hooks": []]]], ["data": "invalid"]] {
            XCTAssertThrowsError(try CodexHookTrustProbe.parse(response: response, expectedCommands: [first, second]))
        }
    }

    func testEmptyExpectedCommandsCannotBeGranted() throws {
        let snapshot = try CodexHookTrustProbe.parse(response: ["data": [entry([])]], expectedCommands: [])
        XCTAssertEqual(snapshot.state, .unavailable)
    }

    func testInspectSendsOnlyInitializeInitializedAndHooksList() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = try responseJSON([hook(first), hook(second)], cwd: directory.path)
        let script = try makeScript(in: directory, body: handshake + "\nprintf '%s\\n' \(quote(response))\nread -r finish\n")
        let snapshot = await CodexHookTrustProbe.inspect(binary: script, cwd: directory, expectedCommands: [first, second])
        XCTAssertEqual(snapshot.state, .granted)
        let lines = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        let requests = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "initialized", "hooks/list"])
        XCTAssertEqual(requests[0]["id"] as? Int, 1)
        XCTAssertNil(requests[1]["id"])
        XCTAssertEqual(requests[2]["id"] as? Int, 2)
        XCTAssertEqual((requests[2]["params"] as? [String: Any])?["cwds"] as? [String], [directory.path])
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("arguments"), encoding: .utf8), "app-server --stdio\n")
    }

    func testInspectReportsUntrustedWithoutLeakingUnrelatedHook() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = try responseJSON([hook(first), hook(second, status: "untrusted"), hook("private-other-command", status: "untrusted")], cwd: directory.path)
        let script = try makeScript(in: directory, body: handshake + "\nprintf '%s\\n' \(quote(response))\n")
        let snapshot = await CodexHookTrustProbe.inspect(binary: script, cwd: directory, expectedCommands: [first, second])
        XCTAssertEqual(snapshot.state, .required)
        XCTAssertEqual(snapshot.configuredCount, 2)
        XCTAssertFalse(snapshot.reason?.contains("private-other-command") ?? false)
    }

    func testInspectHandlesMalformedJSONAndEarlyExit() async throws {
        for body in ["printf '%s\\n' 'not-json'\n", "exit 7\n",
                     "read -r init\nprintf '%s\\n' '{\"id\":1,\"error\":{\"message\":\"secret\"}}'\n"] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = try makeScript(in: directory, body: body)
            let snapshot = await CodexHookTrustProbe.inspect(binary: script, cwd: directory, expectedCommands: [first, second])
            XCTAssertEqual(snapshot.state, .unavailable)
            XCTAssertFalse(snapshot.reason?.contains("secret") ?? false)
        }
    }

    func testInspectTimesOutAndKillsUnresponsiveServerWithinEightSeconds() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(in: directory, body: "trap '' TERM\nprintf '%s' \"$$\" > pid\nwhile :; do read -r request || :; done\n")
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = await CodexHookTrustProbe.inspect(binary: script, cwd: directory, expectedCommands: [first, second])
        XCTAssertEqual(snapshot.state, .unavailable)
        XCTAssertTrue(snapshot.reason?.contains("超时") ?? false)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 8)
        let pidText = try String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testInspectBoundsOutputWithoutDeadlock() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(in: directory, body: "exec /usr/bin/head -c 5000000 /dev/zero\n")
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = await CodexHookTrustProbe.inspect(binary: script, cwd: directory, expectedCommands: [first, second])
        XCTAssertEqual(snapshot.state, .unavailable)
        XCTAssertTrue(snapshot.reason?.contains("大小限制") ?? false)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 8)
        XCTAssertFalse(snapshot.reason?.contains("private-unbounded-output") ?? false)
    }

    func testLargeStderrDoesNotBlockSuccessfulResponse() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = try responseJSON([hook(first), hook(second)], cwd: directory.path)
        let script = try makeScript(in: directory, body: handshake + "\n/usr/bin/head -c 5000000 /dev/zero >&2\nprintf '%s\\n' \(quote(response))\n")
        let snapshot = await CodexHookTrustProbe.inspect(binary: script, cwd: directory, expectedCommands: [first, second])
        XCTAssertEqual(snapshot.state, .granted)
    }

    private func hook(_ command: String, status: String = "trusted") -> [String: Any] {
        ["command": command, "handlerType": "command", "enabled": true, "isManaged": false,
         "trustStatus": status, "currentHash": "hash-\(command)"]
    }

    private func entry(_ hooks: [[String: Any]]) -> [String: Any] {
        ["cwd": "/fixture", "hooks": hooks, "errors": [], "warnings": []]
    }

    private func parse(_ hooks: [[String: Any]]) throws -> CodexHookTrustSnapshot {
        try CodexHookTrustProbe.parse(response: ["data": [entry(hooks)]], expectedCommands: [first, second])
    }

    private func responseJSON(_ hooks: [[String: Any]], cwd: String = "/fixture") throws -> String {
        var responseEntry = entry(hooks)
        responseEntry["cwd"] = cwd
        let data = try JSONSerialization.data(withJSONObject: ["id": 2, "result": ["data": [responseEntry]]])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xisland-trust-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeScript(in directory: URL, body: String) throws -> URL {
        let script = directory.appendingPathComponent("fake-codex")
        try ("#!/bin/sh\nprintf '%s\\n' \"$*\" > arguments\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private var handshake: String {
        """
        read -r init
        printf '%s\\n' "$init" >> requests.jsonl
        printf '%s\\n' '{"id":1,"result":{}}'
        read -r initialized
        printf '%s\\n' "$initialized" >> requests.jsonl
        read -r hooks
        printf '%s\\n' "$hooks" >> requests.jsonl
        """
    }
}
