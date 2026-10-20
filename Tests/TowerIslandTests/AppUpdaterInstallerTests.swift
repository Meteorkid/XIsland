import XCTest
@testable import XIsland

final class AppUpdaterInstallerTests: XCTestCase {
    private final class InstallerFixture {
        let root: URL
        let app: URL
        let source: URL
        let temporary: URL
        let bin: URL

        init(installed: Bool = true, specialPaths: Bool = false) throws {
            let suffix = specialPaths ? " spaces ' \" $(touch injected) `touch injected` \n" : ""
            root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)" + suffix)
            app = root.appendingPathComponent("Applications" + suffix).appendingPathComponent("X Island.app")
            source = root.appendingPathComponent("volume/X Island.app")
            temporary = root.appendingPathComponent("download")
            bin = root.appendingPathComponent("bin")
            for directory in [app.deletingLastPathComponent(), source, temporary, bin] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try "new".write(to: source.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
            if installed {
                try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
                try "old".write(to: app.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
            }
            try stub("cp", body: #"""
                if [ "$FAILURE" = copy ]; then
                    mkdir -p "$3"
                    printf partial > "$3/marker"
                    exit 9
                fi
                exec /bin/cp "$@"
                """#)
            try stub("codesign", body: #"""
                for last do :; done
                printf 'sign:%s\n' "$last" >> "$EVENTS"
                [ "$FAILURE" != sign ]
                """#)
            try stub("mv", body: #"""
                case "$1" in
                  */previous.app) [ "$FAILURE" != rollback ] || exit 13 ;;
                  */.xisland-upgrade.*/X\ Island.app) [ "$FAILURE" != promote ] || exit 12 ;;
                  *) case "$2" in
                       */previous.app) [ "$FAILURE" != backup ] || exit 11 ;;
                       */failed.app) [ "$FAILURE" != rollback_displace ] || exit 14 ;;
                     esac ;;
                esac
                /bin/mv "$@" || exit $?
                case "$2:$FAILURE" in
                  */previous.app:term_after_backup) kill -TERM "$PPID" ;;
                  "$APP_PATH":hup_after_promote) kill -HUP "$PPID" ;;
                  "$APP_PATH":int_after_promote) kill -INT "$PPID" ;;
                esac
                """#)
            try stub("open", body: #"""
                marker=$(/bin/cat "$1/marker")
                printf 'open:%s\n' "$marker" >> "$EVENTS"
                case "$marker:$FAILURE" in
                  new:open|new:rollback|new:rollback_displace) exit 15 ;;
                esac
                """#)
            try stub("hdiutil", body: #"""
                printf 'detach\n' >> "$EVENTS"
                [ "$FAILURE" != detach ]
                """#)
            try stub("xattr", body: #"[ "$FAILURE" != xattr ]"#)
            try stub("rm", body: #"""
                for last do :; done
                case "$last:$FAILURE" in
                  */.xisland-upgrade.*:cleanup) exit 16 ;;
                esac
                exec /bin/rm "$@"
                """#)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func stub(_ name: String, body: String) throws {
            let path = bin.appendingPathComponent(name)
            try ("#!/bin/sh\nset -eu\n" + body + "\n").write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        func run(failure: String = "") throws -> (status: Int32, output: String) {
            let script = root.appendingPathComponent("installer.sh")
            try AppUpdater.makeInstallerScript(
                currentPID: .max,
                mountedAppPath: source.path,
                appPath: app.path,
                mountDirectory: source.deletingLastPathComponent().path,
                tempDirectory: temporary.path
            ).write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            process.currentDirectoryURL = root
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = bin.path + ":/usr/bin:/bin"
            environment["FAILURE"] = failure
            environment["EVENTS"] = root.appendingPathComponent("events").path
            environment["APP_PATH"] = app.path
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        }

        func marker(at directory: URL? = nil) -> String? {
            try? String(contentsOf: (directory ?? app).appendingPathComponent("marker"), encoding: .utf8)
        }

        func transactions() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: app.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".xisland-upgrade.") }
        }

        var events: String {
            (try? String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)) ?? ""
        }

        func assertClean(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path), file: file, line: line)
            XCTAssertTrue(try transactions().isEmpty, file: file, line: line)
            XCTAssertTrue(events.contains("detach"), file: file, line: line)
        }
    }

    func testCopyFailurePreservesInstalledApp() throws {
        let fixture = try InstallerFixture()
        let result = try fixture.run(failure: "copy")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(fixture.marker(), "old", result.output)
        try fixture.assertClean()
    }

    func testStagedSignatureFailurePreservesInstalledApp() throws {
        let fixture = try InstallerFixture()
        let result = try fixture.run(failure: "sign")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(fixture.marker(), "old", result.output)
        XCTAssertTrue(fixture.events.contains("/.xisland-upgrade."))
        try fixture.assertClean()
    }

    func testBackupRenameFailurePreservesInstalledApp() throws {
        let fixture = try InstallerFixture()
        let result = try fixture.run(failure: "backup")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(fixture.marker(), "old", result.output)
        try fixture.assertClean()
    }

    func testPromotionRenameFailureRestoresInstalledApp() throws {
        let fixture = try InstallerFixture()
        let result = try fixture.run(failure: "promote")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(fixture.marker(), "old", result.output)
        XCTAssertTrue(fixture.events.contains("open:old"))
        try fixture.assertClean()
    }

    func testRelaunchFailureRestoresAndRelaunchesPreviousApp() throws {
        let fixture = try InstallerFixture()
        let result = try fixture.run(failure: "open")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(fixture.marker(), "old", result.output)
        XCTAssertTrue(fixture.events.contains("open:new\nopen:old"))
        try fixture.assertClean()
    }

    func testRollbackRenameFailureRetainsPreviousApp() throws {
        let fixture = try InstallerFixture()
        let result = try fixture.run(failure: "rollback")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertNil(fixture.marker())
        let transaction = try XCTUnwrap(fixture.transactions().only)
        XCTAssertEqual(fixture.marker(at: transaction.appendingPathComponent("previous.app")), "old")
        XCTAssertEqual(fixture.marker(at: transaction.appendingPathComponent("failed.app")), "new")
        XCTAssertTrue(result.output.contains("previous app retained at"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporary.path))
        XCTAssertTrue(fixture.events.contains("detach"))
    }

    func testRollbackDisplacementFailureRetainsBothApps() throws {
        let fixture = try InstallerFixture()
        let result = try fixture.run(failure: "rollback_displace")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(fixture.marker(), "new")
        let transaction = try XCTUnwrap(fixture.transactions().only)
        XCTAssertEqual(fixture.marker(at: transaction.appendingPathComponent("previous.app")), "old")
        XCTAssertTrue(result.output.contains("previous app retained at"))
    }

    func testCatchableSignalsRestorePreviousAppAtRenameBoundaries() throws {
        for (failure, status): (String, Int32) in [("term_after_backup", 143), ("hup_after_promote", 129), ("int_after_promote", 130)] {
            let fixture = try InstallerFixture()
            let result = try fixture.run(failure: failure)

            XCTAssertEqual(result.status, status, failure + result.output)
            XCTAssertEqual(fixture.marker(), "old", failure + result.output)
            try fixture.assertClean()
        }
    }

    func testSuccessfulUpgradeRemovesBackupAndTemporaryArtifacts() throws {
        let fixture = try InstallerFixture()
        let result = try fixture.run()

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(fixture.marker(), "new")
        XCTAssertTrue(fixture.events.contains("/.xisland-upgrade."))
        XCTAssertTrue(fixture.events.contains("open:new"))
        try fixture.assertClean()
    }

    func testFirstInstallSucceedsWithoutPreviousApp() throws {
        let fixture = try InstallerFixture(installed: false)
        let result = try fixture.run()

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(fixture.marker(), "new")
        try fixture.assertClean()
    }

    func testFailedFirstInstallLeavesNoPartialApp() throws {
        for failure in ["copy", "promote", "open", "hup_after_promote"] {
            let fixture = try InstallerFixture(installed: false)
            let result = try fixture.run(failure: failure)

            XCTAssertNotEqual(result.status, 0, failure)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app.path), failure)
            try fixture.assertClean()
        }
    }

    func testCleanupFailureDoesNotRemoveInstalledAppOrBackup() throws {
        let fixture = try InstallerFixture()
        let result = try fixture.run(failure: "cleanup")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(fixture.marker(), "new")
        let transaction = try XCTUnwrap(fixture.transactions().only)
        XCTAssertEqual(fixture.marker(at: transaction.appendingPathComponent("previous.app")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporary.path))
    }

    func testNonfatalAttributeAndDetachFailuresPreserveSuccessfulUpgrade() throws {
        for failure in ["xattr", "detach"] {
            let fixture = try InstallerFixture()
            let result = try fixture.run(failure: failure)

            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertEqual(fixture.marker(), "new")
            if failure == "detach" {
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.temporary.path))
                XCTAssertTrue(result.output.contains("retained"))
                XCTAssertTrue(try fixture.transactions().isEmpty)
            } else {
                try fixture.assertClean()
            }
        }
    }

    func testQuotedPathsSupportUpgradeAndRollbackWithoutShellExpansion() throws {
        for failure in ["", "open"] {
            let fixture = try InstallerFixture(specialPaths: true)
            let result = try fixture.run(failure: failure)

            XCTAssertEqual(result.status == 0, failure.isEmpty, result.output)
            XCTAssertEqual(fixture.marker(), failure.isEmpty ? "new" : "old")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("injected").path))
            try fixture.assertClean()
        }
    }

    func testHashMismatchStopsBeforeMountAndCleansDownload() async throws {
        try await assertPreflightFailure("hash", expected: .integrityCheckFailed)
    }

    func testDownloadFailureCleansPartialDownload() async throws {
        try await assertPreflightFailure("download", expected: .downloadFailed)
    }

    func testMountFailureCleansDownload() async throws {
        try await assertPreflightFailure("mount", expected: .mountFailed)
    }

    func testMissingMountedAppDetachesAndCleansDownload() async throws {
        try await assertPreflightFailure("missing", expected: .appNotFound)
    }

    func testMountedSignatureFailureDetachesAndCleansDownload() async throws {
        try await assertPreflightFailure("sign", expected: .codeSigningFailed)
    }

    func testHelperLaunchFailureDetachesAndCleansDownload() async throws {
        try await assertPreflightFailure("helper", expected: .relaunchFailed)
    }

    func testRejectedTerminationDoesNotLaunchHelperAndCleansDownload() async throws {
        let fixture = try InstallerFixture()
        let commands = AppUpdaterTests.CommandRecorder()
        let helperCalls = AppUpdaterTests.URLRecorder()
        let terminations = AppUpdaterTests.StageRecorder()
        let cancellations = AppUpdaterTests.StageRecorder()
        let temporary = fixture.temporary
        let updater = AppUpdater(
            runCommand: { launchPath, arguments in
                commands.append(launchPath, arguments)
                return "/dev/disk-test\tApple_HFS\t/Volumes/X Island Test"
            },
            downloadFile: { _, destination in try Data("abc".utf8).write(to: destination) },
            launchInstallerHelper: { helperCalls.append(URL(fileURLWithPath: $0)) },
            terminateApp: { terminations.record(.relaunching) },
            prepareTermination: { false },
            cancelTermination: { cancellations.record(.installing) },
            temporaryDirectoryProvider: { temporary },
            fileExists: { _ in true }
        )

        do {
            try await updater.install(version: "2.0.2", releaseURL: URL(string: "https://example.invalid/update.dmg")!,
                                      appPath: fixture.app.path, onStage: { _ in })
            XCTFail("退出准备失败时不能把安装移交给 helper")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, .terminationCancelled)
        }

        XCTAssertTrue(helperCalls.all().isEmpty)
        XCTAssertTrue(terminations.stages().isEmpty)
        XCTAssertTrue(cancellations.stages().isEmpty)
        XCTAssertTrue(commands.all().contains { $0.1.first == "detach" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(fixture.marker(), "old")
    }

    func testPreflightDetachFailureRetainsDownloadWithoutMaskingOriginalError() async throws {
        try await assertPreflightFailure("detach", expected: .relaunchFailed)
    }

    private func assertPreflightFailure(_ failure: String, expected: AppUpdaterError) async throws {
        let fixture = try InstallerFixture()
        let commands = AppUpdaterTests.CommandRecorder()
        let helperCalls = AppUpdaterTests.URLRecorder()
        let terminations = AppUpdaterTests.StageRecorder()
        let cancellations = AppUpdaterTests.StageRecorder()
        let temporary = fixture.temporary
        let updater = AppUpdater(
            runCommand: { launchPath, arguments in
                commands.append(launchPath, arguments)
                if (failure == "mount" && arguments.first == "attach") || (failure == "sign" && launchPath == "/usr/bin/codesign")
                    || (failure == "detach" && arguments.first == "detach") {
                    throw CocoaError(.fileReadUnknown)
                }
                return "/dev/disk-test\tApple_HFS\t/Volumes/X Island Test"
            },
            downloadFile: { _, destination in
                try Data("abc".utf8).write(to: destination)
                if failure == "download" { throw CocoaError(.fileWriteUnknown) }
            },
            relaunchApp: { _ in },
            launchInstallerHelper: { script in
                helperCalls.append(URL(fileURLWithPath: script))
                throw CocoaError(.executableNotLoadable)
            },
            terminateApp: { terminations.record(.relaunching) },
            prepareTermination: { true },
            cancelTermination: { cancellations.record(.installing) },
            temporaryDirectoryProvider: { temporary },
            fileExists: { _ in failure != "missing" }
        )

        do {
            try await updater.install(
                version: "1.2.5",
                releaseURL: URL(string: "https://example.invalid/update.dmg")!,
                appPath: fixture.app.path,
                expectedSHA256: failure == "hash" ? String(repeating: "0", count: 64) : "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                onStage: { _ in }
            )
            XCTFail("Expected preflight failure: \(failure)")
        } catch {
            XCTAssertEqual(error as? AppUpdaterError, expected)
        }

        XCTAssertEqual(fixture.marker(), "old")
        XCTAssertEqual(FileManager.default.fileExists(atPath: temporary.path), failure == "detach")
        XCTAssertTrue(terminations.stages().isEmpty)
        XCTAssertEqual(helperCalls.all().count, ["helper", "detach"].contains(failure) ? 1 : 0)
        XCTAssertEqual(cancellations.stages().count, ["helper", "detach"].contains(failure) ? 1 : 0)
        let shouldDetach = ["missing", "sign", "helper", "detach"].contains(failure)
        XCTAssertEqual(commands.all().contains { $0.1.first == "detach" }, shouldDetach)
        if ["hash", "download"].contains(failure) {
            XCTAssertTrue(commands.all().isEmpty)
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
