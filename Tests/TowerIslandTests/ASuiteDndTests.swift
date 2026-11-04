import XCTest
@testable import XIsland

/// A4 不打扰：三态、跨午夜静默、静默目录、子会话、跟进提醒。
@MainActor
final class ASuiteDndTests: XCTestCase {
    func testQuietHoursParsing() {
        XCTAssertEqual(DoNotDisturbPolicy.minutes(from: "22:30"), 1350)
        XCTAssertEqual(DoNotDisturbPolicy.minutes(from: "07:00"), 420)
        XCTAssertNil(DoNotDisturbPolicy.minutes(from: "25:00"))
        XCTAssertNil(DoNotDisturbPolicy.minutes(from: "abc"))
        XCTAssertEqual(DoNotDisturbPolicy.parseDirectories("/tmp, node_modules\nbuild"),
                       ["/tmp", "node_modules", "build"])
    }

    func testQuietHoursCrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var policy = DoNotDisturbPolicy()
        policy.quietHoursEnabled = true
        policy.quietStart = "22:00"
        policy.quietEnd = "07:00"
        let night = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 1, hour: 23, minute: 0))!
        let noon = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 1, hour: 12, minute: 0))!
        XCTAssertTrue(policy.isInQuietHours(now: night, calendar: calendar))
        XCTAssertFalse(policy.isInQuietHours(now: noon, calendar: calendar))
    }

    func testDecisionEventsBypassQuietHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let noon = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 1, hour: 12, minute: 0))!
        var policy = DoNotDisturbPolicy()
        policy.quietHoursEnabled = true
        policy.quietStart = "00:00"
        policy.quietEnd = "23:59"
        XCTAssertTrue(policy.shouldNotify(event: ASuiteFixtures.event(kind: .permission),
                                          scene: SceneMuteState(), isUserActive: false,
                                          now: noon, calendar: calendar))
        XCTAssertFalse(policy.shouldNotify(event: ASuiteFixtures.event(kind: .completed),
                                           scene: SceneMuteState(), isUserActive: false,
                                           now: noon, calendar: calendar))
    }

    func testDisplaySleepHardMutesEvenDecisionEvents() {
        var scene = SceneMuteState()
        scene.isDisplayAsleep = true
        XCTAssertTrue(scene.isHardMuted)
        XCTAssertFalse(DoNotDisturbPolicy().shouldNotify(
            event: ASuiteFixtures.event(kind: .permission),
            scene: scene, isUserActive: false))
    }

    func testLockAndScreensaverCountAsAway() {
        var scene = SceneMuteState()
        XCTAssertFalse(scene.isAway)
        scene.isScreenLocked = true
        XCTAssertTrue(scene.isAway)
        scene.isScreenLocked = false
        scene.isScreensaverActive = true
        XCTAssertTrue(scene.isAway)
    }

    func testSilencedDirectoriesAndSubagents() {
        var policy = DoNotDisturbPolicy()
        policy.silencedDirectories = ["NODE_MODULES"]
        XCTAssertFalse(policy.shouldNotify(
            event: ASuiteFixtures.event(cwd: "/Users/me/proj/node_modules/pkg"),
            scene: SceneMuteState(), isUserActive: false))
        XCTAssertFalse(policy.shouldNotify(
            event: ASuiteFixtures.event(isSubagent: true),
            scene: SceneMuteState(), isUserActive: false))
        XCTAssertTrue(policy.shouldNotify(
            event: ASuiteFixtures.event(cwd: "/Users/me/proj"),
            scene: SceneMuteState(), isUserActive: false))
    }

    func testBackgroundCompactionAndActiveUserAreSuppressed() {
        let policy = DoNotDisturbPolicy()
        XCTAssertFalse(policy.shouldNotify(
            event: ASuiteFixtures.event(kind: .backgroundCompaction),
            scene: SceneMuteState(), isUserActive: false))
        XCTAssertFalse(policy.shouldNotify(event: ASuiteFixtures.event(),
                                           scene: SceneMuteState(), isUserActive: true))
    }

    func testFollowUpDelayBoundary() {
        var policy = DoNotDisturbPolicy()
        XCTAssertFalse(policy.isFollowUpDue(eventOccurredAt: ASuiteFixtures.base,
                                            now: ASuiteFixtures.base))
        policy.followUpEnabled = true
        policy.followUpDelay = 600
        XCTAssertFalse(policy.isFollowUpDue(
            eventOccurredAt: ASuiteFixtures.base,
            now: ASuiteFixtures.base.addingTimeInterval(599)))
        XCTAssertTrue(policy.isFollowUpDue(
            eventOccurredAt: ASuiteFixtures.base,
            now: ASuiteFixtures.base.addingTimeInterval(601)))
    }
}
