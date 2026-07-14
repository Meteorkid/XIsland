import XCTest
@testable import XIsland

@MainActor
final class AppSwitcherTests: XCTestCase {
    func testCurrentAppIdentityIsXIsland() {
        XCTAssertEqual(AppSwitcher.shared.currentAppName, "xisland")
        XCTAssertEqual(AppSwitcher.shared.currentURLScheme, "xisland")
    }

    func testSwitchURLUsesTargetSpecificScheme() {
        XCTAssertEqual(
            AppSwitcher.shared.switchURL(for: "xnook"),
            URL(string: "xnook://xnook/show")
        )
        XCTAssertEqual(
            AppSwitcher.shared.switchURL(for: "xisland"),
            URL(string: "xisland://xisland/show")
        )
    }
}
