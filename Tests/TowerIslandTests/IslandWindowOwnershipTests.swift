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

    func testVisibleIslandWindowRecognizesItselfAsFrontmost() {
        let window = NotchWindow()
        window.level = .screenSaver
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

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
