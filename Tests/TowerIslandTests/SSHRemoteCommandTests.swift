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
}
