import XCTest
@testable import XIsland

@MainActor
final class IslandAttentionEpochTests: XCTestCase {
    func testQueuedRequestIsRejectedButNewManualRequestIsAccepted() throws {
        try withStore { store, _ in
            let oldURL = try XCTUnwrap(IslandAttentionEpoch.adding(store.capture(), to: showURL))
            XCTAssertNotNil(store.admission(for: oldURL))
            XCTAssertTrue(store.advance())
            XCTAssertNil(store.admission(for: oldURL))
            let nextURL = try XCTUnwrap(IslandAttentionEpoch.adding(store.capture(), to: showURL))
            XCTAssertNotNil(store.admission(for: nextURL))
        }
    }

    func testAdmittedPreparationIsInvalidatedBeforeItsCallback() throws {
        try withStore { store, _ in
            let admission = try XCTUnwrap(store.admission(for: showURL))
            XCTAssertTrue(store.isCurrent(admission))
            XCTAssertTrue(store.advance())
            XCTAssertFalse(store.isCurrent(admission))
            XCTAssertTrue(store.isCurrent(try XCTUnwrap(store.admission(for: showURL))))
        }
    }

    func testSeparateDefaultsInstancesRefreshTheSameBarrier() throws {
        try withStore { writer, suite in
            let reader = IslandAttentionEpoch.Store(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
                                                    bootSession: { "test-boot" }, uptime: { 100 })
            let before = reader.capture()
            XCTAssertTrue(writer.advance())
            XCTAssertFalse(reader.isCurrent(before))
            XCTAssertEqual(reader.capture(), writer.capture())
        }
    }

    func testLegacyDirectionalRequestsRespectBarrierAndPlainLinksRemainCompatible() throws {
        try withStore { store, _ in
            let old = IslandSwitchMotion(direction: .left, reduceMotion: true, issuedUptime: 99)
            let oldURL = try XCTUnwrap(old.adding(to: showURL))
            XCTAssertNotNil(store.admission(for: oldURL, motion: old))
            XCTAssertTrue(store.advance())
            XCTAssertNil(store.admission(for: oldURL, motion: old))
            let newer = IslandSwitchMotion(direction: .left, reduceMotion: true, issuedUptime: 101)
            XCTAssertNotNil(store.admission(for: showURL, motion: newer))
            XCTAssertNotNil(store.admission(for: showURL))
        }
    }

    func testBarrierDoesNotExpireInTheSameBootAndOldBootDoesNotSuppressLegacyRequests() throws {
        try withStore { store, _ in
            let old = store.capture()
            XCTAssertTrue(store.advance())
            let later = IslandAttentionEpoch.Store(defaults: store.defaults, bootSession: { "test-boot" }, uptime: { 10_000 })
            XCTAssertFalse(later.isCurrent(old))
            let rebooted = IslandAttentionEpoch.Store(defaults: store.defaults, bootSession: { "new-boot" }, uptime: { 10 })
            XCTAssertEqual(rebooted.capture(), old)
            XCTAssertNotNil(rebooted.admission(for: showURL,
                motion: .init(direction: .left, reduceMotion: true, issuedUptime: 9)))
        }
    }

    func testMalformedUntrustedEpochNeverDowngradesToLegacy() throws {
        try withStore { store, _ in
            let id = store.capture().id.uuidString
            for query in [
                "attentionEpoch=\(id)", "attentionVersion=1", "attentionVersion=2&attentionEpoch=\(id)",
                "attentionVersion=1&attentionEpoch=bad", "attentionVersion=1&attentionEpoch",
                "attentionVersion=1&attentionEpoch=\(id)&attentionEpoch=\(id)",
                "attentionVersion=1&attentionEpoch=\(id)&attentionUnknown=x",
                "attentionVersion=1&attentionVersion=1&attentionEpoch=\(id)",
            ] {
                XCTAssertNil(store.admission(for: try XCTUnwrap(URL(string: showURL.absoluteString + "?" + query))), query)
            }
            let stamped = try XCTUnwrap(IslandAttentionEpoch.adding(store.capture(), to: showURL))
            XCTAssertNil(IslandAttentionEpoch.adding(store.capture(), to: stamped))
        }
    }

    func testOutboundPlainAndDirectionalURLsBothCarryEpoch() throws {
        try withStore { store, _ in
            for direction in [nil, SwipeDirection.left] {
                let state = SwitchState()
                let switcher = makeSwitcher(store: store, state: state)
                switcher.switchToIsland(named: peerName(switcher), direction: direction)
                let url = try XCTUnwrap(state.urls.first)
                XCTAssertEqual(store.admission(for: url), store.capture())
                XCTAssertTrue(url.absoluteString.contains("attentionEpoch="))
                XCTAssertEqual(try IslandSwitchMotion.decode(url: url)?.direction, direction)
            }
        }
    }

    func testSupersededOpenFailureAndTimeoutNeverRestoreSource() throws {
        try withStore { store, _ in
            for useTimeout in [false, true] {
                let state = SwitchState()
                let switcher = makeSwitcher(store: store, state: state)
                switcher.switchToIsland(named: peerName(switcher))
                XCTAssertTrue(store.advance())
                if useTimeout { try XCTUnwrap(state.scheduled.first)() }
                else { try XCTUnwrap(state.openCompletion)(false) }
                XCTAssertEqual(state.restores, 0)
                XCTAssertEqual(state.hides, 0)
                XCTAssertFalse(state.switching)
                XCTAssertFalse(switcher.isSwitchInProgress)
            }
        }
    }

    func testSupersededVisiblePollDoesNotHidePriorityIsland() throws {
        try withStore { store, _ in
            let state = SwitchState()
            let switcher = makeSwitcher(store: store, state: state)
            switcher.switchToIsland(named: peerName(switcher))
            try XCTUnwrap(state.openCompletion)(true)
            XCTAssertEqual(state.scheduled.count, 2)
            XCTAssertTrue(store.advance())
            state.peerVisible = true
            state.scheduled[1]()
            XCTAssertEqual(state.hides, 0)
            XCTAssertEqual(state.restores, 0)
            XCTAssertFalse(switcher.isSwitchInProgress)
        }
    }

    private var showURL: URL { URL(string: "xnook://xnook/show")! }

    private func peerName(_ switcher: AppSwitcher) -> String {
        switcher.currentAppName == "xisland" ? "xnook" : "xisland"
    }

    private func withStore(_ body: (IslandAttentionEpoch.Store, String) throws -> Void) throws {
        let suite = "IslandAttentionEpochTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(.init(defaults: defaults, bootSession: { "test-boot" }, uptime: { 100 }), suite)
    }

    private final class SwitchState {
        var urls: [URL] = []
        var openCompletion: (@MainActor (Bool) -> Void)?
        var scheduled: [@MainActor () -> Void] = []
        var switching = false
        var peerVisible = false
        var hides = 0
        var restores = 0
    }

    private func makeSwitcher(store: IslandAttentionEpoch.Store, state: SwitchState) -> AppSwitcher {
        AppSwitcher(environment: .init(
            applicationURL: { _ in URL(fileURLWithPath: "/Fixture/Peer.app") },
            open: { url, _, done in state.urls.append(url); state.openCompletion = done },
            isVisible: { _ in state.peerVisible }, isFrontmost: { _ in false },
            setSwitching: { state.switching = $0 }, hideSource: { state.hides += 1 },
            restoreSource: { state.restores += 1 },
            schedule: { _, work in state.scheduled.append(work); return {} },
            uptime: { 100 }, captureAttentionEpoch: { store.capture() },
            isAttentionEpochCurrent: { store.isCurrent($0) }
        ))
    }
}
