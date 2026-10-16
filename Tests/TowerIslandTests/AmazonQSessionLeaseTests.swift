import XCTest
@testable import DIBridge

final class AmazonQSessionLeaseTests: XCTestCase {
    func testWrongProcessGenerationAndSymlinkAreRejected() throws {
        let lease = try AmazonQSessionLease(socketPath: "/tmp/fixture.sock")
        try lease.activate()
        let link = URL(fileURLWithPath: lease.path).deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: lease.path)
        XCTAssertThrowsError(try AmazonQSessionLease.withActiveState(at: link.path) { _ in XCTFail() })
        let url = URL(fileURLWithPath: lease.path)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["ownerStart"] = "0:0"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try AmazonQSessionLease.withActiveState(at: lease.path) { _ in XCTFail() })
    }

    func testContendedCallbackFailsPromptlyAndEndRevokesPath() throws {
        let lease = try AmazonQSessionLease(socketPath: "/tmp/fixture.sock")
        try lease.activate()
        try AmazonQSessionLease.withActiveState(at: lease.path) { _ in
            XCTAssertThrowsError(try AmazonQSessionLease.withActiveState(at: lease.path) { _ in XCTFail() })
            XCTAssertThrowsError(try lease.end())
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.path))
        XCTAssertThrowsError(try AmazonQSessionLease.withActiveState(at: lease.path) { _ in XCTFail() })
    }

    func testOnlyActiveLeaseCanEmitAndLateCallbacksAreRejected() throws {
        let lease = try AmazonQSessionLease(socketPath: "/tmp/fixture.sock")
        XCTAssertThrowsError(try AmazonQSessionLease.withActiveState(at: lease.path) { _ in XCTFail() })
        try lease.activate()
        var calls = 0
        try AmazonQSessionLease.withActiveState(at: lease.path) { state in
            calls += 1
            XCTAssertEqual(state.socketPath, "/tmp/fixture.sock")
            XCTAssertNotNil(UUID(uuidString: state.id))
        }
        try lease.end()
        XCTAssertThrowsError(try AmazonQSessionLease.withActiveState(at: lease.path) { _ in calls += 1 })
        XCTAssertEqual(calls, 1)
    }

    func testIndependentLeasesAndPrivateFilePermissions() throws {
        let first = try AmazonQSessionLease(socketPath: "/tmp/fixture.sock")
        let second = try AmazonQSessionLease(socketPath: "/tmp/fixture.sock")
        try first.activate(); try second.activate()
        var firstID = "", secondID = ""
        try AmazonQSessionLease.withActiveState(at: first.path) { firstID = $0.id }
        try AmazonQSessionLease.withActiveState(at: second.path) { secondID = $0.id }
        XCTAssertNotEqual(firstID, secondID)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: first.path)
        XCTAssertThrowsError(try AmazonQSessionLease.withActiveState(at: first.path) { _ in XCTFail() })
    }
}
