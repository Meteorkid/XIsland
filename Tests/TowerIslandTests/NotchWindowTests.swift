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

    // MARK: - 屏幕选择（纯函数，与实际显示器配置无关）

    /// 副屏在主屏上方时，Quartz 的 y 为负；不做翻转会导致任何屏都判不中
    func testConvertToAppKitFlipsVerticallyStackedDisplay() {
        let primaryFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowOnUpperScreen = CGRect(x: 0, y: -1080, width: 1600, height: 900)

        let converted = NotchWindow.convertToAppKit(cgRect: windowOnUpperScreen, primaryFrame: primaryFrame)

        XCTAssertEqual(converted, CGRect(x: 0, y: 1260, width: 1600, height: 900))
    }

    func testConvertToAppKitLeavesWindowOnPrimaryScreenInPlace() {
        let primaryFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let fullScreenWindow = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let converted = NotchWindow.convertToAppKit(cgRect: fullScreenWindow, primaryFrame: primaryFrame)

        XCTAssertEqual(converted, primaryFrame)
    }

    func testIndexOfScreenPicksVerticallyStackedUpperScreen() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        ]
        let windowOnUpperScreen = CGRect(x: 0, y: 1260, width: 1600, height: 900)

        XCTAssertEqual(NotchWindow.indexOfScreen(bestOverlapping: windowOnUpperScreen, in: frames), 1)
    }

    /// 窗口跨屏时按重叠面积选，而不是按中心点
    func testIndexOfScreenPicksLargerOverlapWhenWindowStraddlesScreens() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1000, height: 1000),
            CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        ]
        let mostlyOnSecondScreen = CGRect(x: 900, y: 0, width: 800, height: 1000)

        XCTAssertEqual(NotchWindow.indexOfScreen(bestOverlapping: mostlyOnSecondScreen, in: frames), 1)
    }

    func testIndexOfScreenReturnsNilWhenNothingOverlaps() {
        let frames = [CGRect(x: 0, y: 0, width: 1000, height: 1000)]

        XCTAssertNil(NotchWindow.indexOfScreen(bestOverlapping: CGRect(x: 5000, y: 5000, width: 100, height: 100), in: frames))
        XCTAssertNil(NotchWindow.indexOfScreen(bestOverlapping: CGRect(x: 0, y: 0, width: 100, height: 100), in: []))
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
