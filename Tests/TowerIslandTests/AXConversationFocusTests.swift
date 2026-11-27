import XCTest
@testable import XIsland

final class AXConversationFocusTests: XCTestCase {
    private func candidate(_ index: Int, _ label: String, role: String = "AXButton",
                           enabled: Bool = true, canPress: Bool = true,
                           focused: Bool = true, container: Bool = true) -> AXConversationFocus.Candidate {
        .init(index: index, label: label, role: role, enabled: enabled,
              canPress: canPress, inFocusedWindow: focused, inConversationContainer: container)
    }

    func testExactUniqueMatchIsSelected() {
        let candidates = [
            candidate(0, "Fix login bug"),
            candidate(1, "Fix login bug · 2m ago"),
        ]
        XCTAssertEqual(AXConversationFocus.select(title: "Fix login bug", candidates: candidates), .unique(0))
    }

    func testDuplicateExactMatchIsAmbiguousRatherThanFirstWins() {
        let candidates = [candidate(0, "Fix login bug"), candidate(1, "Fix login bug")]
        XCTAssertEqual(AXConversationFocus.select(title: "Fix login bug", candidates: candidates), .ambiguous)
    }

    func testFocusedWindowExactMatchWinsOverOtherWindow() {
        let candidates = [
            candidate(0, "Fix login bug", focused: false),
            candidate(1, "Fix login bug", focused: true),
        ]
        XCTAssertEqual(AXConversationFocus.select(title: "Fix login bug", candidates: candidates), .unique(1))
    }

    func testSubstringMatchRequiresFourCharactersAndUniqueness() {
        let short = [candidate(0, "修复登录问题 · 2m ago")]
        XCTAssertEqual(AXConversationFocus.select(title: "修复", candidates: short), .none)

        let long = [candidate(0, "修复登录问题 · 2m ago"), candidate(1, "另一个修复登录问题 · 1m ago")]
        XCTAssertEqual(AXConversationFocus.select(title: "修复登录", candidates: long), .ambiguous)
    }

    func testGenericOrInactionableLabelsAreNeverPressed() {
        for title in ["New chat", "聊天", "Untitled"] {
            XCTAssertEqual(AXConversationFocus.select(title: title,
                candidates: [candidate(0, title)]), .none)
        }
        XCTAssertEqual(AXConversationFocus.select(title: "Fix login bug",
            candidates: [candidate(0, "Fix login bug", role: "AXStaticText")]), .none)
        XCTAssertEqual(AXConversationFocus.select(title: "Fix login bug",
            candidates: [candidate(0, "Fix login bug", canPress: false)]), .none)
        XCTAssertEqual(AXConversationFocus.select(title: "Fix login bug",
            candidates: [candidate(0, "Fix login bug", enabled: false)]), .none)
    }

    func testToolbarButtonOutsideConversationContainerIsNeverPressed() {
        XCTAssertEqual(AXConversationFocus.select(title: "Fix login bug",
            candidates: [candidate(0, "Fix login bug", container: false)]), .none)
    }

    func testNonMatchingCandidateIsNotSelected() {
        XCTAssertEqual(AXConversationFocus.select(title: "Fix login bug",
            candidates: [candidate(0, "Fix logout bug")]), .none)
    }
}
