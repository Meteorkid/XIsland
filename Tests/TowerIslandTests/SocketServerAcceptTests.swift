import XCTest
@testable import XIsland

final class SocketServerAcceptTests: XCTestCase {
    func testAcceptFailureBackoffIsNonZero() {
        XCTAssertEqual(SocketServer.acceptFailureBackoffMicroseconds, 50_000)
    }
}
