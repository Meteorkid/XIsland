import XCTest
@testable import XIsland

/// 脱敏与诊断导出：出本机的内容不得带凭据、邮箱、家目录或原始命令。
@MainActor
final class ASuiteRedactionTests: XCTestCase {
    func testRedactsKeyValuePairsAndProviderKeys() {
        let text = EventRedaction.redact(
            "api_key=sk-live-abcdefghijklmnop and password: hunter2")
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("sk-live"))
        XCTAssertTrue(text.contains(EventRedaction.placeholder))
    }

    func testRedactsBearerTokenBeforeKeyValueRule() {
        let secret = "eyJhbGciOiJIUzI1NiJ9abcdefghijklmnopqrst"
        let text = EventRedaction.redact("Authorization: Bearer \(secret)")
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("Bearer"))
    }

    func testRedactsLongOpaqueStringsAndEmails() {
        let opaque = String(repeating: "a", count: 48)
        let text = EventRedaction.redact("blob=\(opaque) mail=me@example.com")
        XCTAssertFalse(text.contains(opaque))
        XCTAssertFalse(text.contains("me@example.com"))
        XCTAssertTrue(text.contains("[EMAIL]"))
    }

    func testRedactsURLCredentialsAndQuery() {
        let text = EventRedaction.redact(
            "https://user:pw@host.example/path?token=abcdefghijklmnop&x=1")
        XCTAssertFalse(text.contains("user:pw"))
        XCTAssertFalse(text.contains("token=abcdefghijklmnop"))
        XCTAssertTrue(text.contains(EventRedaction.placeholder))
    }

    func testRedactsHomeDirectory() {
        let home = "/Users/someone"
        let text = EventRedaction.redact("cd \(home)/proj && make build",
                                         homeDirectory: home)
        XCTAssertFalse(text.contains(home))
        XCTAssertTrue(text.contains("~/proj"))
        XCTAssertFalse(text.contains("\n"))
    }

    func testTruncatesLongPlainText() {
        // 用中文长文本：不会被「长 ASCII 凭据」规则先替换掉，能真实检验截断。
        let long = String(repeating: "测", count: 400)
        let text = EventRedaction.redact(long)
        XCTAssertLessThanOrEqual(text.count, EventRedaction.maxLength + 1)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    func testRedactPathKeepsOnlyTail() {
        let redacted = EventRedaction.redact(path: "/Users/someone/proj/src/main.swift",
                                             homeDirectory: "/Users/someone")
        XCTAssertTrue(redacted.hasPrefix("~/proj"))
    }

    func testRedactPathCollapsesDeepPaths() {
        XCTAssertEqual(EventRedaction.redact(path: "/Users/someone/a/b/c/d",
                                             homeDirectory: "/Users/someone"), "~/c/d")
        XCTAssertEqual(EventRedaction.redact(path: "/Volumes/Disk/Projects/app/src",
                                             homeDirectory: "/Users/someone"), "…/app/src")
    }

    func testPushBuilderRedactsTitle() {
        let event = IslandEvent(
            kind: .completed, sessionId: "s", requestId: nil, stableToken: "t",
            title: "api_key=supersecretvalue", detail: "done",
            workingDirectory: "/tmp", isSubagent: false,
            occurredAt: ASuiteFixtures.base)
        let request = PushChannelRequestBuilder.makeRequest(
            config: PushConfiguration(kind: .webhook, endpoint: "https://example.com/h"),
            event: event, redactedDetail: "done")
        let body = request?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(body.contains("supersecretvalue"))
    }

    // MARK: 诊断包文本

    func testDiagnosticsAllowlistExcludesSensitiveKeys() {
        let allowlist = DiagnosticsTextBuilder.preferenceAllowlist
        XCTAssertFalse(allowlist.contains(ASuiteSettings.pushConfigurationsKey))
        XCTAssertFalse(allowlist.contains(ASuiteSettings.dndSilencedDirectoriesKey))
    }

    func testManifestAndSessionsAreRedacted() {
        let manifest = DiagnosticsTextBuilder.manifestText(
            appVersion: "2.0.15", osVersion: "14.0",
            generatedAt: ASuiteFixtures.base,
            settings: ["note": "api_key=supersecretvalue"])
        XCTAssertFalse(manifest.contains("supersecretvalue"))

        let summary = ASuiteFixtures.summary(detail: "password: hunter2")
        let sessions = DiagnosticsTextBuilder.sessionsText([summary])
        XCTAssertFalse(sessions.contains("hunter2"))
        XCTAssertTrue(sessions.contains("status"))
    }

    func testDiagnosticsExportWritesRealZip() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("asuite-diagnostics-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: destination) }

        let artifact = try DiagnosticsExporter.export(
            summaries: [ASuiteFixtures.summary(detail: "token=abcdefghijklmnopqrstuvwxyz")],
            settings: DiagnosticsTextBuilder.snapshotSettings(),
            logFiles: [("sample.log", "api_key=supersecretvalue")],
            generatedAt: ASuiteFixtures.base,
            destination: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertGreaterThan(artifact.byteCount, 0)
    }
}
