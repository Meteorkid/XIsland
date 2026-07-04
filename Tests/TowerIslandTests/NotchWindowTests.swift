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

    func testShouldTriggerScrollExpandAcceptsCollapsedPreciseDownwardScrollInsideHitFrame() {
        let windowFrame = CGRect(x: 100, y: 860, width: 220, height: 40)
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertTrue(
            NotchWindow.shouldTriggerScrollExpand(
                isEnabled: true,
                isVisible: true,
                isCollapsed: true,
                isPrecise: true,
                deltaY: 4,
                windowFrame: windowFrame,
                screenFrame: screenFrame,
                mouseLocation: CGPoint(x: 180, y: 899)
            )
        )
    }

    func testShouldTriggerScrollExpandRejectsHiddenWindowAndOutsidePointer() {
        let windowFrame = CGRect(x: 100, y: 860, width: 220, height: 40)
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertFalse(
            NotchWindow.shouldTriggerScrollExpand(
                isEnabled: true,
                isVisible: false,
                isCollapsed: true,
                isPrecise: true,
                deltaY: 4,
                windowFrame: windowFrame,
                screenFrame: screenFrame,
                mouseLocation: CGPoint(x: 180, y: 899)
            )
        )

        XCTAssertFalse(
            NotchWindow.shouldTriggerScrollExpand(
                isEnabled: true,
                isVisible: true,
                isCollapsed: true,
                isPrecise: true,
                deltaY: 4,
                windowFrame: windowFrame,
                screenFrame: screenFrame,
                mouseLocation: CGPoint(x: 80, y: 899)
            )
        )
    }
}
