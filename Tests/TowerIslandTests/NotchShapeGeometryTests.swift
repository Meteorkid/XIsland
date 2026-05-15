import XCTest
@testable import XIsland

final class NotchShapeGeometryTests: XCTestCase {
    func testExpandedStateKeepsTopEdgeFlat() {
        XCTAssertEqual(NotchShapeGeometry.topCornerRadius(state: .expanded), 0)
        XCTAssertEqual(NotchShapeGeometry.topCornerRadius(state: .permission("p")), 0)
        XCTAssertEqual(NotchShapeGeometry.topCornerRadius(state: .question("q")), 0)
        XCTAssertEqual(NotchShapeGeometry.topCornerRadius(state: .planReview("r")), 0)
    }

    func testCollapsedStateKeepsTopEdgeFlat() {
        XCTAssertEqual(NotchShapeGeometry.topCornerRadius(state: .collapsed), 0)
    }

    func testBottomCornerStillOpensTowardExpandedRadius() {
        XCTAssertEqual(NotchShapeGeometry.bottomCornerRadius(openProgress: 0), 17)
        XCTAssertEqual(NotchShapeGeometry.bottomCornerRadius(openProgress: 1), 22)
    }
}
