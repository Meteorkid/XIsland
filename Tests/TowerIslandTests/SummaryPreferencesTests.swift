import XCTest
@testable import XIsland

final class SummaryPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "dev.xisland.tests.summary.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testLegacyModelMigratesOnlyToCurrentProvider() {
        defaults.set("qwen2.5:3b", forKey: SummaryModelStore.legacyKey)

        XCTAssertEqual(SummaryModelStore.model(for: "ollama", defaults: defaults), "qwen2.5:3b")
        XCTAssertEqual(defaults.string(forKey: SummaryModelStore.key(for: "ollama")), "qwen2.5:3b")
        XCTAssertNil(defaults.string(forKey: SummaryModelStore.legacyKey))
        XCTAssertEqual(SummaryModelStore.model(for: "openai", defaults: defaults), "")
    }

    func testModelsAreScopedByProvider() {
        SummaryModelStore.set("qwen2.5:3b", for: "ollama", defaults: defaults)
        SummaryModelStore.set("gpt-4o-mini", for: "openai", defaults: defaults)

        XCTAssertEqual(SummaryModelStore.model(for: "ollama", defaults: defaults), "qwen2.5:3b")
        XCTAssertEqual(SummaryModelStore.model(for: "openai", defaults: defaults), "gpt-4o-mini")
        XCTAssertEqual(SummaryModelStore.model(for: "zhipu", defaults: defaults), "")

        SummaryModelStore.set("", for: "openai", defaults: defaults)
        XCTAssertEqual(SummaryModelStore.model(for: "openai", defaults: defaults), "")
    }

    func testSummaryRequiresExplicitConsent() {
        defaults.set(true, forKey: SummaryConsent.enabledKey)
        XCTAssertFalse(SummaryConsent.isEnabled(defaults: defaults))

        SummaryConsent.accept(defaults: defaults)
        XCTAssertTrue(SummaryConsent.isEnabled(defaults: defaults))

        SummaryConsent.disable(defaults: defaults)
        XCTAssertFalse(SummaryConsent.isEnabled(defaults: defaults))
    }
}
