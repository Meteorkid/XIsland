import XCTest
@testable import DIBridge

final class TerminalSessionIdentityTests: XCTestCase {
    func testTmuxIdentityTakesPrecedenceOverInheritedOuterTerminal() {
        let environment = [
            "TMUX_PANE": "%3", "WEZTERM_PANE": "42", "KITTY_WINDOW_ID": "9",
            "ITERM_SESSION_ID": "w0t1p0:session-123", "TTY": "/dev/ttys001",
            "TERM_SESSION_ID": "legacy-session"
        ]
        XCTAssertEqual(DIBridge.resolveTermSessionId(environment: environment, tty: "/dev/ttys002"), "tmux:%3")
    }

    func testWezTermAndKittyIdentitiesUseExplicitPaneEnvironment() {
        XCTAssertEqual(DIBridge.resolveTermSessionId(
            environment: ["WEZTERM_PANE": "42", "KITTY_WINDOW_ID": "9", "ITERM_SESSION_ID": "outer"], tty: nil
        ), "wezterm:42")
        XCTAssertEqual(DIBridge.resolveTermSessionId(
            environment: ["KITTY_WINDOW_ID": "9", "ITERM_SESSION_ID": "outer"], tty: nil
        ), "kitty:9")
        XCTAssertEqual(DIBridge.resolveTermSessionId(environment: ["WEZTERM_PANE": "0"], tty: nil), "wezterm:0")
        XCTAssertEqual(DIBridge.resolveTermSessionId(environment: ["KITTY_WINDOW_ID": "0"], tty: nil), "kitty:0")
        XCTAssertEqual(DIBridge.resolveTermSessionId(environment: ["TMUX_PANE": "%0"], tty: nil), "tmux:%0")
    }

    func testITermPreservesSessionTokenBeforeTTYAndLegacyIdentity() {
        let id = "w0t1p2:0B0D70D0-52C6-4C19-A579-F8760CB13821"
        XCTAssertEqual(DIBridge.resolveTermSessionId(
            environment: ["ITERM_SESSION_ID": id, "TTY": "/dev/ttys001", "TERM_SESSION_ID": "legacy"],
            tty: "/dev/ttys002"
        ), "iterm:" + id)
    }

    func testEnvironmentTTYAndActualTTYTakePrecedenceOverLegacyIdentity() {
        XCTAssertEqual(DIBridge.resolveTermSessionId(
            environment: ["TTY": "/dev/ttys001", "TERM_SESSION_ID": "legacy"], tty: "/dev/ttys002"
        ), "tty:/dev/ttys001")
        XCTAssertEqual(DIBridge.resolveTermSessionId(
            environment: ["TERM_SESSION_ID": "legacy"], tty: "/dev/ttys002"
        ), "tty:/dev/ttys002")
    }

    func testLegacyIdentityIsPreservedWhenNoPreciseLocatorExists() {
        XCTAssertEqual(DIBridge.resolveTermSessionId(
            environment: ["TERM_SESSION_ID": "legacy-session:123"], tty: nil
        ), "ts:legacy-session:123")
        XCTAssertEqual(DIBridge.resolveTermSessionId(environment: [:], tty: nil), "")
    }

    func testInvalidPaneIDsCannotFallBackToAnOuterTerminal() {
        for value in ["-1", "+1", "1.0", " 1", "1 ", "１", "1\n2", "1;touch", "$(id)", "999999999999999999999999"] {
            for key in ["WEZTERM_PANE", "KITTY_WINDOW_ID"] {
                XCTAssertEqual(DIBridge.resolveTermSessionId(
                    environment: [key: value, "ITERM_SESSION_ID": "outer", "TERM_SESSION_ID": "legacy"],
                    tty: "/dev/ttys001"
                ), "", "\(key)=\(value)")
            }
        }
        for value in ["3", "%", "%-1", "%1\n", "%1;select-pane", "%999999999999999999999999"] {
            XCTAssertEqual(DIBridge.resolveTermSessionId(
                environment: ["TMUX_PANE": value, "ITERM_SESSION_ID": "outer"], tty: "/dev/ttys001"
            ), "", value)
        }
    }

    func testControlCharactersAndWhitespaceAreRejectedInOpaqueTokens() {
        for value in ["\n", "id\nactivate", "id\rnext", "id\tmore", "id\0more", "id\u{7F}", "id next", " id", String(repeating: "a", count: 507)] {
            XCTAssertEqual(DIBridge.resolveTermSessionId(environment: ["ITERM_SESSION_ID": value], tty: nil), "")
            XCTAssertEqual(DIBridge.resolveTermSessionId(environment: ["TERM_SESSION_ID": value], tty: nil), "")
        }
    }

    func testTTYRequiresAnExactDevicePathWithAlphanumericSuffix() {
        for value in ["/dev/tty", "/dev/ttys001/other", "/dev/tty../other", "/tmp/ttys001", "/dev/tty１", "/dev/ttys001\n", "/dev/ttys001;touch", "/dev/tty" + String(repeating: "s", count: 121)] {
            XCTAssertEqual(DIBridge.resolveTermSessionId(environment: ["TTY": value], tty: nil), "", value)
            XCTAssertEqual(DIBridge.resolveTermSessionId(environment: [:], tty: value), "", value)
        }
        XCTAssertEqual(DIBridge.resolveTermSessionId(
            environment: ["TTY": "/tmp/invalid"], tty: "/dev/ttys003"
        ), "tty:/dev/ttys003")
    }

    func testEmptyEnvironmentValuesDoNotMaskAnAvailablePreciseIdentity() {
        XCTAssertEqual(DIBridge.resolveTermSessionId(
            environment: ["TMUX_PANE": "", "WEZTERM_PANE": "", "KITTY_WINDOW_ID": "", "ITERM_SESSION_ID": "", "TTY": ""],
            tty: "/dev/ttys004"
        ), "tty:/dev/ttys004")
    }
}
