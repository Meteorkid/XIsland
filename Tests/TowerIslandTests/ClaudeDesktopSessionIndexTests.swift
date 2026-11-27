import XCTest
@testable import XIsland

final class ClaudeDesktopSessionIndexTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("xisland-claude-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ object: [String: Any], root: String, local: String) throws -> URL {
        let directory = base.appendingPathComponent("\(root)/org/account", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(local + ".json")
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
        return url
    }

    func testMapsExactCLISessionToCodeAndCoworkRoutes() throws {
        let codeCLI = "c2d57ea0-55b6-4cc2-b032-a6c476da9263"
        let coworkCLI = "e681c93e-1714-488b-9947-0682f549c09e"
        _ = try write(["sessionId": "local_f39fbf5b-7e13-47ef-87a7-2a22f1f1e676",
                       "cliSessionId": codeCLI, "lastActivityAt": 1788784570652],
                      root: "claude-code-sessions", local: "local_f39fbf5b-7e13-47ef-87a7-2a22f1f1e676")
        _ = try write(["sessionId": "local_87e3abb8-1388-4708-b383-dd3e32f7c609",
                       "cliSessionId": coworkCLI, "lastActivityAt": 1783354988371],
                      root: "local-agent-mode-sessions", local: "local_87e3abb8-1388-4708-b383-dd3e32f7c609")

        let index = ClaudeDesktopSessionIndex(roots: [
            .init(url: base.appendingPathComponent("claude-code-sessions"), route: .code),
            .init(url: base.appendingPathComponent("local-agent-mode-sessions"), route: .cowork),
        ])
        let code = try XCTUnwrap(index.match(cliSessionID: codeCLI))
        XCTAssertEqual(code.route, .code)
        XCTAssertEqual(code.localSessionID, "local_f39fbf5b-7e13-47ef-87a7-2a22f1f1e676")
        XCTAssertEqual(ClaudeDesktopSessionIndex.deepLink(for: code),
                       URL(string: "claude://claude.ai/epitaxy/local_f39fbf5b-7e13-47ef-87a7-2a22f1f1e676"))

        let cowork = try XCTUnwrap(index.match(cliSessionID: coworkCLI))
        XCTAssertEqual(cowork.route, .cowork)
        XCTAssertEqual(ClaudeDesktopSessionIndex.deepLink(for: cowork),
                       URL(string: "claude://claude.ai/cowork/local_87e3abb8-1388-4708-b383-dd3e32f7c609"))
    }

    func testArchivedOrMismatchedEntriesNeverProduceALink() throws {
        let cli = "c2d57ea0-55b6-4cc2-b032-a6c476da9263"
        _ = try write(["sessionId": "local_f39fbf5b-7e13-47ef-87a7-2a22f1f1e676",
                       "cliSessionId": cli, "isArchived": true],
                      root: "claude-code-sessions", local: "local_f39fbf5b-7e13-47ef-87a7-2a22f1f1e676")
        _ = try write(["sessionId": "local_0fc9e222-df57-4274-ba4f-c502be0379bf",
                       "cliSessionId": "other", "isArchived": false],
                      root: "claude-code-sessions", local: "local_0fc9e222-df57-4274-ba4f-c502be0379bf")
        let index = ClaudeDesktopSessionIndex(roots: [
            .init(url: base.appendingPathComponent("claude-code-sessions"), route: .code),
        ])
        XCTAssertNil(index.match(cliSessionID: cli))
        XCTAssertNil(index.match(cliSessionID: "missing"))
    }

    func testNewestEntryWinsAndBridgeSessionIDsAreAccepted() throws {
        let cli = "c2d57ea0-55b6-4cc2-b032-a6c476da9263"
        _ = try write(["sessionId": "local_6c0b1d81-d58a-449b-8244-159bd0e56742",
                       "bridgeSessionIds": [cli], "lastActivityAt": 100],
                      root: "claude-code-sessions", local: "local_6c0b1d81-d58a-449b-8244-159bd0e56742")
        _ = try write(["sessionId": "local_fa4af932-7dd6-4569-ba2e-f11399b4a1a1",
                       "cliSessionId": cli, "lastActivityAt": 200],
                      root: "claude-code-sessions", local: "local_fa4af932-7dd6-4569-ba2e-f11399b4a1a1")
        let index = ClaudeDesktopSessionIndex(roots: [
            .init(url: base.appendingPathComponent("claude-code-sessions"), route: .code),
        ])
        XCTAssertEqual(index.match(cliSessionID: cli)?.localSessionID,
                       "local_fa4af932-7dd6-4569-ba2e-f11399b4a1a1")
    }

    func testInvalidLocalIDsAreRejected() {
        for id in ["local_", "local_../escape", "local_bad id", "local_\(String(repeating: "a", count: 65))"] {
            XCTAssertFalse(ClaudeDesktopSessionIndex.validLocalSessionID(id), id)
        }
    }
}
