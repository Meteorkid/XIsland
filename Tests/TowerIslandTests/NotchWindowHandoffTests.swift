import AppKit
import XCTest
@testable import XIsland

@MainActor
final class NotchWindowHandoffTests: XCTestCase {
    func testColdInboundWaitsForHandlerAndCompletesOnce() throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        var completed: [UInt64] = []
        let generation = fixture.window.beginInboundHandoff { completed.append($0) }
        XCTAssertEqual(fixture.window.handoffState.pendingPreparation, generation)
        XCTAssertTrue(completed.isEmpty)
        var requested: [UInt64] = []
        fixture.window.installHandoffPreparationHandler { requested.append($0) }
        XCTAssertEqual(requested, [generation])
        XCTAssertTrue(fixture.window.completeInboundHandoffPreparation(generation: generation))
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: generation))
        XCTAssertEqual(completed, [generation])
    }

    func testRepeatedInboundRejectsStalePreparation() throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        var completed: [UInt64] = []
        let first = fixture.window.beginInboundHandoff { completed.append($0) }
        let latest = fixture.window.beginInboundHandoff { completed.append($0) }
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: first))
        XCTAssertTrue(fixture.window.completeInboundHandoffPreparation(generation: latest))
        XCTAssertEqual(completed, [latest])
    }

    func testExplicitShowCancelsPreparationAndRestoresLayer() throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let incoming = fixture.window.beginInboundHandoff { _ in XCTFail("旧准备不能重新显示") }
        fixture.window.previewIslandSwitch(translation: 30)
        fixture.window.showWindow()
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: incoming))
        XCTAssertNil(fixture.window.handoffState.pendingPreparation)
        XCTAssertFalse(fixture.window.isSwitchingApps)
        XCTAssertEqual(fixture.window.alphaValue, 1)
        XCTAssertEqual(fixture.harness.frontCount, 1)
    }

    func testPreparedShowWaitsForPreparationAndPublishesPresentation() throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        var presentations = 0
        var completions = 0
        let token = NotificationCenter.default.addObserver(forName: .xislandDidPresentWindow,
                                                           object: fixture.window, queue: .main) { _ in
            MainActor.assumeIsolated { presentations += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let completedToken = NotificationCenter.default.addObserver(forName: .xislandDidFinishHandoff,
            object: fixture.window, queue: .main) { _ in
                MainActor.assumeIsolated { completions += 1 }
            }
        defer { NotificationCenter.default.removeObserver(completedToken) }
        let incoming = fixture.window.beginInboundHandoff { [window = fixture.window] generation in
            window.showPreparedHandoff(generation: generation)
        }
        fixture.window.showPreparedHandoff(generation: incoming)
        XCTAssertEqual(fixture.harness.frontCount, 0)
        XCTAssertTrue(fixture.window.completeInboundHandoffPreparation(generation: incoming))
        fixture.window.showPreparedHandoff(generation: incoming)
        XCTAssertEqual(fixture.harness.frontCount, 1)
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(completions, 1, "入站完成只发布一次独立通知")
        XCTAssertFalse(fixture.window.isSwitchingApps, "减弱动态效果应同步结束入场保护")
    }

    func testReducedMotionHideIsImmediateAndCannotCompleteOldPreparation() throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let incoming = fixture.window.beginInboundHandoff { _ in XCTFail("出站必须作废入站") }
        fixture.window.hideWindowForIslandSwitch()
        fixture.window.hideWindowForIslandSwitch()
        XCTAssertTrue(fixture.window.isHiddenByIslandSwitch)
        XCTAssertFalse(fixture.window.handoffState.isFadingOut)
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: incoming))
        XCTAssertEqual(fixture.harness.outCount, 1)
    }

    func testCloseInvalidatesPendingHandoff() throws {
        let fixture = try makeFixture()
        let incoming = fixture.window.beginInboundHandoff { _ in XCTFail("关闭后不能复显") }
        fixture.window.close()
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: incoming))
    }

    func testExplicitHideInvalidatesPreparation() throws {
        let fixture = try makeFixture()
        defer { fixture.window.close() }
        let incoming = fixture.window.beginInboundHandoff { _ in XCTFail("隐藏后不能复显") }
        fixture.window.orderOut(nil)
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: incoming))
        XCTAssertNil(fixture.window.handoffState.pendingPreparation)
    }

    func testHoverEffectsStayOffDuringHandoffOrSwipe() {
        for (handoff, switching) in [(true, false), (false, true)] {
            XCTAssertFalse(NotchContentView.shouldAllowHoverExpansion(
                isPointerInside: true, isExpanded: false, collapseAnimating: false,
                isHandoffSuppressed: handoff, isSwitchingApps: switching))
            XCTAssertFalse(NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: true, isExpanded: false, collapseAnimating: false,
                previousMouseY: 0, currentMouseY: 10,
                isHandoffSuppressed: handoff, isSwitchingApps: switching))
        }
    }

    func testExpansionClearsPreviewLayerAndGestureWithoutAnotherScrollEvent() throws {
        let fixture = try makeFixture(reduceMotion: false)
        defer { fixture.window.close() }
        let window = fixture.window
        _ = window.swipeRecognizer.handleScroll(deltaX: 18, deltaY: 0, isPrecise: true,
                                                phase: .began, momentumPhase: [], now: Date())
        window.previewIslandSwitch(translation: 18)
        XCTAssertGreaterThan(try XCTUnwrap(window.contentView?.layer?.transform.m41), 0)
        XCTAssertTrue(window.swipeRecognizer.consumesHorizontalScroll)

        window.islandState = .expanded

        XCTAssertEqual(window.contentView?.layer?.transform.m41, 0)
        XCTAssertNil(window.contentView?.layer?.animation(forKey: "island.directional-switch"))
        XCTAssertFalse(window.swipeRecognizer.isActive)
    }

    func testOwnershipLossClearsPreviewEvenWhenPointerRemainsInside() throws {
        let fixture = try makeFixture(reduceMotion: false)
        defer { fixture.window.close() }
        let window = fixture.window
        _ = window.swipeRecognizer.handleScroll(deltaX: 18, deltaY: 0, isPrecise: true,
                                                phase: .began, momentumPhase: [], now: Date())
        window.previewIslandSwitch(translation: 18)
        XCTAssertGreaterThan(try XCTUnwrap(window.contentView?.layer?.transform.m41), 0)
        XCTAssertFalse(window.isVisible, "未显示的测试窗口不能拥有最前方灵动岛")

        _ = window.observeHandoffPointer(isInside: true)

        XCTAssertEqual(window.contentView?.layer?.transform.m41, 0)
        XCTAssertFalse(window.swipeRecognizer.isActive)
        XCTAssertEqual(fixture.harness.frontCount, 0)
    }

    private func makeFixture(reduceMotion: Bool = true) throws -> (window: NotchWindow, harness: Harness) {
        _ = NSApplication.shared
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "XIslandTests.Handoff.\(UUID().uuidString)"))
        let harness = Harness()
        let window = NotchWindow(defaults: defaults, markVisible: {}, onExplicitShow: {},
                                 handoffEnvironment: .init(reduceMotion: { reduceMotion },
                                                           orderFront: { _ in harness.frontCount += 1 },
                                                           orderOut: { _ in harness.outCount += 1 }))
        return (window, harness)
    }

    private final class Harness {
        var frontCount = 0
        var outCount = 0
    }
}
