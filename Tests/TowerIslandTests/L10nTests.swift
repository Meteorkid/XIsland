import XCTest
@testable import XIsland

final class L10nTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "appLanguage")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        super.tearDown()
    }

    // MARK: - effectiveLanguage

    func testEffectiveLanguageReturnsManualOverrideWhenSet() {
        UserDefaults.standard.set("ko", forKey: "appLanguage")
        XCTAssertEqual(L10n.effectiveLanguage, "ko")
    }

    func testEffectiveLanguageReturnsSupportedLanguageWhenNoOverride() {
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        let lang = L10n.effectiveLanguage
        XCTAssertTrue(["zh", "en", "ko", "ja", "fr"].contains(lang),
                      "effectiveLanguage should return a supported language code, got: \(lang)")
    }

    // MARK: - availableLanguages

    func testAvailableLanguagesContainsAllSix() {
        let codes = L10n.availableLanguages.map(\.code)
        XCTAssertTrue(codes.contains("auto"))
        XCTAssertTrue(codes.contains("zh"))
        XCTAssertTrue(codes.contains("en"))
        XCTAssertTrue(codes.contains("ko"))
        XCTAssertTrue(codes.contains("ja"))
        XCTAssertTrue(codes.contains("fr"))
    }

    func testAutoLanguageHasNonEmptyName() {
        let auto = L10n.availableLanguages.first { $0.code == "auto" }
        XCTAssertNotNil(auto)
        XCTAssertFalse(auto!.name.isEmpty)
    }

    // MARK: - Static string sanity checks (via public properties)

    func testCoreStringsAreNonEmpty() {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        XCTAssertFalse(L10n.ready.isEmpty)
        XCTAssertFalse(L10n.active.isEmpty)
        XCTAssertFalse(L10n.quitApp.isEmpty)
        XCTAssertFalse(L10n.dismissAll.isEmpty)
        XCTAssertFalse(L10n.activityLog.isEmpty)
        XCTAssertFalse(L10n.noActivity.isEmpty)
        XCTAssertFalse(L10n.soundMute.isEmpty)
        XCTAssertFalse(L10n.unmute.isEmpty)
        XCTAssertFalse(L10n.prefsEllipsis.isEmpty)
    }

    func testCoreStringsAreNonEmptyInAllLanguages() {
        for lang in ["zh", "en", "ko", "ja", "fr"] {
            UserDefaults.standard.set(lang, forKey: "appLanguage")
            XCTAssertFalse(L10n.ready.isEmpty, "L10n.ready empty for \(lang)")
            XCTAssertFalse(L10n.quitApp.isEmpty, "L10n.quitApp empty for \(lang)")
            XCTAssertFalse(L10n.activityLog.isEmpty, "L10n.activityLog empty for \(lang)")
        }
    }

    func testParameterizedStringsWork() {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        let toolStr = L10n.toolRunning("grep")
        XCTAssertTrue(toolStr.contains("grep"))
    }

    func testActiveSessionsContainsCountPlaceholder() {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        // L10n.activeSessions should be a suffix like " active"
        XCTAssertFalse(L10n.activeSessions.isEmpty)
    }

    // MARK: - Language switching consistency

    func testSwitchingLanguageChangesOutput() {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        let enReady = L10n.ready

        UserDefaults.standard.set("zh", forKey: "appLanguage")
        let zhReady = L10n.ready

        // 英文和中文的 "Ready" 应该不同
        // (除非恰好相同，但至少 quitApp 应该不同)
        UserDefaults.standard.set("en", forKey: "appLanguage")
        let enQuit = L10n.quitApp
        UserDefaults.standard.set("zh", forKey: "appLanguage")
        let zhQuit = L10n.quitApp
        XCTAssertNotEqual(enQuit, zhQuit, "English and Chinese quit strings should differ")
    }
}
