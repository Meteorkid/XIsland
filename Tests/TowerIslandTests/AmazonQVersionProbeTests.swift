import XCTest
@testable import DIBridge

final class AmazonQVersionProbeTests: XCTestCase {
    func testRequiresTheVerifiedChatBinaryAndExactRelease() {
        XCTAssertTrue(AmazonQVersionProbe.supports("qchat 1.19.7\n"))
        for value in ["q 1.19.7", "kiro-cli 1.19.7", "qchat 1.19.70", "qchat 1.20.0", "qchat 1.19.7\nextra"] {
            XCTAssertFalse(AmazonQVersionProbe.supports(value))
        }
    }

    func testProbeRejectsMissingExecutableAndInvalidDeadline() {
        XCTAssertFalse(AmazonQVersionProbe.verify(executable: "/missing/xisland-q", environment: [:]))
        XCTAssertFalse(AmazonQVersionProbe.verify(executable: "/bin/sh", environment: [:], timeout: .nan))
    }
}
