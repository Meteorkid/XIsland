import AppKit
import XCTest
@testable import XIsland

final class IslandHandoffVisibilityTests: XCTestCase {
    private let sourcePID: pid_t = 100
    private let peerPID: pid_t = 200
    private let bundleIdentifier = "com.example.peer"

    func testBothKnownIslandLevelsAreVisibleAndFrontmost() {
        for levelOffset in [1, 2] {
            let windows = [window(pid: peerPID, layer: NSWindow.Level.statusBar.rawValue + levelOffset), window(pid: sourcePID)]
            XCTAssertTrue(isVisible(windows))
            XCTAssertTrue(isFrontmost(windows))
        }
    }

    func testSourceReclaimedFrontPreventsLateHideButStillRecognizesVisiblePeer() {
        let windows = [window(pid: sourcePID), window(pid: peerPID)]
        XCTAssertTrue(isVisible(windows))
        XCTAssertFalse(isFrontmost(windows))
    }

    func testHigherSourceLayerDoesNotPreventPendingVisibilityConfirmation() {
        let windows = [
            window(pid: sourcePID, layer: NSWindow.Level.statusBar.rawValue + 2),
            window(pid: peerPID, layer: NSWindow.Level.statusBar.rawValue + 1),
        ]
        XCTAssertTrue(isVisible(windows))
        XCTAssertFalse(isFrontmost(windows))
    }

    func testPeerIsAcceptedWhenSourceHasNoWindow() {
        XCTAssertTrue(isVisible([window(pid: peerPID)]))
        XCTAssertTrue(isFrontmost([window(pid: peerPID)]))
    }

    func testRunningPeerWithoutIslandWindowIsNotVisible() {
        XCTAssertFalse(isVisible([]))
        XCTAssertFalse(isFrontmost([]))
        XCTAssertFalse(isVisible([window(pid: sourcePID)]))
        XCTAssertFalse(isFrontmost([window(pid: sourcePID)]))
    }

    func testSettingsAndUnknownLayersAreRejected() {
        for layer in [0, NSWindow.Level.statusBar.rawValue, NSWindow.Level.statusBar.rawValue + 3] {
            XCTAssertFalse(isVisible([window(pid: peerPID, layer: layer)]))
            XCTAssertFalse(isFrontmost([window(pid: peerPID, layer: layer)]))
        }
        XCTAssertTrue(isFrontmost([window(pid: sourcePID, layer: 0), window(pid: peerPID)]))
    }

    func testTransparentAndOffscreenWindowsAreRejected() {
        let invalidWindows = [window(pid: peerPID, alpha: 0), window(pid: peerPID, onScreen: false)]
        for invalid in invalidWindows {
            XCTAssertFalse(isVisible([invalid]))
            XCTAssertFalse(isFrontmost([invalid]))
        }
        XCTAssertTrue(isFrontmost([window(pid: sourcePID, alpha: 0), window(pid: peerPID)]))
    }

    func testNonpositiveAndNonfiniteGeometryOrAlphaAreRejected() {
        for value: CGFloat in [0, -1, .nan, .infinity] {
            for invalid in [
                window(pid: peerPID, width: value),
                window(pid: peerPID, height: value),
                window(pid: peerPID, alpha: value),
            ] {
                XCTAssertFalse(isVisible([invalid]))
                XCTAssertFalse(isFrontmost([invalid]))
            }
        }
    }

    func testMissingRequiredMetadataFailsClosed() {
        for key in [kCGWindowOwnerPID, kCGWindowLayer, kCGWindowIsOnscreen, kCGWindowAlpha, kCGWindowBounds] {
            var invalid = window(pid: peerPID)
            invalid.removeValue(forKey: key as String)
            XCTAssertFalse(isVisible([invalid]))
            XCTAssertFalse(isFrontmost([invalid]))
        }
        for key in ["Width", "Height"] {
            var invalid = window(pid: peerPID)
            var bounds = invalid[kCGWindowBounds as String] as! [String: CGFloat]
            bounds.removeValue(forKey: key)
            invalid[kCGWindowBounds as String] = bounds
            XCTAssertFalse(isVisible([invalid]))
            XCTAssertFalse(isFrontmost([invalid]))
        }
    }

    func testCoreGraphicsBridgedNumbersAreAcceptedWithoutWindowNames() {
        let info: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: peerPID),
            kCGWindowLayer as String: NSNumber(value: NSWindow.Level.statusBar.rawValue + 1),
            kCGWindowAlpha as String: NSNumber(value: 0.5),
            kCGWindowIsOnscreen as String: NSNumber(value: true),
            kCGWindowBounds as String: [
                "X": NSNumber(value: 100), "Y": NSNumber(value: 0),
                "Width": NSNumber(value: 240), "Height": NSNumber(value: 50),
            ] as NSDictionary,
        ]
        XCTAssertTrue(isVisible([info]))
        XCTAssertTrue(isFrontmost([info]))
    }

    func testUnrelatedWindowsDoNotOwnTheHandoff() {
        XCTAssertTrue(isFrontmost([window(pid: 999), window(pid: peerPID), window(pid: sourcePID)]))
        XCTAssertFalse(isVisible([window(pid: 999)]))
        XCTAssertFalse(isFrontmost([window(pid: 999)]))
    }

    func testSourceCannotMatchItselfAsPeer() {
        let windows = [window(pid: sourcePID)]
        XCTAssertFalse(IslandHandoffVisibility.isPeerVisible(windowList: windows, peerPIDs: [sourcePID], sourcePID: sourcePID))
        XCTAssertFalse(IslandHandoffVisibility.isPeerFrontmost(windowList: windows, peerPIDs: [sourcePID], sourcePID: sourcePID))
    }

    func testExpectedApplicationPathExcludesOtherCopiesWithSameBundleIdentifier() {
        let expectedURL = URL(fileURLWithPath: "/Applications/Peer.app")
        let peerPIDs = IslandHandoffVisibility.peerProcessIdentifiers(
            bundleIdentifier: bundleIdentifier,
            applicationURL: expectedURL,
            applications: [
                application(pid: peerPID, path: expectedURL.path),
                application(pid: 201, path: "/tmp/Peer.app"),
                application(pid: 202, path: nil),
                .init(processIdentifier: 203, bundleIdentifier: "com.example.other", applicationURL: expectedURL),
                application(pid: 204, path: "/Applications/Old/../Peer.app"),
            ]
        )
        XCTAssertEqual(peerPIDs, [peerPID, 204])
        let windows = [window(pid: 201), window(pid: sourcePID), window(pid: peerPID)]
        XCTAssertFalse(IslandHandoffVisibility.isPeerFrontmost(windowList: windows, peerPIDs: peerPIDs, sourcePID: sourcePID))
        XCTAssertTrue(IslandHandoffVisibility.isPeerVisible(windowList: windows, peerPIDs: peerPIDs, sourcePID: sourcePID))
        XCTAssertFalse(IslandHandoffVisibility.isPeerVisible(windowList: [window(pid: 201)], peerPIDs: peerPIDs, sourcePID: sourcePID))
    }

    func testUnknownApplicationPathAllowsAllInstancesOfOnlyTheExpectedBundle() {
        let peerPIDs = IslandHandoffVisibility.peerProcessIdentifiers(
            bundleIdentifier: bundleIdentifier,
            applicationURL: nil,
            applications: [
                application(pid: peerPID, path: "/Applications/Peer.app"),
                application(pid: 201, path: "/tmp/Peer.app"),
                application(pid: 202, path: nil),
                .init(processIdentifier: 203, bundleIdentifier: nil, applicationURL: nil),
                .init(processIdentifier: 204, bundleIdentifier: "com.example.other", applicationURL: nil),
                application(pid: 0, path: nil),
            ]
        )
        XCTAssertEqual(peerPIDs, [peerPID, 201, 202])
        XCTAssertTrue(IslandHandoffVisibility.isPeerFrontmost(windowList: [window(pid: 201)], peerPIDs: peerPIDs, sourcePID: sourcePID))
    }

    func testNonFileApplicationURLCannotMatchLocalInstallation() {
        XCTAssertTrue(IslandHandoffVisibility.peerProcessIdentifiers(
            bundleIdentifier: bundleIdentifier,
            applicationURL: URL(string: "https://example.com/Applications/Peer.app"),
            applications: [application(pid: peerPID, path: "/Applications/Peer.app")]
        ).isEmpty)
    }

    private func isVisible(_ windows: [[String: Any]]) -> Bool {
        IslandHandoffVisibility.isPeerVisible(windowList: windows, peerPIDs: [peerPID], sourcePID: sourcePID)
    }

    private func isFrontmost(_ windows: [[String: Any]]) -> Bool {
        IslandHandoffVisibility.isPeerFrontmost(windowList: windows, peerPIDs: [peerPID], sourcePID: sourcePID)
    }

    private func application(pid: pid_t, path: String?) -> IslandHandoffVisibility.RunningApplication {
        .init(processIdentifier: pid, bundleIdentifier: bundleIdentifier, applicationURL: path.map { URL(fileURLWithPath: $0) })
    }

    private func window(
        pid: pid_t,
        layer: Int = NSWindow.Level.statusBar.rawValue + 1,
        alpha: CGFloat = 1,
        onScreen: Bool = true,
        width: CGFloat = 240,
        height: CGFloat = 50
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowIsOnscreen as String: onScreen,
            kCGWindowBounds as String: ["X": CGFloat(100), "Y": CGFloat(0), "Width": width, "Height": height],
        ]
    }
}
