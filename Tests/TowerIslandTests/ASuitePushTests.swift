import XCTest
@testable import XIsland

/// A3 推送：配置校验、请求构造、投递策略。全部不发网络。
@MainActor
final class ASuitePushTests: XCTestCase {
    private func config(_ kind: PushChannelKind = .webhook,
                        endpoint: String = "https://example.com/hook",
                        secret: String = "",
                        events: Set<String>? = nil) -> PushConfiguration {
        var value = PushConfiguration(kind: kind, endpoint: endpoint, secret: secret)
        if let events { value.enabledEvents = events }
        return value
    }

    func testConfigurationValidation() {
        XCTAssertTrue(config().isValid)
        XCTAssertFalse(config(endpoint: "not-a-url").isValid)
        XCTAssertFalse(config(endpoint: "ftp://example.com").isValid)
        XCTAssertFalse(config(.dingTalk, secret: "").isValid)
        XCTAssertTrue(config(.dingTalk, secret: "sign").isValid)
        var disabled = config()
        disabled.isEnabled = false
        XCTAssertFalse(disabled.isValid)
    }

    func testWebhookPayloadNeverCarriesRawCommand() {
        let event = ASuiteFixtures.event(kind: .permission, requestId: "r1",
                                         detail: "rm -rf / --token=RAWSECRETVALUE")
        let payload = PushChannelRequestBuilder.webhookPayload(
            event: event, title: "Proj", body: EventRedaction.redact(event.detail))
        XCTAssertEqual(payload["event"], "permission")
        XCTAssertEqual(payload["requestId"], "r1")
        XCTAssertFalse(payload.values.contains("RAWSECRETVALUE"))
        // 推送正文里没有任何「可执行决定」字段。
        XCTAssertNil(payload["decision"])
        XCTAssertNil(payload["action"])
    }

    func testRequestConstruction() {
        let event = ASuiteFixtures.event()
        let request = PushChannelRequestBuilder.makeRequest(
            config: config(), event: event, redactedDetail: "done")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.host, "example.com")
        let body = request?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(body.contains("completed"))
    }

    func testBarkEncodesTitleAndBodyIntoPath() {
        let request = PushChannelRequestBuilder.makeRequest(
            config: config(.bark, endpoint: "https://bark.example.com/key"),
            event: ASuiteFixtures.event(), redactedDetail: "hello world")
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertTrue(request?.url?.path.contains("hello%20world") == true)
    }

    func testPushPolicyOnlyWhenAway() {
        let event = ASuiteFixtures.event()
        var scene = SceneMuteState()
        XCTAssertFalse(PushPolicy.shouldDeliver(
            event: event, config: config(), scene: scene, onlyWhenAway: true,
            isUserActive: false, dnd: DoNotDisturbPolicy()))
        scene.isScreenLocked = true
        XCTAssertTrue(PushPolicy.shouldDeliver(
            event: event, config: config(), scene: scene, onlyWhenAway: true,
            isUserActive: false, dnd: DoNotDisturbPolicy()))
    }

    func testPushPolicyBlocksSubagentsCompactionAndUnsubscribedEvents() {
        var scene = SceneMuteState()
        scene.isScreenLocked = true
        XCTAssertFalse(PushPolicy.shouldDeliver(
            event: ASuiteFixtures.event(isSubagent: true), config: config(),
            scene: scene, onlyWhenAway: true, isUserActive: false,
            dnd: DoNotDisturbPolicy()))
        XCTAssertFalse(PushPolicy.shouldDeliver(
            event: ASuiteFixtures.event(kind: .backgroundCompaction), config: config(),
            scene: scene, onlyWhenAway: true, isUserActive: false,
            dnd: DoNotDisturbPolicy()))
        XCTAssertFalse(PushPolicy.shouldDeliver(
            event: ASuiteFixtures.event(kind: .started), config: config(),
            scene: scene, onlyWhenAway: true, isUserActive: false,
            dnd: DoNotDisturbPolicy()))
    }

    func testSubagentSuppressionIsConfigurable() {
        var scene = SceneMuteState()
        scene.isScreenLocked = true
        var policy = DoNotDisturbPolicy()
        policy.suppressSubagents = true
        XCTAssertFalse(PushPolicy.shouldDeliver(
            event: ASuiteFixtures.event(isSubagent: true), config: config(),
            scene: scene, onlyWhenAway: true, isUserActive: false, dnd: policy))
        policy.suppressSubagents = false
        XCTAssertTrue(PushPolicy.shouldDeliver(
            event: ASuiteFixtures.event(isSubagent: true), config: config(),
            scene: scene, onlyWhenAway: true, isUserActive: false, dnd: policy))
    }

    func testPushConfigurationsRoundTrip() {
        let items = [config(), config(.ntfy, endpoint: "https://ntfy.example.com/topic")]
        let encoded = try? JSONEncoder().encode(items)
        XCTAssertNotNil(encoded)
        let decoded = encoded.flatMap { try? JSONDecoder().decode([PushConfiguration].self, from: $0) }
        XCTAssertEqual(decoded, items)
    }
}
