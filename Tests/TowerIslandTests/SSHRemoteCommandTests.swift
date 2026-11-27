import XCTest
import DIShared
@testable import XIsland

final class SSHRemoteCommandTests: XCTestCase {
    func testLocalTunnelSocketLivesUnderXislandDir() {
        let server = SSHRemoteServer(label: "prod", host: "example.com", port: 2222, user: "deploy")
        XCTAssertTrue(server.localTunnelSocket.hasPrefix(DISocketConfig.socketDir))
        XCTAssertTrue(server.localTunnelSocket.hasSuffix(".sock"))
        XCTAssertTrue(server.localTunnelSocket.contains("prod"))
    }

    func testRemoteServersWithSameLabelStillHaveDistinctLocalSockets() {
        let a = SSHRemoteServer(label: "same", host: "h1", user: "u")
        let b = SSHRemoteServer(label: "same", host: "h1", user: "u")
        XCTAssertNotEqual(a.localTunnelSocket, b.localTunnelSocket)
    }

    func testSocketLabelIsSanitizedForSocketPaths() {
        let server = SSHRemoteServer(label: "../prod env", host: "example.com", user: "deploy")

        XCTAssertFalse(server.localTunnelSocket.contains("../"))
        XCTAssertFalse(server.localTunnelSocket.contains(" "))
        XCTAssertTrue(server.localTunnelSocket.contains("prod_env"))
    }

    func testRemoteHookUsesRemoteTunnelSocketOverride() {
        let manager = SSHRemoteManager()
        let server = SSHRemoteServer(label: "prod", host: "example.com", user: "deploy")
        let command = manager.remoteHookSetupCommand(for: server)

        XCTAssertTrue(command.contains("export DI_SOCKET_PATH=/tmp/xisland-deploy-di-remote-"))
        XCTAssertTrue(command.contains("--agent claude_code --hook"))
        XCTAssertFalse(command.contains("export DI_SOCKET_PATH=\(DISocketConfig.socketPath)"))
    }

    func testDefaultRemoteBridgePathStaysRemoteRelative() {
        let server = SSHRemoteServer(label: "prod", host: "example.com", user: "deploy")

        XCTAssertEqual(server.remoteBridgePath, "~/.xisland/bin/di-bridge")
    }

    func testRegexCompilationFailsClosedInsteadOfCrashingOnMalformedPattern() {
        XCTAssertNil(SSHInputValidator.compilePattern("[unterminated"))
        XCTAssertFalse(SSHInputValidator.matches("example.com", regex: nil))
    }

    func testSSHValidatorRejectsShellMetacharacters() {
        XCTAssertThrowsError(try SSHInputValidator.validateHost("example.com; rm -rf /"))
        XCTAssertThrowsError(try SSHInputValidator.validateUser("deploy$(whoami)"))
        XCTAssertThrowsError(try SSHInputValidator.validateRemotePath("~/bridge; touch /tmp/pwned", label: "bridge"))
    }

    func testSSHValidatorAcceptsExpectedValues() throws {
        XCTAssertEqual(try SSHInputValidator.validateHost("example.com"), "example.com")
        XCTAssertEqual(try SSHInputValidator.validateUser("deploy-user"), "deploy-user")
        XCTAssertEqual(try SSHInputValidator.validateRemotePath(" ~/.xisland/bin/di-bridge ", label: "bridge"),
                       "~/.xisland/bin/di-bridge")
    }
}
