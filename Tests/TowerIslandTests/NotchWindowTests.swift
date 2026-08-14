import XCTest
@testable import XIsland

@MainActor
final class NotchWindowTests: XCTestCase {
    func testCollapsedWindowFrameMatchesVisiblePillSize() {
        let window = NotchWindow()

        window.resizeToFitCollapse(contentWidth: 180, contentHeight: 32)

        // 高度 = max(内容高度, 收起态高度) + windowTopExtension（窗口向上延伸使屏幕顶端在窗口内部）
        let expectedHeight = max(32, IslandSizeCalculator.collapsedShapeHeight) + NotchWindow.windowTopExtension
        XCTAssertEqual(window.frame.width, 180, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, expectedHeight, accuracy: 0.5)
    }

    func testResizeToFitClampsTinyHeights() {
        let window = NotchWindow()

        window.resizeToFit(contentWidth: 180, contentHeight: 1)

        let expectedHeight = max(32, IslandSizeCalculator.collapsedShapeHeight) + NotchWindow.windowTopExtension
        XCTAssertEqual(window.frame.height, expectedHeight, accuracy: 0.5)
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

    func testActiveScreenReturnsAnAvailableScreen() {
        let active = NotchWindow.activeScreen()
        XCTAssertTrue(NSScreen.screens.contains { $0.frame == active.frame })
    }

    func testShowAtActiveScreenPositionsOnAnAvailableScreenAndShows() {
        let window = NotchWindow()
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)

        window.showAtActiveScreen()

        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(NSScreen.screens.contains { $0.frame == window.screen?.frame })
    }
}
