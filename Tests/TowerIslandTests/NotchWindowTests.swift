import XCTest
@testable import XIsland

@MainActor
final class NotchWindowTests: XCTestCase {
    func testCollapsedWindowFrameMatchesVisiblePillSize() {
        let window = NotchWindow()

        window.resizeToFitCollapse(contentWidth: 180, contentHeight: 32)

        XCTAssertEqual(window.frame.width, 180, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, 32, accuracy: 0.5)
    }

    func testResizeToFitClampsTinyHeights() {
        let window = NotchWindow()

        window.resizeToFit(contentWidth: 180, contentHeight: 1)

        XCTAssertEqual(window.frame.height, 32, accuracy: 0.5)
    }
}
