import Foundation
import XCTest
@testable import XIsland

@MainActor
final class IntegrationClientLauncherTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/tmp/xisland-launcher-fixture/Codex.app")

    func testMissingApplicationDoesNotCallOpener() async {
        var calls = 0
        let launcher = IntegrationClientLauncher { _ in calls += 1 }

        let opened = await launcher.open(.codex, at: nil)

        XCTAssertFalse(opened)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(launcher.failure, .init(agent: .codex, kind: .applicationMissing))
        XCTAssertNil(launcher.openingAgent)
    }

    func testSuccessfulLaunchPassesApplicationURLAndClearsOpeningState() async {
        var openedURLs: [URL] = []
        let launcher = IntegrationClientLauncher { openedURLs.append($0) }

        let opened = await launcher.open(.codex, at: appURL)

        XCTAssertTrue(opened)
        XCTAssertEqual(openedURLs, [appURL])
        XCTAssertNil(launcher.failure)
        XCTAssertNil(launcher.openingAgent)
    }

    func testFailedLaunchOffersLocalizedGuidanceWithoutRawErrorOrPath() async throws {
        let launcher = IntegrationClientLauncher { _ in
            throw NSError(domain: "private-launch-error", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "/private/secret/client.app rejected"])
        }

        let opened = await launcher.open(.codex, at: appURL)

        XCTAssertFalse(opened)
        XCTAssertEqual(launcher.failure, .init(agent: .codex, kind: .launchFailed))
        XCTAssertNil(launcher.openingAgent)
        let failure = try XCTUnwrap(launcher.failure)
        XCTAssertTrue(failure.message(language: "zh-Hans").contains("手动打开"))
        XCTAssertTrue(failure.message(language: "en").contains("manually"))
        for language in ["zh", "en"] {
            let message = failure.message(language: language)
            XCTAssertTrue(message.contains("Codex"))
            XCTAssertFalse(message.contains("/private/secret"))
            XCTAssertFalse(message.contains("private-launch-error"))
            XCTAssertFalse(message.contains(appURL.path))
        }
    }

    func testRetryClearsFailureAndCanSucceed() async {
        var calls = 0
        let launcher = IntegrationClientLauncher { _ in
            calls += 1
            if calls == 1 { throw LaunchFailure.rejected }
        }

        let first = await launcher.open(.codex, at: appURL)
        XCTAssertFalse(first)
        XCTAssertNotNil(launcher.failure)
        let second = await launcher.open(.codex, at: appURL)

        XCTAssertTrue(second)
        XCTAssertEqual(calls, 2)
        XCTAssertNil(launcher.failure)
        XCTAssertNil(launcher.openingAgent)
    }

    func testRepeatedClicksDoNotStartAnotherLaunch() async throws {
        let started = expectation(description: "launch suspended")
        var pending: CheckedContinuation<Void, Error>?
        var calls = 0
        let launcher = IntegrationClientLauncher { _ in
            calls += 1
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }
        let first = Task { await launcher.open(.codex, at: appURL) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(launcher.openingAgent, .codex)

        let repeated = await launcher.open(.codex, at: appURL)
        let other = await launcher.open(.cursor, at: nil)

        XCTAssertFalse(repeated)
        XCTAssertFalse(other)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(launcher.openingAgent, .codex)
        XCTAssertNil(launcher.failure)
        try XCTUnwrap(pending).resume(returning: ())
        let opened = await first.value
        XCTAssertTrue(opened)
        XCTAssertNil(launcher.openingAgent)
    }

    func testResetDiscardsOldSuccessWithoutClearingNewLaunch() async throws {
        let firstStarted = expectation(description: "first launch suspended")
        let secondStarted = expectation(description: "second launch suspended")
        var pending: [CheckedContinuation<Void, Error>] = []
        let launcher = IntegrationClientLauncher { _ in
            try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                if pending.count == 1 { firstStarted.fulfill() }
                else { secondStarted.fulfill() }
            }
        }
        let first = Task { await launcher.open(.codex, at: appURL) }
        await fulfillment(of: [firstStarted], timeout: 2)

        launcher.reset()
        XCTAssertNil(launcher.openingAgent)
        XCTAssertNil(launcher.failure)
        let second = Task { await launcher.open(.cursor, at: appURL) }
        await fulfillment(of: [secondStarted], timeout: 2)
        pending[0].resume(returning: ())
        let staleResult = await first.value

        XCTAssertFalse(staleResult)
        XCTAssertEqual(launcher.openingAgent, .cursor)
        XCTAssertNil(launcher.failure)
        pending[1].resume(returning: ())
        let currentResult = await second.value
        XCTAssertTrue(currentResult)
        XCTAssertNil(launcher.openingAgent)
    }

    func testResetDiscardsOldFailureWithoutOverwritingNewFailure() async throws {
        let started = expectation(description: "launch suspended")
        var pending: CheckedContinuation<Void, Error>?
        let launcher = IntegrationClientLauncher { _ in
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }
        let first = Task { await launcher.open(.codex, at: appURL) }
        await fulfillment(of: [started], timeout: 2)

        launcher.reset()
        let missing = await launcher.open(.cursor, at: nil)
        XCTAssertFalse(missing)
        try XCTUnwrap(pending).resume(throwing: LaunchFailure.rejected)
        let staleResult = await first.value

        XCTAssertFalse(staleResult)
        XCTAssertEqual(launcher.failure, .init(agent: .cursor, kind: .applicationMissing))
        XCTAssertNil(launcher.openingAgent)
        launcher.reset()
        XCTAssertNil(launcher.failure)
    }

    func testMissingApplicationGuidanceExplainsManualAndCommandLineRoutes() {
        let failure = IntegrationClientLauncher.Failure(agent: .codex, kind: .applicationMissing)

        XCTAssertTrue(failure.message(language: "zh").contains("手动打开"))
        XCTAssertTrue(failure.message(language: "zh").contains("命令行"))
        XCTAssertTrue(failure.message(language: "en").contains("manually"))
        XCTAssertTrue(failure.message(language: "en").contains("command-line"))
    }

    private enum LaunchFailure: Error {
        case rejected
    }
}
