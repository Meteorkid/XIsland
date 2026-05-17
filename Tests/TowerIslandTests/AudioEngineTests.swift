import XCTest
@testable import XIsland

final class AudioEngineTests: XCTestCase {

    private var engine: AudioEngine!

    override func setUp() {
        super.setUp()
        // 清理 UserDefaults 状态
        UserDefaults.standard.removeObject(forKey: "audio.isMuted")
        UserDefaults.standard.removeObject(forKey: "audio.volume")
        UserDefaults.standard.removeObject(forKey: "audio.quietHoursEnabled")
        UserDefaults.standard.removeObject(forKey: "audio.quietHoursStart")
        UserDefaults.standard.removeObject(forKey: "audio.quietHoursEnd")
        engine = AudioEngine()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "audio.isMuted")
        UserDefaults.standard.removeObject(forKey: "audio.volume")
        UserDefaults.standard.removeObject(forKey: "audio.quietHoursEnabled")
        UserDefaults.standard.removeObject(forKey: "audio.quietHoursStart")
        UserDefaults.standard.removeObject(forKey: "audio.quietHoursEnd")
        engine = nil
        super.tearDown()
    }

    // MARK: - Mute state

    func testIsMutedFalseByDefault() {
        XCTAssertFalse(engine.isMuted)
    }

    func testIsMutedPersistsToUserDefaults() {
        engine.isMuted = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "audio.isMuted"))
        engine.isMuted = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "audio.isMuted"))
    }

    // MARK: - Volume

    func testVolumeHasDefault() {
        XCTAssertGreaterThan(engine.volume, 0)
    }

    func testVolumePersistsToUserDefaults() {
        engine.volume = 0.75
        XCTAssertEqual(UserDefaults.standard.float(forKey: "audio.volume"), 0.75, accuracy: 0.01)
    }

    // MARK: - Event enable/disable

    func testEventEnabledByDefault() {
        XCTAssertTrue(engine.isEnabled(.permissionRequest))
        XCTAssertTrue(engine.isEnabled(.question))
        XCTAssertTrue(engine.isEnabled(.sessionEnd))
    }

    func testEventDisabledByDefault() {
        XCTAssertFalse(engine.isEnabled(.sessionStart))
        XCTAssertFalse(engine.isEnabled(.toolStart))
        XCTAssertFalse(engine.isEnabled(.contextCompacting))
    }

    func testSetEventEnabled() {
        engine.setEnabled(.sessionStart, true)
        XCTAssertTrue(engine.isEnabled(.sessionStart))

        engine.setEnabled(.sessionStart, false)
        XCTAssertFalse(engine.isEnabled(.sessionStart))
    }

    // MARK: - Quiet hours

    func testQuietHoursDisabledByDefault() {
        XCTAssertFalse(engine.isQuietHoursActive)
    }

    func testQuietHoursActiveDuringConfiguredRange() {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let currentHour = comps.hour ?? 0
        let currentMinute = comps.minute ?? 0

        // 设置 quiet hours 包含当前时间
        let startHour = (currentHour + 23) % 24  // 1 小时前
        let endHour = (currentHour + 1) % 24      // 1 小时后
        let startStr = String(format: "%02d:%02d", startHour, currentMinute)
        let endStr = String(format: "%02d:%02d", endHour, currentMinute)

        UserDefaults.standard.set(true, forKey: "audio.quietHoursEnabled")
        UserDefaults.standard.set(startStr, forKey: "audio.quietHoursStart")
        UserDefaults.standard.set(endStr, forKey: "audio.quietHoursEnd")

        // 重新创建 engine 读取新设置
        let testEngine = AudioEngine()
        XCTAssertTrue(testEngine.isQuietHoursActive)
    }

    // MARK: - Mute rules

    func testMuteRulesEmptyByDefault() {
        XCTAssertTrue(engine.muteRules.isEmpty)
    }

    func testMuteRulesPersistToUserDefaults() {
        let rules = [
            MuteRule(pattern: "test", matchField: .agentType, isEnabled: true),
            MuteRule(pattern: "grep", matchField: .tool, isEnabled: false)
        ]
        engine.muteRules = rules
        XCTAssertEqual(engine.muteRules.count, 2)
        XCTAssertEqual(engine.muteRules[0].pattern, "test")
        XCTAssertEqual(engine.muteRules[1].matchField, .tool)
    }

    // MARK: - Sound event properties

    func testSoundEventAllCases() {
        XCTAssertEqual(SoundEvent.allCases.count, 11)
    }

    func testSoundEventIdIsRawValue() {
        XCTAssertEqual(SoundEvent.sessionStart.id, "session_start")
        XCTAssertEqual(SoundEvent.error.id, "error")
    }

    func testSoundEventDisplayNameNonEmpty() {
        for event in SoundEvent.allCases {
            XCTAssertFalse(event.displayName.isEmpty, "\(event) displayName should not be empty")
        }
    }

    func testSoundEventIconSymbolNonEmpty() {
        for event in SoundEvent.allCases {
            XCTAssertFalse(event.iconSymbol.isEmpty, "\(event) iconSymbol should not be empty")
        }
    }
}
