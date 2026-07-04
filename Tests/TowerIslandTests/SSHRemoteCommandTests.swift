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
}
