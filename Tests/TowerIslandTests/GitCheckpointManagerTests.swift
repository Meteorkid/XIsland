import XCTest
@testable import XIsland

final class GitCheckpointManagerTests: XCTestCase {
    func testCreateCheckpointReturnsNilOutsideGitRepo() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nogit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = AgentSession(
            id: "s",
            agentType: .claudeCode,
            workingDirectory: dir.path
        )
        XCTAssertNil(GitCheckpointManager.createCheckpoint(for: session))
    }

    func testGitCheckpointHoldsMessage() {
        let cp = GitCheckpoint(timestamp: Date(), hash: "abcd1234", message: "test stash")
        XCTAssertEqual(cp.message, "test stash")
        XCTAssertEqual(cp.hash, "abcd1234")
    }
}
