import AppKit
import QuartzCore
import XCTest
@testable import XIsland

private func geometryFixture(
    frame: CGRect = CGRect(x: 700, y: 900, width: 270, height: 40), displayID: UInt32 = 1
) -> IslandSwitchGeometry {
    IslandSwitchGeometry(frame: frame, displayID: displayID, topRadius: 8, bottomRadius: 18,
                         fill: IslandSwitchColor(red: 0.08, green: 0.12, blue: 0.16, alpha: 0.95))!
}

@MainActor
final class IslandSwitchMotionTests: XCTestCase {
    func testURLAndNotificationRoundTripPreserveIdentityDirectionAndClock() throws {
        for direction in [SwipeDirection.left, .right] {
            let request = IslandSwitchMotion(direction: direction, reduceMotion: false, issuedUptime: 100)
            let url = try XCTUnwrap(request.adding(to: URL(string: "xnook://xnook/show")!))
            XCTAssertEqual(try IslandSwitchMotion.decode(url: url), request)
            let ready = request.starting(at: 100.05, reduceMotion: true)
            XCTAssertEqual(try IslandSwitchMotion.decode(userInfo: ready.userInfo), ready)
            XCTAssertEqual(url.path, "/show")
            XCTAssertTrue(ready.reduceMotion)
            XCTAssertTrue(ready.isTimely(at: 100))
            XCTAssertFalse(ready.isTimely(at: 102))
        }
    }

    func testLegacyShowAndNoticeHaveNoDirectionalMotion() throws {
        XCTAssertNil(try IslandSwitchMotion.decode(url: URL(string: "xnook://xnook/show")!))
        XCTAssertNil(try IslandSwitchMotion.decode(userInfo: ["source": "xisland", "shownAt": 10.0]))
    }

    func testMalformedPartialDuplicateAndNonfiniteMetadataIsRejected() throws {
        let request = IslandSwitchMotion(direction: .left, reduceMotion: false, issuedUptime: 100)
        let url = try XCTUnwrap(request.adding(to: URL(string: "xnook://xnook/show")!))
        XCTAssertThrowsError(try IslandSwitchMotion.decode(url: URL(string: url.absoluteString + "&slideDirection=right")!))
        XCTAssertThrowsError(try IslandSwitchMotion.decode(url: URL(string: "xnook://xnook/show?slideDirection=left")!))
        for (key, value) in [("slideVersion", "2"), ("handoffID", "bad"), ("slideDirection", "up"),
                             ("slideReduceMotion", "false"), ("slideIssuedAt", "nan"), ("slideStartAt", "99")] {
            var info = request.userInfo; info[key] = value
            XCTAssertThrowsError(try IslandSwitchMotion.decode(userInfo: info), key)
        }
        XCTAssertThrowsError(try IslandSwitchMotion.decode(userInfo: ["slideVersion": 1]))
        XCTAssertFalse(IslandSwitchMotion(direction: .left, reduceMotion: false, issuedUptime: 120).isTimely(at: 100))
    }

    func testOptionalSourceAndTargetGeometryRoundTripThroughURLAndNotice() throws {
        let source = geometryFixture(frame: CGRect(x: -1500, y: -900, width: 270, height: 40), displayID: 2)
        let target = geometryFixture(frame: CGRect(x: 720, y: 960, width: 340, height: 44))
        let combinations: [(IslandSwitchGeometry?, IslandSwitchGeometry?)] = [
            (nil, nil), (source, nil), (nil, target), (source, target),
        ]
        for (sourceGeometry, targetGeometry) in combinations {
            let motion = IslandSwitchMotion(direction: .right, reduceMotion: false, issuedUptime: 100,
                                            sourceGeometry: sourceGeometry, targetGeometry: targetGeometry)
            let url = try XCTUnwrap(motion.adding(to: URL(string: "xnook://xnook/show")!))
            XCTAssertEqual(try IslandSwitchMotion.decode(url: url), motion)
            XCTAssertEqual(try IslandSwitchMotion.decode(userInfo: motion.userInfo), motion)
        }
    }

    func testArrivalAndSharedStartPreserveSourceGeometry() {
        let source = geometryFixture()
        let target = geometryFixture(frame: CGRect(x: 700, y: 800, width: 320, height: 48))
        let request = IslandSwitchMotion(direction: .left, reduceMotion: false, issuedUptime: 100,
                                         sourceGeometry: source)
        let ready = request.arriving(at: target).starting(at: 100.05, reduceMotion: true)
        XCTAssertEqual(ready.requestID, request.requestID)
        XCTAssertEqual(ready.issuedUptime, request.issuedUptime)
        XCTAssertEqual(ready.sourceGeometry, source)
        XCTAssertEqual(ready.targetGeometry, target)
        XCTAssertTrue(ready.reduceMotion)
        XCTAssertEqual(ready.arriving(at: nil).sourceGeometry, source)
        XCTAssertNil(ready.arriving(at: nil).targetGeometry)
    }

    func testGeometryFieldsAreAllOrNoneAndDuplicateURLFieldsAreRejected() throws {
        let motion = IslandSwitchMotion(direction: .left, reduceMotion: false, issuedUptime: 100,
                                         sourceGeometry: geometryFixture(), targetGeometry: geometryFixture())
        for prefix in ["slideSource", "slideTarget"] {
            for key in motion.userInfo.keys.filter({ $0.hasPrefix(prefix) }) {
                var partial = motion.userInfo
                partial.removeValue(forKey: key)
                XCTAssertThrowsError(try IslandSwitchMotion.decode(userInfo: partial), key)
            }
        }
        let url = try XCTUnwrap(motion.adding(to: URL(string: "xnook://xnook/show")!))
        XCTAssertThrowsError(try IslandSwitchMotion.decode(url: URL(string: url.absoluteString + "&slideSourceWidth=280")!))
        XCTAssertThrowsError(try IslandSwitchMotion.decode(url: URL(string: "xnook://xnook/show?slideSourceWidth=280")!))
        XCTAssertNil(motion.adding(to: URL(string: "xnook://xnook/show?slideTargetWidth=280")!))
    }

    func testNonfiniteAndOutOfBoundsGeometryMetadataIsRejected() {
        let motion = IslandSwitchMotion(direction: .left, reduceMotion: false, issuedUptime: 100,
                                         sourceGeometry: geometryFixture(), targetGeometry: geometryFixture())
        let invalidValues = [
            ("X", "nan"), ("Y", "inf"), ("X", "100001"), ("Y", "-100001"),
            ("Width", "0"), ("Width", "-1"), ("Width", "4097"), ("Height", "2049"),
            ("DisplayID", "0"), ("DisplayID", "4294967296"),
            ("TopRadius", "-1"), ("BottomRadius", "41"), ("TopRadius", "nan"),
            ("Red", "1.1"), ("Green", "-0.1"), ("Blue", "nan"), ("Alpha", "2"),
        ]
        for prefix in ["slideSource", "slideTarget"] {
            for (suffix, value) in invalidValues {
                var malformed = motion.userInfo
                malformed[prefix + suffix] = value
                XCTAssertThrowsError(try IslandSwitchMotion.decode(userInfo: malformed), prefix + suffix)
            }
        }
        var nonString: [AnyHashable: Any] = motion.userInfo
        nonString["slideSourceWidth"] = 270
        XCTAssertThrowsError(try IslandSwitchMotion.decode(userInfo: nonString))
    }

    func testGeometryInitializerRejectsInvalidFramesRadiiAndColors() {
        let fill = IslandSwitchColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9)
        XCTAssertTrue(geometryFixture().isValid)
        XCTAssertNil(IslandSwitchGeometry(frame: CGRect(x: 0, y: 0, width: 0, height: 40), displayID: 1,
                                          topRadius: 8, bottomRadius: 18, fill: fill))
        XCTAssertNil(IslandSwitchGeometry(frame: CGRect(x: CGFloat.infinity, y: 0, width: 270, height: 40), displayID: 1,
                                          topRadius: 8, bottomRadius: 18, fill: fill))
        XCTAssertNil(IslandSwitchGeometry(frame: CGRect(x: 0, y: 0, width: 270, height: 40), displayID: 1,
                                          topRadius: 41, bottomRadius: 18, fill: fill))
        XCTAssertNil(IslandSwitchGeometry(frame: CGRect(x: 0, y: 0, width: 270, height: 40), displayID: 1,
                                          topRadius: 8, bottomRadius: 18,
                                          fill: IslandSwitchColor(red: 0, green: 0, blue: 0, alpha: .nan)))
    }

    func testAdaptivePreviewIsContinuousBoundedAndSymmetric() {
        for width: CGFloat in [80, 270, 600] {
            XCTAssertEqual(IslandSlideAnimator.previewOffset(translation: 0, width: width), 0)
            XCTAssertLessThan(IslandSlideAnimator.previewOffset(translation: 30, width: width), width * 0.32)
            XCTAssertEqual(IslandSlideAnimator.previewOffset(translation: -30, width: width),
                           -IslandSlideAnimator.previewOffset(translation: 30, width: width), accuracy: 0.0001)
            XCTAssertLessThanOrEqual(IslandSlideAnimator.previewOffset(translation: 100000, width: width), width * 0.32)
        }
        XCTAssertEqual(IslandSlideAnimator.previewOffset(translation: .nan, width: 200), 0)
        XCTAssertEqual(IslandSlideAnimator.previewOffset(translation: 30, width: .infinity), 0)
    }

    func testAnimatorUsesOneSharedStartAndMatchingChildDurations() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 60))
        let animator = IslandSlideAnimator(viewProvider: { view })
        let motion = IslandSwitchMotion(direction: .left, reduceMotion: false,
            startUptime: ProcessInfo.processInfo.systemUptime + 0.05)
        animator.animateIncoming(motion: motion, reduceMotion: false, completion: {})
        let group = try XCTUnwrap(view.layer?.animation(forKey: "island.directional-switch") as? CAAnimationGroup)
        XCTAssertEqual(group.duration, 0.28)
        XCTAssertEqual(group.animations?.count, 2)
        for child in group.animations ?? [] { XCTAssertEqual(child.duration, group.duration) }
        let position = try XCTUnwrap(group.animations?.first as? CABasicAnimation)
        XCTAssertEqual((position.fromValue as? NSNumber)?.doubleValue, 270)
        XCTAssertEqual((position.toValue as? NSNumber)?.doubleValue, 0)
        animator.reset()
    }

    func testNewPreviewContinuesCurrentPoseAndDoesNotAccumulateBaseEachFrame() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 60))
        view.wantsLayer = true
        view.layer?.setValue(20, forKeyPath: "transform.translation.x")
        let animator = IslandSlideAnimator(viewProvider: { view })
        animator.preview(translation: -2, width: 270, reduceMotion: false)
        XCTAssertEqual(try XCTUnwrap(view.layer?.value(forKeyPath: "transform.translation.x") as? NSNumber).doubleValue,
                       Double(20 + IslandSlideAnimator.previewOffset(translation: -2, width: 270)), accuracy: 0.001)
        animator.preview(translation: -4, width: 270, reduceMotion: false)
        XCTAssertEqual(try XCTUnwrap(view.layer?.value(forKeyPath: "transform.translation.x") as? NSNumber).doubleValue,
                       Double(20 + IslandSlideAnimator.previewOffset(translation: -4, width: 270)), accuracy: 0.001)
        animator.returnToRest(reduceMotion: true)
        animator.preview(translation: -2, width: 270, reduceMotion: false)
        XCTAssertLessThan(try XCTUnwrap(view.layer?.value(forKeyPath: "transform.translation.x") as? NSNumber).doubleValue, 0)
        animator.reset()
    }

    func testReducedMotionHasNoPreviewOrAnimatedWait() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 60))
        let animator = IslandSlideAnimator(viewProvider: { view })
        animator.preview(translation: 40, width: 270, reduceMotion: false)
        animator.preview(translation: 40, width: 270, reduceMotion: true)
        XCTAssertEqual((view.layer?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue, 0)
        var completed = false
        animator.animateIncoming(motion: IslandSwitchMotion(direction: .right, reduceMotion: true),
                                  reduceMotion: false) { completed = true }
        XCTAssertTrue(completed)
        XCTAssertNil(view.layer?.animation(forKey: "island.directional-switch"))
        XCTAssertEqual(view.layer?.opacity, 1)
    }

    func testResetInvalidatesOldAnimationCompletion() async {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 60))
        let animator = IslandSlideAnimator(viewProvider: { view })
        var completions = 0
        animator.animateOutgoing(motion: nil, reduceMotion: false) { completions += 1 }
        animator.reset()
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(view.layer?.opacity, 1)
    }
}

@MainActor
final class DirectionalSwitchTransactionTests: XCTestCase {
    @MainActor private final class State {
        struct Work { var delay: TimeInterval; var cancelled = false; let action: @MainActor () -> Void }
        var url: URL?
        var opened: (@MainActor (Bool) -> Void)?
        var visible = false
        var reduced = false
        var switching = false
        var hides: [IslandSwitchMotion?] = []
        var restores = 0
        var cancelledPreviews = 0
        var work: [Work] = []
        var now: TimeInterval = 100
        var sourceGeometry: IslandSwitchGeometry?
        func fire(_ delay: TimeInterval) {
            guard let index = work.firstIndex(where: { !$0.cancelled && $0.delay == delay }) else { return }
            work[index].cancelled = true
            work[index].action()
        }
    }

    private func fixture() -> (AppSwitcher, State, String) {
        let state = State()
        let switcher = AppSwitcher(environment: .init(
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Fixture.app") },
            open: { url, _, done in state.url = url; state.opened = done },
            isVisible: { _ in state.visible }, isFrontmost: { _ in state.visible },
            setSwitching: { state.switching = $0 }, hideSource: { state.hides.append(nil) },
            restoreSource: { state.restores += 1 },
            schedule: { delay, action in
                let index = state.work.count; state.work.append(.init(delay: delay, action: action))
                return { state.work[index].cancelled = true }
            }, hideSourceWithMotion: { state.hides.append($0) },
            cancelPreview: { state.cancelledPreviews += 1 }, reduceMotion: { state.reduced }, uptime: { state.now },
            sourceGeometry: { state.sourceGeometry }))
        return (switcher, state, switcher.currentAppName == "xnook" ? "xisland" : "xnook")
    }

    func testDirectionSurvivesURLAndMatchingVisibleAcknowledgement() throws {
        for direction in [SwipeDirection.left, .right] {
            let (switcher, state, peer) = fixture()
            switcher.switchToNextIsland(direction: direction)
            let motion = try XCTUnwrap(try IslandSwitchMotion.decode(url: XCTUnwrap(state.url)))
            XCTAssertEqual(motion.direction, direction)
            XCTAssertEqual(state.url?.host, peer)
            XCTAssertTrue(state.switching)
            state.opened?(true)
            XCTAssertTrue(state.hides.isEmpty)
            let ready = motion.starting(at: 100.05, reduceMotion: false)
            XCTAssertFalse(switcher.acceptPeerHideRequest(from: peer, shownAt: 10, motion: ready))
            state.visible = true
            XCTAssertTrue(switcher.acceptPeerHideRequest(from: peer, shownAt: 10, motion: ready))
            XCTAssertEqual(switcher.acceptedPeerMotion, ready)
            XCTAssertFalse(switcher.isSwitchInProgress)
            XCTAssertFalse(switcher.acceptPeerHideRequest(from: peer, shownAt: 11, motion: ready))
        }
    }

    func testGeometryAcknowledgementPreservesSourceAndAddsTarget() throws {
        let (switcher, state, peer) = fixture()
        let source = geometryFixture()
        let target = geometryFixture(frame: CGRect(x: 700, y: 900, width: 320, height: 48))
        state.sourceGeometry = source
        switcher.switchToIsland(named: peer, direction: .left)
        let request = try XCTUnwrap(try IslandSwitchMotion.decode(url: XCTUnwrap(state.url)))
        XCTAssertEqual(request.sourceGeometry, source)
        XCTAssertNil(request.targetGeometry)
        let ready = request.arriving(at: target).starting(at: 100.05, reduceMotion: false)
        state.visible = true
        XCTAssertTrue(switcher.acceptPeerHideRequest(from: peer, shownAt: 10, motion: ready))
        XCTAssertEqual(switcher.acceptedPeerMotion?.sourceGeometry, source)
        XCTAssertEqual(switcher.acceptedPeerMotion?.targetGeometry, target)
    }

    func testAcknowledgementCannotReplaceOrRemovePendingSourceGeometry() throws {
        let (switcher, state, peer) = fixture()
        state.sourceGeometry = geometryFixture()
        switcher.switchToIsland(named: peer, direction: .right)
        let request = try XCTUnwrap(try IslandSwitchMotion.decode(url: XCTUnwrap(state.url)))
        state.visible = true
        let alternatives: [IslandSwitchGeometry?] = [nil,
            geometryFixture(frame: CGRect(x: 701, y: 900, width: 270, height: 40))]
        for source in alternatives {
            let forged = IslandSwitchMotion(requestID: request.requestID, direction: request.direction,
                reduceMotion: request.reduceMotion, issuedUptime: request.issuedUptime, startUptime: 100.05,
                sourceGeometry: source, targetGeometry: geometryFixture())
            XCTAssertFalse(switcher.acceptPeerHideRequest(from: peer, shownAt: 10, motion: forged))
            XCTAssertTrue(switcher.isSwitchInProgress)
        }
        XCTAssertTrue(switcher.acceptPeerHideRequest(from: peer, shownAt: 10,
            motion: request.arriving(at: geometryFixture()).starting(at: 100.05, reduceMotion: false)))
    }

    func testGeometryFreeRequestCanReceiveOptionalTargetGeometry() throws {
        let (switcher, state, peer) = fixture()
        switcher.switchToIsland(named: peer, direction: .left)
        let request = try XCTUnwrap(try IslandSwitchMotion.decode(url: XCTUnwrap(state.url)))
        XCTAssertNil(request.sourceGeometry)
        let target = geometryFixture()
        let ready = request.arriving(at: target).starting(at: 100.05, reduceMotion: false)
        state.visible = true
        let unexpectedSource = IslandSwitchMotion(requestID: request.requestID, direction: request.direction,
            reduceMotion: false, issuedUptime: request.issuedUptime, startUptime: 100.05,
            sourceGeometry: geometryFixture(), targetGeometry: target)
        XCTAssertFalse(switcher.acceptPeerHideRequest(from: peer, shownAt: 10, motion: unexpectedSource))
        XCTAssertTrue(switcher.acceptPeerHideRequest(from: peer, shownAt: 10, motion: ready))
        XCTAssertNil(switcher.acceptedPeerMotion?.sourceGeometry)
        XCTAssertEqual(switcher.acceptedPeerMotion?.targetGeometry, target)
    }

    func testEarlyAcknowledgementIsRetainedUntilWindowServerConfirmsVisibility() throws {
        let (switcher, state, peer) = fixture()
        switcher.switchToIsland(named: peer, direction: .left)
        let request = try XCTUnwrap(try IslandSwitchMotion.decode(url: XCTUnwrap(state.url)))
        state.opened?(true)
        let ready = request.starting(at: 100.05, reduceMotion: false)
        XCTAssertFalse(switcher.acceptPeerHideRequest(from: peer, shownAt: 10, motion: ready))
        XCTAssertTrue(state.hides.isEmpty)
        state.visible = true
        state.fire(0.1)
        XCTAssertEqual(state.hides.count, 1)
        XCTAssertEqual(state.hides.first!, ready)
        XCTAssertFalse(switcher.isSwitchInProgress)
    }

    func testStaleOrWrongDirectionAcknowledgementCannotFinishCurrentSwitch() throws {
        let (switcher, state, peer) = fixture()
        switcher.switchToIsland(named: peer, direction: .left)
        let old = try XCTUnwrap(try IslandSwitchMotion.decode(url: XCTUnwrap(state.url)))
        switcher.cancelSwitch()
        state.now = 101
        switcher.switchToIsland(named: peer, direction: .right)
        let current = try XCTUnwrap(try IslandSwitchMotion.decode(url: XCTUnwrap(state.url)))
        state.visible = true
        XCTAssertFalse(switcher.acceptPeerHideRequest(from: peer, shownAt: 10,
            motion: old.starting(at: 101.05, reduceMotion: false)))
        let wrong = IslandSwitchMotion(requestID: current.requestID, direction: .left, reduceMotion: false,
            issuedUptime: current.issuedUptime, startUptime: 101.05)
        XCTAssertFalse(switcher.acceptPeerHideRequest(from: peer, shownAt: 10, motion: wrong))
        XCTAssertTrue(switcher.isSwitchInProgress)
    }

    func testLegacyVisiblePeerFallsBackWithoutInventingDirectionalAcknowledgement() {
        let (switcher, state, peer) = fixture()
        switcher.switchToIsland(named: peer, direction: .left)
        state.visible = true; state.opened?(true)
        XCTAssertTrue(state.hides.isEmpty)
        for _ in 0..<3 { state.fire(0.05) }
        XCTAssertEqual(state.hides.count, 1)
        XCTAssertNil(state.hides[0])
        XCTAssertFalse(switcher.isSwitchInProgress)
    }

    func testColdStartTimeoutRestoresSourceAndCancelsPreview() {
        let (switcher, state, peer) = fixture()
        switcher.switchToIsland(named: peer, direction: .right)
        state.opened?(true)
        state.fire(8)
        XCTAssertTrue(state.hides.isEmpty)
        XCTAssertEqual(state.restores, 1)
        XCTAssertEqual(state.cancelledPreviews, 1)
        XCTAssertFalse(switcher.isSwitchInProgress)
    }

    func testReducedMotionCannotBeReenabledByPeer() throws {
        let (switcher, state, peer) = fixture()
        state.reduced = true
        switcher.switchToIsland(named: peer, direction: .left)
        let outgoing = try XCTUnwrap(try IslandSwitchMotion.decode(url: XCTUnwrap(state.url)))
        XCTAssertTrue(outgoing.reduceMotion)
        let acknowledgement = IslandSwitchMotion(requestID: outgoing.requestID, direction: .left,
            reduceMotion: false, issuedUptime: 100, startUptime: 100.05)
        state.visible = true
        XCTAssertTrue(switcher.acceptPeerHideRequest(from: peer, shownAt: 10, motion: acknowledgement))
        XCTAssertTrue(switcher.acceptedPeerMotion?.reduceMotion == true)
    }
}
