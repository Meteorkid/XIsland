import XCTest
@testable import XIsland

final class TerminalSessionNavigatorTests: XCTestCase {
    func testITermSelectsExactSessionTabAndWindowOnlyAfterUniqueMatch() throws {
        let uuid = "0B0D70D0-52C6-4C19-A579-F8760CB13821"
        let script = try XCTUnwrap(TerminalSessionNavigator.appleScript(for: .iTerm(id: "iterm:w0t1p2:" + uuid)))
        XCTAssertTrue(script.contains("if unique ID of aSession is \"\(uuid)\" then"))
        XCTAssertTrue(script.contains("if matchCount is not 1 then return false"))
        let guardRange = try XCTUnwrap(script.range(of: "if matchCount is not 1 then return false"))
        let selectRange = try XCTUnwrap(script.range(of: "select targetSession"))
        XCTAssertLessThan(guardRange.lowerBound, selectRange.lowerBound)
        XCTAssertTrue(script.contains("select targetTab"))
        XCTAssertTrue(script.contains("select targetWindow"))
        XCTAssertFalse(script.contains("current window"))
        XCTAssertFalse(script.contains("contains"))
    }

    func testITermAcceptsBareIDAndTTYWithoutTitleFallback() throws {
        let bare = try XCTUnwrap(TerminalSessionNavigator.appleScript(for: .iTerm(id: "session-123")))
        XCTAssertTrue(bare.contains("unique ID of aSession is \"session-123\""))
        let tty = try XCTUnwrap(TerminalSessionNavigator.appleScript(for: .iTerm(id: "tty:/dev/ttys007")))
        XCTAssertTrue(tty.contains("tty of aSession is \"/dev/ttys007\""))
        XCTAssertFalse(tty.contains("name of aSession"))
    }

    func testAppleTerminalRequiresUniqueExactTTY() throws {
        let script = try XCTUnwrap(TerminalSessionNavigator.appleScript(for: .appleTerminalTTY("tty:/dev/ttys004")))
        XCTAssertTrue(script.contains("if tty of aTab is \"/dev/ttys004\" then"))
        XCTAssertTrue(script.contains("if matchCount is not 1 then return false"))
        XCTAssertTrue(script.contains("set selected tab of targetWindow to targetTab"))
        XCTAssertFalse(script.contains("custom title"))
        XCTAssertFalse(script.contains("id of"))
    }

    func testScriptsGuardStoppedApplicationsAndHaveAppleEventTimeout() throws {
        for target in [TerminalSessionTarget.iTerm(id: "session-123"), .appleTerminalTTY("/dev/ttys001")] {
            let script = try XCTUnwrap(TerminalSessionNavigator.appleScript(for: target))
            XCTAssertTrue(script.contains("is not running then return false"))
            XCTAssertTrue(script.contains("with timeout of 5 seconds"))
        }
    }

    func testITermIdentifierIsQuotedAsData() throws {
        let id = "session-\"quoted\\identifier"
        let script = try XCTUnwrap(TerminalSessionNavigator.appleScript(for: .iTerm(id: id)))
        XCTAssertTrue(script.contains("unique ID of aSession is \"session-\\\"quoted\\\\identifier\""))
    }

    func testCommandsUseExplicitNonnegativeIdentity() {
        XCTAssertEqual(TerminalSessionNavigator.commandArguments(for: .wezTermPane(42)),
                       ["wezterm", "cli", "activate-pane", "--pane-id", "42"])
        XCTAssertEqual(TerminalSessionNavigator.commandArguments(for: .wezTermPane(0)),
                       ["wezterm", "cli", "activate-pane", "--pane-id", "0"])
        XCTAssertEqual(TerminalSessionNavigator.commandArguments(for: .kittyWindow(23)),
                       ["kitty", "@", "focus-window", "--match", "id:23"])
        XCTAssertNil(TerminalSessionNavigator.commandArguments(for: .wezTermPane(-1)))
        XCTAssertNil(TerminalSessionNavigator.commandArguments(for: .kittyWindow(-1)))
    }

    func testMalformedTargetsNeverReachExecutors() {
        let targets: [TerminalSessionTarget] = [
            .iTerm(id: ""), .iTerm(id: "iterm:"), .iTerm(id: "iterm:w0t0p0:"),
            .iTerm(id: "id\nactivate"), .iTerm(id: String(repeating: "x", count: 513)),
            .iTerm(id: "tty:/tmp/ttys001"), .appleTerminalTTY("/tmp/ttys001"),
            .appleTerminalTTY("/dev/ttys001/other"), .appleTerminalTTY(""),
            .wezTermPane(-1), .kittyWindow(-1)
        ]
        let executor = TerminalSessionNavigator.Executor(
            appleScript: { _ in XCTFail("invalid target executed AppleScript"); return .returned(true) },
            command: { _ in XCTFail("invalid target launched command"); return .exited(0) }
        )
        for target in targets {
            XCTAssertEqual(TerminalSessionNavigator.navigate(target, executor: executor), .targetNotFound)
        }
    }

    func testAppleScriptFailureDoesNotBecomeSuccessfulActivation() {
        let outcomes: [(TerminalSessionNavigator.AppleScriptOutcome, TerminalSessionNavigationResult)] = [
            (.returned(true), .success), (.returned(false), .targetNotFound),
            (.failed(-1743), .automationDenied), (.failed(-1744), .automationDenied),
            (.failed(-1712), .commandFailed), (.failed(-1708), .commandFailed),
            (.failed(nil), .commandFailed)
        ]
        for (outcome, expected) in outcomes {
            let executor = TerminalSessionNavigator.Executor(
                appleScript: { _ in outcome },
                command: { _ in XCTFail("AppleScript must not fall back to a command"); return .exited(0) }
            )
            XCTAssertEqual(TerminalSessionNavigator.navigate(.iTerm(id: "session-123"), executor: executor), expected)
        }
    }

    func testCommandSuccessRequiresCompletedZeroExit() {
        let outcomes: [(TerminalSessionNavigator.CommandOutcome, TerminalSessionNavigationResult)] = [
            (.exited(0), .success), (.exited(1), .commandFailed),
            (.exited(127), .commandFailed), (.failed, .commandFailed), (.timedOut, .commandFailed)
        ]
        for (outcome, expected) in outcomes {
            var received: [String] = []
            let executor = TerminalSessionNavigator.Executor(
                appleScript: { _ in XCTFail("command must not fall back to AppleScript"); return .returned(true) },
                command: { received = $0; return outcome }
            )
            XCTAssertEqual(TerminalSessionNavigator.navigate(.wezTermPane(42), executor: executor), expected)
            XCTAssertEqual(received, ["wezterm", "cli", "activate-pane", "--pane-id", "42"])
        }
    }
}
