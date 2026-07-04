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
