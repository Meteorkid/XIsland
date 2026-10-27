import AppKit
import CoreGraphics
import XCTest
@testable import XIsland

@MainActor
final class IslandWindowOwnershipTests: XCTestCase {
    func testFrontmostOverlappingIslandOwnsGlobalSwipe() {
        let bounds = CGRect(x: 100, y: 0, width: 240, height: 50)
        let snapshots = [
            IslandWindowSnapshot(number: 20, ownerPID: 200, bounds: bounds, alpha: 1),
            IslandWindowSnapshot(number: 10, ownerPID: 100, bounds: bounds, alpha: 1),
        ]

        let owner = IslandWindowOwnership.frontmostWindowNumber(
            overlapping: bounds,
            snapshots: snapshots,
            islandPIDs: [100, 200]
        )

        XCTAssertEqual(owner, 20)
    }

    func testVisibleIslandWindowRecognizesItselfAsFrontmost() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("原生所有权验证需要WindowServer屏幕") }
        let suite = "dev.xisland.tests.window-ownership.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "showOnAllSpaces")
        defaults.set(false, forKey: "hideInFullscreen")
        let window = NotchWindow(defaults: defaults, markVisible: {}, onExplicitShow: {})
        defer { window.close(); defaults.removePersistentDomain(forName: suite) }
        NotificationCenter.default.removeObserver(window)
        NSWorkspace.shared.notificationCenter.removeObserver(window)
        window.allowsAutomaticScreenChange = { false }
        window.level = .screenSaver
        window.hidesOnDeactivate = false
        // 透明零内容窗口可能不进入onScreen列表；提供与生产岛同样实际可绘制的内容。
        window.isOpaque = true
        window.backgroundColor = .black
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content
        window.orderFrontRegardless()
        window.displayIfNeeded()

        func ownSnapshot() -> [String: Any]? {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]])?.first { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while ownSnapshot() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try XCTUnwrap(ownSnapshot(),
            "WindowServer尚未登记fixture：visible=\(window.isVisible), appHidden=\(NSApp.isHidden), number=\(window.windowNumber), frame=\(window.frame)")
        XCTAssertGreaterThan(snapshot[kCGWindowAlpha as String] as? Double ?? 0, 0)
        let bounds = try XCTUnwrap(snapshot[kCGWindowBounds as String] as? [String: Double])
        XCTAssertGreaterThan(bounds["Width"] ?? 0, 0)
        XCTAssertGreaterThan(bounds["Height"] ?? 0, 0)
        // 只等待原生显示前置条件，不轮询产品判断直到它碰巧返回true。
        XCTAssertTrue(window.isFrontmostIslandWindow())
    }

    func testLinkedCanvasIsIgnoredWhilePeerWindowStillOwnsSwipe() {
        let bounds = CGRect(x: 100, y: 0, width: 240, height: 50)
        let snapshots = [
            IslandWindowSnapshot(number: 99, ownerPID: 100, bounds: bounds, alpha: 1,
                                 level: NSWindow.Level.statusBar.rawValue + 4),
            IslandWindowSnapshot(number: 20, ownerPID: 200, bounds: bounds, alpha: 1,
                                 level: NSWindow.Level.statusBar.rawValue + 2),
            IslandWindowSnapshot(number: 10, ownerPID: 100, bounds: bounds, alpha: 1,
                                 level: NSWindow.Level.statusBar.rawValue + 1),
        ]
        XCTAssertEqual(IslandWindowOwnership.frontmostWindowNumber(
            overlapping: bounds, snapshots: snapshots, islandPIDs: [100, 200]), 20)
    }

    func testOrdinaryWindowAboveIslandIsNotIgnoredWithLinkedCanvas() {
        let bounds = CGRect(x: 100, y: 0, width: 240, height: 50)
        let canvas = IslandWindowSnapshot(number: 99, ownerPID: 100, bounds: bounds, alpha: 1,
                                         level: NSWindow.Level.statusBar.rawValue + 4)
        let overlay = IslandWindowSnapshot(number: 30, ownerPID: 100, bounds: bounds, alpha: 1,
                                          level: NSWindow.Level.statusBar.rawValue + 3)
        let island = IslandWindowSnapshot(number: 10, ownerPID: 100, bounds: bounds, alpha: 1,
                                         level: NSWindow.Level.statusBar.rawValue + 1)
        XCTAssertEqual(IslandWindowOwnership.frontmostWindowNumber(
            overlapping: bounds, snapshots: [canvas, overlay, island], islandPIDs: [100]), 30)
        XCTAssertNil(IslandWindowOwnership.frontmostWindowNumber(
            overlapping: bounds, snapshots: [canvas], islandPIDs: [100]))
    }

    func testGlobalSwipeRequiresVisibleCollapsedIslandUnderPointer() {
        let frame = CGRect(x: 100, y: 100, width: 240, height: 50)

        XCTAssertTrue(IslandWindowOwnership.canHandleGlobalSwipe(
            isVisible: true,
            isCollapsed: true,
            windowFrame: frame,
            mouseLocation: CGPoint(x: 120, y: 120)
        ))
        XCTAssertFalse(IslandWindowOwnership.canHandleGlobalSwipe(
            isVisible: false,
            isCollapsed: true,
            windowFrame: frame,
            mouseLocation: CGPoint(x: 120, y: 120)
        ))
        XCTAssertFalse(IslandWindowOwnership.canHandleGlobalSwipe(
            isVisible: true,
            isCollapsed: false,
            windowFrame: frame,
            mouseLocation: CGPoint(x: 120, y: 120)
        ))
        XCTAssertFalse(IslandWindowOwnership.canHandleGlobalSwipe(
            isVisible: true,
            isCollapsed: true,
            windowFrame: frame,
            mouseLocation: CGPoint(x: 20, y: 20)
        ))
    }
}
