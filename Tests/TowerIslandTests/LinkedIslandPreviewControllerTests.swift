import CoreGraphics
import XCTest
@testable import XIsland

@MainActor
final class LinkedIslandPreviewControllerTests: XCTestCase {
    func testSourceStaysLiveUntilReadyCanvasHasPresentedSourceEndpoint() throws {
        let harness = try Harness()
        harness.controller.beginGesture()
        harness.controller.update(translation: -18)
        XCTAssertTrue(harness.controller.isActive)
        XCTAssertTrue(harness.controller.ownsGesture)
        XCTAssertTrue(harness.blocked)
        XCTAssertEqual(harness.finishCount, 0)
        XCTAssertFalse(harness.liveHidden)
        XCTAssertTrue(harness.canvases.isEmpty)
        XCTAssertTrue(harness.switches.isEmpty)

        harness.reply(harness.target)

        let events = harness.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .canvasCreated)),
                          try XCTUnwrap(events.firstIndex(of: .update(0))))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .update(0))),
                          try XCTUnwrap(events.firstIndex(of: .hidden(true))))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .hidden(true))),
                          try XCTUnwrap(events.firstIndex(of: .update(-18))))
        XCTAssertTrue(harness.liveHidden)
        XCTAssertEqual(try harness.canvas().currentDistance, -18)
        XCTAssertTrue(harness.switches.isEmpty)
    }

    func testSignedDistanceCanReverseWithoutStartingAnotherRequest() throws {
        let harness = try Harness()
        try harness.makeReady()
        for distance: CGFloat in [-30, -5, 10, 0, -12] {
            harness.controller.update(translation: distance)
            XCTAssertEqual(try harness.canvas().currentDistance, distance)
        }
        XCTAssertEqual(harness.replies.count, 1)
        XCTAssertEqual(harness.canvases.count, 1)
        XCTAssertTrue(harness.switches.isEmpty)
    }

    func testShortGestureRestoresSourceBeforeCanvasFadeAndFinishesOnce() throws {
        let harness = try Harness()
        try harness.makeReady()
        let canvas = try harness.canvas()
        harness.controller.update(translation: -16)
        harness.controller.cancel()
        XCTAssertEqual(canvas.settles.map(\.target), [0])
        XCTAssertTrue(harness.liveHidden)
        XCTAssertTrue(harness.blocked)
        XCTAssertTrue(harness.switches.isEmpty)
        XCTAssertEqual(harness.finishCount, 0)

        canvas.completeSettle(0)
        XCTAssertFalse(harness.liveHidden)
        XCTAssertTrue(harness.blocked, "返回画布还在淡出时继续保护交互")
        let arrival = try XCTUnwrap(harness.events.lastIndex(of: .arrived(0)))
        let restore = try XCTUnwrap(harness.events.lastIndex(of: .hidden(false)))
        let fade = try XCTUnwrap(harness.events.lastIndex(of: .fade))
        XCTAssertLessThan(arrival, restore)
        XCTAssertLessThan(restore, fade)
        XCTAssertEqual(canvas.closeCount, 0)

        canvas.completeFade(0)
        XCTAssertEqual(canvas.closeCount, 1)
        XCTAssertFalse(harness.blocked)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertEqual(harness.finishCount, 1)
        harness.controller.cancel()
        harness.controller.reset()
        XCTAssertEqual(harness.finishCount, 1)
    }

    func testCancelledPreparationIgnoresLateReadyIncludingAfterNewGesture() throws {
        let harness = try Harness()
        harness.controller.beginGesture()
        harness.controller.cancel()
        XCTAssertEqual(harness.requestCancellationCount, 1)
        XCTAssertEqual(harness.finishCount, 1)
        harness.reply(harness.target, request: 0)
        XCTAssertTrue(harness.canvases.isEmpty)
        XCTAssertFalse(harness.liveHidden)

        harness.controller.beginGesture()
        harness.reply(harness.target, request: 0)
        XCTAssertTrue(harness.canvases.isEmpty)
        harness.reply(harness.target, request: 1)
        XCTAssertEqual(harness.canvases.count, 1)
        XCTAssertTrue(harness.liveHidden)
        XCTAssertTrue(harness.switches.isEmpty)
    }

    func testReleaseBeforeReadyCommitsExactlyOnceAfterCanvasArrival() throws {
        let harness = try Harness()
        harness.controller.beginGesture()
        harness.controller.update(translation: -24)
        harness.controller.commit(direction: .left)
        harness.controller.commit(direction: .left)
        XCTAssertFalse(harness.controller.ownsGesture)
        XCTAssertFalse(harness.liveHidden)
        XCTAssertTrue(harness.switches.isEmpty)

        harness.reply(harness.target)
        let canvas = try harness.canvas()
        XCTAssertEqual(canvas.settles.map(\.target), [-harness.source!.frame.width])
        XCTAssertTrue(harness.switches.isEmpty)
        canvas.completeSettle(0)
        XCTAssertEqual(harness.switches, [.init(direction: .left, alreadyAnimated: true)])
        canvas.fireStaleSettle(0)
        harness.reply(harness.target)
        harness.controller.commit(direction: .left)
        XCTAssertEqual(harness.switches.count, 1)
    }

    func testBothDirectionsSwitchOnlyAfterTheirOwnTargetEndpointIsReached() throws {
        for direction in [SwipeDirection.left, .right] {
            let harness = try Harness()
            try harness.makeReady()
            harness.controller.update(translation: direction == .left ? -20 : 20)
            harness.controller.commit(direction: direction)
            let canvas = try harness.canvas()
            let destination = direction == .left ? -harness.source!.frame.width : harness.target.frame.width
            XCTAssertEqual(canvas.settles.map(\.target), [destination])
            XCTAssertTrue(harness.switches.isEmpty)
            canvas.completeSettle(0)
            XCTAssertEqual(harness.switches, [.init(direction: direction, alreadyAnimated: true)])
            XCTAssertLessThan(try XCTUnwrap(harness.events.firstIndex(of: .arrived(destination))),
                              try XCTUnwrap(harness.events.firstIndex(of: .remote(direction, true))))
        }
    }

    func testUnavailableDisplayMismatchAndFailedFactoryFallbackWithoutHidingSource() throws {
        for condition in UnavailableCase.allCases {
            let harness = try Harness()
            if condition == .requestUnavailable { harness.requestAvailable = false }
            if condition == .missingSource { harness.source = nil }
            if condition == .factoryRejected { harness.factoryAvailable = false }
            harness.controller.beginGesture()
            if condition != .requestUnavailable {
                let reply = condition == .missingTarget ? nil
                    : condition == .differentDisplay ? try Harness.snapshot(width: 120, height: 60, displayID: 2)
                    : harness.target
                harness.reply(reply)
            }
            XCTAssertFalse(harness.liveHidden, condition.rawValue)
            XCTAssertFalse(harness.events.contains(.hidden(true)), condition.rawValue)
            XCTAssertFalse(harness.blocked, condition.rawValue)
            XCTAssertFalse(harness.controller.isActive, condition.rawValue)
            harness.controller.commit(direction: .right)
            XCTAssertEqual(harness.switches, [.init(direction: .right, alreadyAnimated: false)], condition.rawValue)
            XCTAssertTrue(harness.canvases.isEmpty, condition.rawValue)
        }
    }

    func testReleaseBeforeUnavailableReplyFallsBackOnceWithoutHidingSource() throws {
        let harness = try Harness()
        harness.controller.beginGesture()
        harness.controller.commit(direction: .left)
        harness.reply(nil)
        harness.reply(harness.target)
        XCTAssertEqual(harness.switches, [.init(direction: .left, alreadyAnimated: false)])
        XCTAssertFalse(harness.liveHidden)
        XCTAssertFalse(harness.blocked)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertTrue(harness.canvases.isEmpty)
    }

    func testHiddenSourceTransfersCanvasOnlyToConfirmedVisiblePeer() throws {
        for peerVisible in [false, true] {
            let harness = try Harness()
            try harness.makeReady()
            harness.controller.commit(direction: .right)
            let canvas = try harness.canvas()
            canvas.completeSettle(0)
            harness.peerVisible = peerVisible

            harness.controller.reset(afterWindowHidden: true)

            XCTAssertFalse(harness.blocked)
            XCTAssertFalse(harness.liveHidden)
            XCTAssertEqual(harness.finishCount, 1)
            XCTAssertEqual(harness.commitCancellationCount, peerVisible ? 0 : 1)
            XCTAssertEqual(canvas.fades.count, peerVisible ? 1 : 0)
            XCTAssertEqual(canvas.closeCount, peerVisible ? 0 : 1)
            if peerVisible {
                harness.controller.beginGesture()
                canvas.completeFade(0)
                XCTAssertTrue(harness.controller.isActive, "旧画布淡出不能清除新请求")
                XCTAssertTrue(harness.blocked)
                XCTAssertEqual(canvas.closeCount, 1)
            }
        }
    }

    func testExplicitResetCancelsCommitEvenIfPeerIsVisible() throws {
        let harness = try Harness()
        try harness.makeReady()
        harness.controller.commit(direction: .left)
        let canvas = try harness.canvas()
        canvas.completeSettle(0)
        harness.peerVisible = true
        harness.controller.reset()
        XCTAssertEqual(harness.commitCancellationCount, 1)
        XCTAssertTrue(canvas.fades.isEmpty)
        XCTAssertEqual(canvas.closeCount, 1)
        XCTAssertEqual(harness.finishCount, 1)
    }

    func testExplicitResetBeforeCanvasArrivalPreventsLateRemoteSwitch() throws {
        let harness = try Harness()
        try harness.makeReady()
        harness.controller.commit(direction: .left)
        let canvas = try harness.canvas()
        XCTAssertTrue(harness.switches.isEmpty)
        harness.controller.reset()
        canvas.fireStaleSettle(0)
        XCTAssertTrue(harness.switches.isEmpty)
        XCTAssertEqual(harness.commitCancellationCount, 0, "尚未发起的远端切换无需取消")
        XCTAssertFalse(harness.liveHidden)
        XCTAssertFalse(harness.blocked)
        XCTAssertEqual(canvas.closeCount, 1)
        XCTAssertEqual(harness.finishCount, 1)
    }

    func testFailedCommitReturnsToSourceAndLateCallbacksCannotTakeOverNewGesture() throws {
        let harness = try Harness()
        try harness.makeReady()
        harness.controller.commit(direction: .left)
        let previous = try harness.canvas()
        previous.completeSettle(0)
        harness.controller.cancel()
        XCTAssertEqual(harness.commitCancellationCount, 1)
        XCTAssertEqual(previous.settles.last?.target, 0)
        XCTAssertTrue(harness.liveHidden)
        previous.fireStaleSettle(0)
        XCTAssertEqual(harness.switches.count, 1)
        previous.completeSettle(1)
        previous.completeFade(0)
        XCTAssertFalse(harness.blocked)
        XCTAssertEqual(harness.finishCount, 1)

        harness.controller.beginGesture()
        harness.reply(harness.target, request: 1)
        let latest = try harness.canvas()
        previous.fireStaleSettle(0)
        previous.fireStaleSettle(1)
        previous.completeFade(0)
        XCTAssertTrue(harness.liveHidden)
        XCTAssertTrue(harness.blocked)
        XCTAssertEqual(latest.closeCount, 0)
        XCTAssertEqual(harness.switches.count, 1)
    }

    func testNewGestureDuringReturnContinuesFromPresentationDistance() throws {
        let harness = try Harness()
        try harness.makeReady()
        let canvas = try harness.canvas()
        harness.controller.update(translation: -40)
        harness.controller.cancel()
        canvas.currentDistance = -14
        harness.controller.beginGesture()
        XCTAssertEqual(canvas.currentDistance, -14)
        harness.controller.update(translation: 8)
        XCTAssertEqual(canvas.currentDistance, -6)
        harness.controller.update(translation: -8)
        XCTAssertEqual(canvas.currentDistance, -22)
        canvas.fireStaleSettle(0)
        XCTAssertTrue(harness.liveHidden)
        XCTAssertTrue(canvas.fades.isEmpty)
        XCTAssertEqual(harness.replies.count, 1)
        XCTAssertEqual(harness.finishCount, 0)
        harness.controller.commit(direction: .right)
        canvas.completeSettle(1)
        XCTAssertEqual(harness.switches, [.init(direction: .right, alreadyAnimated: true)])
    }

    func testUnavailableAttemptEmitsFinishOnceDespiteCancelResetAndNextBegin() throws {
        let harness = try Harness()
        harness.controller.beginGesture()
        harness.reply(nil)
        XCTAssertEqual(harness.finishCount, 1)
        harness.controller.cancel()
        harness.controller.reset()
        XCTAssertEqual(harness.finishCount, 1, "已经结束的不可用预览不能重复发完成通知")
        harness.controller.beginGesture()
        XCTAssertEqual(harness.finishCount, 1)
        XCTAssertTrue(harness.blocked)
        XCTAssertTrue(harness.controller.isActive)
    }

    func testTrackingYieldsToVisiblePeerBeforeRestoringSourceBehindHiddenWindow() throws {
        let harness = try Harness()
        try harness.makeReady()
        let canvas = try harness.canvas()
        harness.controller.update(translation: -12)
        harness.peerVisible = true
        harness.now += 0.11

        harness.controller.update(translation: -18)

        XCTAssertEqual(harness.yieldCount, 1)
        XCTAssertTrue(harness.switches.isEmpty)
        XCTAssertEqual(canvas.currentDistance, -12, "对端显现后停止移动旧快照")
        XCTAssertTrue(canvas.settles.isEmpty)
        XCTAssertTrue(canvas.fades.isEmpty)
        XCTAssertTrue(harness.liveHidden)
        XCTAssertTrue(harness.nativeSourceVisible)
        XCTAssertTrue(harness.restoredNativeVisibility.isEmpty)
        XCTAssertFalse(harness.controller.ownsGesture)

        harness.hideNativeSourceAndFinish()

        XCTAssertFalse(harness.nativeSourceVisible)
        XCTAssertEqual(harness.restoredNativeVisibility, [false], "真实源窗退屏后才能恢复背后内容")
        XCTAssertEqual(canvas.fades.count, 1)
        XCTAssertEqual(harness.commitCancellationCount, 0)
        XCTAssertFalse(harness.blocked)
        canvas.completeFade(0)
        XCTAssertEqual(canvas.closeCount, 1)
        XCTAssertTrue(harness.switches.isEmpty)
        XCTAssertEqual(harness.finishCount, 1)
    }

    func testCommitForcesFreshPeerVisibilityCheckInsideCachedInterval() throws {
        let harness = try Harness()
        try harness.makeReady()
        let canvas = try harness.canvas()
        XCTAssertEqual(harness.visibilityQueryCount, 1, "接收有效ready时先核对目标显隐")
        harness.controller.update(translation: 12)
        XCTAssertEqual(harness.visibilityQueryCount, 1)
        harness.now += 0.03
        harness.peerVisible = true

        harness.controller.commit(direction: .right)

        XCTAssertEqual(harness.visibilityQueryCount, 2, "松手必须核对当前对端，不能沿用拖动缓存")
        XCTAssertEqual(harness.yieldCount, 1)
        XCTAssertTrue(harness.switches.isEmpty)
        XCTAssertTrue(canvas.settles.isEmpty)
        XCTAssertTrue(harness.liveHidden)
        harness.hideNativeSourceAndFinish()
        XCTAssertEqual(harness.restoredNativeVisibility, [false])
        XCTAssertEqual(canvas.fades.count, 1)
        canvas.completeFade(0)
        XCTAssertFalse(harness.nativeSourceVisible)
        XCTAssertTrue(harness.switches.isEmpty)
    }

    func testVisiblePeerAtReadyYieldsWithoutInstallingCanvasEvenAfterRelease() throws {
        for releasedBeforeReady in [false, true] {
            let harness = try Harness()
            harness.controller.beginGesture()
            harness.controller.update(translation: -20)
            if releasedBeforeReady { harness.controller.commit(direction: .left) }
            harness.peerVisible = true

            harness.reply(harness.target)

            XCTAssertEqual(harness.yieldCount, 1)
            XCTAssertTrue(harness.canvases.isEmpty, "已显示的对端不能被迟到快照覆盖")
            XCTAssertTrue(harness.switches.isEmpty)
            XCTAssertFalse(harness.liveHidden)
            XCTAssertFalse(harness.events.contains(.hidden(true)))
            XCTAssertFalse(harness.controller.ownsGesture)
            harness.hideNativeSourceAndFinish()
            XCTAssertFalse(harness.nativeSourceVisible)
            XCTAssertTrue(harness.restoredNativeVisibility.isEmpty, "未隐藏过源内容，无需恢复其可见层")
            XCTAssertEqual(harness.commitCancellationCount, 0)
            XCTAssertEqual(harness.finishCount, 1)
            XCTAssertFalse(harness.blocked)
            harness.reply(harness.target)
            XCTAssertEqual(harness.yieldCount, 1)
            XCTAssertTrue(harness.switches.isEmpty)
        }
    }

    func testPeerVisibleAtForwardArrivalYieldsInsteadOfSendingNormalShow() throws {
        let harness = try Harness()
        try harness.makeReady()
        let canvas = try harness.canvas()
        harness.controller.update(translation: -20)
        harness.controller.commit(direction: .left)
        let queriesBeforeArrival = harness.visibilityQueryCount
        harness.now += 0.02
        harness.peerVisible = true

        canvas.completeSettle(0)

        XCTAssertEqual(harness.visibilityQueryCount, queriesBeforeArrival + 1,
                       "到达端点必须重新确认，不沿用松手前缓存")
        XCTAssertEqual(harness.yieldCount, 1)
        XCTAssertTrue(harness.switches.isEmpty)
        XCTAssertTrue(harness.liveHidden)
        XCTAssertTrue(canvas.fades.isEmpty)
        harness.hideNativeSourceAndFinish()
        XCTAssertEqual(harness.restoredNativeVisibility, [false])
        XCTAssertEqual(canvas.fades.count, 1)
        XCTAssertEqual(harness.commitCancellationCount, 0)
        canvas.completeFade(0)
        canvas.fireStaleSettle(0)
        XCTAssertEqual(canvas.closeCount, 1)
        XCTAssertEqual(harness.finishCount, 1)
        XCTAssertEqual(harness.yieldCount, 1)
        XCTAssertTrue(harness.switches.isEmpty)
    }

    func testInvalidSourceContextCancelsTrackingAndPendingCommitWithoutLateSwitch() throws {
        for settlingForward in [false, true] {
            let harness = try Harness()
            try harness.makeReady()
            let previous = try harness.canvas()
            harness.controller.update(translation: -18)
            if settlingForward { harness.controller.commit(direction: .left) }
            harness.sourceContextValid = false
            if settlingForward { previous.completeSettle(0) }
            else { harness.controller.update(translation: -22) }

            XCTAssertFalse(harness.controller.isActive)
            XCTAssertFalse(harness.blocked)
            XCTAssertFalse(harness.liveHidden)
            XCTAssertEqual(previous.closeCount, 1)
            XCTAssertTrue(harness.switches.isEmpty)
            XCTAssertEqual(harness.finishCount, 1)
            harness.sourceContextValid = true
            harness.controller.beginGesture()
            harness.reply(harness.target, request: 1)
            let latest = try harness.canvas()
            if settlingForward { previous.fireStaleSettle(0) }
            harness.reply(harness.target, request: 0)
            XCTAssertTrue(harness.liveHidden)
            XCTAssertTrue(harness.blocked)
            XCTAssertEqual(latest.closeCount, 0)
            XCTAssertTrue(harness.switches.isEmpty)
        }
    }

    func testTrackingBoundsPeerVisibilityQueriesToOnePerHundredMilliseconds() throws {
        let harness = try Harness()
        try harness.makeReady()
        let readyQueryCount = harness.visibilityQueryCount
        XCTAssertEqual(readyQueryCount, 1)
        for index in 0..<200 { harness.controller.update(translation: CGFloat(index % 40) - 20) }
        XCTAssertEqual(harness.visibilityQueryCount - readyQueryCount, 0)
        harness.now = 100.099
        harness.controller.update(translation: 1)
        XCTAssertEqual(harness.visibilityQueryCount - readyQueryCount, 0)
        harness.now = 100.101
        harness.controller.update(translation: 2)
        XCTAssertEqual(harness.visibilityQueryCount - readyQueryCount, 1)
        harness.now = 100.15
        for index in 0..<200 { harness.controller.update(translation: CGFloat(index % 40) - 20) }
        XCTAssertEqual(harness.visibilityQueryCount - readyQueryCount, 1)
        harness.now = 100.202
        harness.controller.update(translation: 3)
        XCTAssertEqual(harness.visibilityQueryCount - readyQueryCount, 2)
        XCTAssertTrue(harness.switches.isEmpty)
        XCTAssertEqual(harness.yieldCount, 0)
    }

    private enum UnavailableCase: String, CaseIterable {
        case requestUnavailable, missingTarget, missingSource, differentDisplay, factoryRejected
    }

    private enum Event: Equatable {
        case request, requestCancelled, sourceCaptured, canvasCreated, hidden(Bool), blocked(Bool)
        case update(CGFloat), settle(CGFloat), arrived(CGFloat), fade, close
        case remote(SwipeDirection, Bool), commitCancelled, finished, yieldedToPeer, nativeSourceHidden
    }

    private struct Switch: Equatable {
        let direction: SwipeDirection
        let alreadyAnimated: Bool
    }

    @MainActor
    private final class Harness {
        var source: IslandPreviewSnapshot?
        let target: IslandPreviewSnapshot
        var events: [Event] = []
        var replies: [@MainActor (IslandPreviewSnapshot?) -> Void] = []
        var canvases: [FakeCanvas] = []
        var switches: [Switch] = []
        var requestAvailable = true
        var factoryAvailable = true
        var peerVisible = false
        var liveHidden = false
        var blocked = false
        var finishCount = 0
        var requestCancellationCount = 0
        var commitCancellationCount = 0
        var visibilityQueryCount = 0
        var yieldCount = 0
        var nativeSourceVisible = true
        var restoredNativeVisibility: [Bool] = []
        var sourceContextValid = true
        var now: TimeInterval = 100

        lazy var controller = LinkedIslandPreviewController(environment: .init(
            requestTarget: { [unowned self] reply in
                events.append(.request)
                guard requestAvailable else { return nil }
                replies.append(reply)
                return { [unowned self] in requestCancellationCount += 1; events.append(.requestCancelled) }
            },
            captureSource: { [unowned self] in events.append(.sourceCaptured); return source },
            makeCanvas: { [unowned self] _, _ in
                guard factoryAvailable else { return nil }
                let canvas = FakeCanvas { [weak self] in self?.events.append($0) }
                canvases.append(canvas)
                events.append(.canvasCreated)
                return canvas
            },
            hideLiveContent: { [unowned self] hidden in
                if !hidden && liveHidden { restoredNativeVisibility.append(nativeSourceVisible) }
                liveHidden = hidden
                events.append(.hidden(hidden))
            },
            blockInteraction: { [unowned self] in blocked = $0; events.append(.blocked($0)) },
            switchToPeer: { [unowned self] direction, alreadyAnimated in
                switches.append(Switch(direction: direction, alreadyAnimated: alreadyAnimated))
                events.append(.remote(direction, alreadyAnimated))
            },
            peerIsVisible: { [unowned self] in visibilityQueryCount += 1; return peerVisible },
            didFinish: { [unowned self] in finishCount += 1; events.append(.finished) },
            cancelCommit: { [unowned self] in commitCancellationCount += 1; events.append(.commitCancelled) },
            yieldToVisiblePeer: { [unowned self] in yieldCount += 1; events.append(.yieldedToPeer) },
            sourceContextIsValid: { [unowned self] _ in sourceContextValid },
            uptime: { [unowned self] in now }
        ))

        init() throws {
            source = try Self.snapshot(width: 80, height: 40)
            target = try Self.snapshot(width: 120, height: 60)
        }

        func reply(_ snapshot: IslandPreviewSnapshot?, request: Int = 0) { replies[request](snapshot) }
        func canvas() throws -> FakeCanvas { try XCTUnwrap(canvases.last) }
        func makeReady() throws { controller.beginGesture(); reply(target); _ = try canvas() }
        func hideNativeSourceAndFinish() {
            nativeSourceVisible = false
            events.append(.nativeSourceHidden)
            controller.reset(afterWindowHidden: true)
        }

        static func snapshot(width: Int, height: Int, displayID: UInt32 = 1) throws -> IslandPreviewSnapshot {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let frame = CGRect(x: 100, y: 200, width: width, height: height)
            let outline = try XCTUnwrap(IslandSwitchGeometry(frame: frame, displayID: displayID,
                topRadius: 0, bottomRadius: 8, fill: IslandSwitchColor(red: 1, green: 0, blue: 0, alpha: 1)))
            return IslandPreviewSnapshot(image: try XCTUnwrap(context.makeImage()), frame: frame, scale: 1, outline: outline)
        }
    }

    @MainActor
    private final class FakeCanvas: LinkedIslandPreviewPresenting {
        var viewportScreenFrame = CGRect(x: 0, y: 0, width: 260, height: 60)
        struct Settle {
            let target: CGFloat
            let completion: @MainActor () -> Void
        }
        let record: (Event) -> Void
        var currentDistance: CGFloat = 0
        var settles: [Settle] = []
        var fades: [@MainActor () -> Void] = []
        private(set) var closeCount = 0
        init(record: @escaping (Event) -> Void) { self.record = record }
        func update(distance: CGFloat) { currentDistance = distance; record(.update(distance)) }
        func settle(targetDistance: CGFloat, duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
            settles.append(Settle(target: targetDistance, completion: completion))
            record(.settle(targetDistance))
        }
        func fadeOut(duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
            fades.append(completion); record(.fade)
        }
        func close() { guard closeCount == 0 else { return }; closeCount = 1; record(.close) }
        func completeSettle(_ index: Int) {
            currentDistance = settles[index].target
            record(.arrived(currentDistance))
            settles[index].completion()
        }
        func fireStaleSettle(_ index: Int) { settles[index].completion() }
        func completeFade(_ index: Int) { fades[index]() }
    }
}
