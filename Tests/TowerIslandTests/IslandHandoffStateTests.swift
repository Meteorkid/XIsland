import XCTest
@testable import XIsland

final class IslandHandoffStateTests: XCTestCase {
    func testOnlyLatestPreparationCanCompleteOnce() {
        var state = IslandHandoffState()
        let first = state.beginInbound()
        let latest = state.beginInbound()
        XCTAssertFalse(state.consumePreparation(first))
        XCTAssertTrue(state.consumePreparation(latest))
        XCTAssertFalse(state.consumePreparation(latest))
    }

    func testPreparedPresentationStartsAndFinishesOnlyOnce() {
        var state = IslandHandoffState()
        let incoming = state.beginInbound()
        XCTAssertFalse(state.beginPresentation(incoming))
        XCTAssertTrue(state.consumePreparation(incoming))
        XCTAssertTrue(state.beginPresentation(incoming))
        XCTAssertFalse(state.beginPresentation(incoming))
        XCTAssertTrue(state.finishPresentation(incoming))
        XCTAssertFalse(state.finishPresentation(incoming))
    }

    func testHoverRequiresRealExitAfterPreparation() {
        var state = IslandHandoffState()
        let generation = state.beginInbound()
        XCTAssertTrue(state.observePointer(isInside: false))
        XCTAssertTrue(state.consumePreparation(generation))
        XCTAssertTrue(state.observePointer(isInside: true))
        XCTAssertFalse(state.observePointer(isInside: false))
        XCTAssertFalse(state.observePointer(isInside: true))
    }

    func testNewPresentationInvalidatesOldFadeAndPreparation() throws {
        var state = IslandHandoffState()
        let incoming = state.beginInbound()
        let fade = try XCTUnwrap(state.beginFadeOut())
        XCTAssertFalse(state.consumePreparation(incoming))
        XCTAssertNil(state.beginFadeOut())
        state.cancelPresentation()
        XCTAssertFalse(state.finishFadeOut(fade))
        XCTAssertFalse(state.isFadingOut)
    }

    func testNewInboundInvalidatesOutgoingCompletion() throws {
        var state = IslandHandoffState()
        let outgoing = try XCTUnwrap(state.beginFadeOut())
        let incoming = state.beginInbound()
        XCTAssertFalse(state.finishFadeOut(outgoing))
        XCTAssertTrue(state.consumePreparation(incoming))
    }

    func testExplicitPresentationRestoresOnlyCancelledContent() throws {
        var state = IslandHandoffState()
        let incoming = state.beginInbound()
        XCTAssertTrue(state.consumePreparation(incoming))
        XCTAssertFalse(state.shouldRestoreContent(preparedGeneration: incoming, isWindowVisible: true,
                                                  didPresentWindow: true, hiddenByIslandSwitch: false))
        _ = try XCTUnwrap(state.beginFadeOut())
        XCTAssertFalse(state.shouldRestoreContent(preparedGeneration: incoming, isWindowVisible: true,
                                                  didPresentWindow: false, hiddenByIslandSwitch: true))
        state.cancelPresentation()
        XCTAssertTrue(state.shouldRestoreContent(preparedGeneration: incoming, isWindowVisible: false,
                                                 didPresentWindow: true, hiddenByIslandSwitch: false))
    }
}
