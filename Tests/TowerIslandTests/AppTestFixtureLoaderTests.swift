import XCTest
@testable import XIsland

@MainActor
final class AppTestFixtureLoaderTests: XCTestCase {
    func testLoadsNamedPermissionFixtureIntoSessionManager() throws {
        let sessionManager = SessionManager()
        let updateManager = UpdateManager()

        _ = try AppTestFixtureLoader.load(
            named: "permission-smoke",
            into: sessionManager,
            updateManager: updateManager
        )

        XCTAssertEqual(sessionManager.sessions.count, 1)
        XCTAssertEqual(sessionManager.selectedSessionId, "fixture-permission")
        XCTAssertEqual(sessionManager.sessions[0].status, .waitingPermission)
        XCTAssertEqual(sessionManager.sessions[0].pendingPermission?.tool, "Bash")
        XCTAssertEqual(sessionManager.sessions[0].pendingPermission?.requestingAgent, .claudeCode)
        XCTAssertEqual(updateManager.state, .idle)
    }

    func testLoadsUpdateFixtureIntoUpdateManager() throws {
        let sessionManager = SessionManager()
        let updateManager = UpdateManager()

        _ = try AppTestFixtureLoader.load(
            named: "update-available",
            into: sessionManager,
            updateManager: updateManager
        )

        XCTAssertEqual(sessionManager.sessions.count, 0)
        XCTAssertEqual(updateManager.state, .updateAvailable(version: "1.2.9"))
        XCTAssertEqual(updateManager.latestRelease?.normalizedVersion, "1.2.9")
        XCTAssertEqual(
            updateManager.latestRelease?.dmgURL,
            URL(string: "https://example.com/XIsland-1.2.9.dmg")
        )
    }

    func testLoadsNamedFixtureFromStableBasePathWhenCurrentDirectoryChanges() throws {
        let sessionManager = SessionManager()
        let updateManager = UpdateManager()
        let originalDirectory = FileManager.default.currentDirectoryPath
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(originalDirectory)
        }

        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(temporaryDirectory.path))

        _ = try AppTestFixtureLoader.load(
            named: "permission-smoke",
            into: sessionManager,
            updateManager: updateManager
        )

        XCTAssertEqual(sessionManager.sessions.count, 1)
        XCTAssertEqual(sessionManager.selectedSessionId, "fixture-permission")
        XCTAssertEqual(sessionManager.sessions[0].status, .waitingPermission)
    }
}
