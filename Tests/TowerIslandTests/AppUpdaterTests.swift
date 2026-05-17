import XCTest
@testable import XIsland

final class AppUpdaterTests: XCTestCase {
    final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func append(_ url: URL) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }

        func all() -> [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    final class CommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [(String, [String])] = []

        func append(_ launchPath: String, _ arguments: [String]) {
            lock.lock()
            commands.append((launchPath, arguments))
            lock.unlock()
        }

        func all() -> [(String, [String])] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }
    }

    final class StageRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedStages: [AppUpdaterStage] = []

        func record(_ stage: AppUpdaterStage) {
            lock.lock()
            storedStages.append(stage)
            lock.unlock()
        }

        func stages() -> [AppUpdaterStage] {
            lock.lock()
            defer { lock.unlock() }
            return storedStages
        }
    }

    func testExtractsMountDirectoryFromHdiutilOutput() {
        let output = "/dev/disk16\tGUID_partition_scheme\t\n/dev/disk16s1\tApple_HFS\t/Volumes/X Island 7"

        XCTAssertEqual(AppUpdater.mountDirectory(from: output), "/Volumes/X Island 7")
    }

    func testReturnsNilWhenMountDirectoryLineIsMissing() {
        let output = "/dev/disk16\tGUID_partition_scheme\t\n/dev/disk16s1\tApple_HFS\t"

        XCTAssertNil(AppUpdater.mountDirectory(from: output))
    }

    func testIgnoresTrailingBlankLinesWhenParsingMountDirectory() {
        let output = "/dev/disk16\tGUID_partition_scheme\t\n/dev/disk16s1\tApple_HFS\t/Volumes/X Island 7\n\n"

        XCTAssertEqual(AppUpdater.mountDirectory(from: output), "/Volumes/X Island 7")
    }

    func testDefaultRunCommandSurfacesProcessFailureWithoutCollapsingIt() throws {
        do {
            _ = try AppUpdater.defaultRunCommand(
                "/bin/sh",
                [
                    "-c",
                    #"perl -e 'print "x" x 131072'; exit 7"#
                ]
            )
            XCTFail("Expected command execution to fail.")
        } catch let error as AppUpdater.CommandExecutionError {
            XCTAssertEqual(error.terminationStatus, 7)
            XCTAssertEqual(error.output.count, 131072)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testInstallReportsStagesInOrder() async throws {
        let updater = AppUpdater(
            runCommand: { _, _ in "" },
            downloadFile: { _, _ in },
            relaunchApp: { _ in },
            launchInstallerHelper: { _ in },
            terminateApp: { },
            installImpl: { _, _, _, _, onStage in
                await MainActor.run { onStage(.downloading) }
                await MainActor.run { onStage(.mounting) }
                await MainActor.run { onStage(.installing) }
                await MainActor.run { onStage(.relaunching) }
            }
        )

        let recorder = StageRecorder()
        try await updater.install(
            version: "1.2.5",
            releaseURL: URL(string: "https://example.com/XIsland-1.2.5.dmg")!,
            appPath: "/Applications/X Island.app",
            onStage: { recorder.record($0) }
        )

        XCTAssertEqual(recorder.stages(), [.downloading, .mounting, .installing, .relaunching])
    }

    func testInstallDownloadsMountsAndLaunchesHelperScript() async throws {
        let downloads = URLRecorder()
        let commands = CommandRecorder()
        let helperPath = URLRecorder()
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let updater = AppUpdater(
            runCommand: { launchPath, arguments in
                commands.append(launchPath, arguments)
                return "/dev/disk16\tGUID_partition_scheme\t\n/dev/disk16s1\tApple_HFS\t/Volumes/X Island"
            },
            downloadFile: { sourceURL, destinationURL in
                downloads.append(sourceURL)
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: destinationURL)
            },
            relaunchApp: { _ in },
            launchInstallerHelper: { scriptPath in
                helperPath.append(URL(fileURLWithPath: scriptPath))
            },
            terminateApp: { },
            temporaryDirectoryProvider: {
                tempRoot
            },
            fileExists: { path in
                path == "/Volumes/X Island/X Island.app"
            }
        )

        try await updater.install(
            version: "1.2.5",
            releaseURL: URL(string: "https://example.com/XIsland-1.2.5.dmg")!,
            appPath: "/Applications/X Island.app",
            onStage: { _ in }
        )

        let downloadedURLs = downloads.all()
        XCTAssertEqual(downloadedURLs, [URL(string: "https://example.com/XIsland-1.2.5.dmg")!])

        let recordedCommands = commands.all()
        XCTAssertEqual(recordedCommands.first?.0, "/usr/bin/hdiutil")
        XCTAssertEqual(recordedCommands.first?.1.prefix(2), ["attach", tempRoot.appendingPathComponent("XIsland-1.2.5.dmg").path])

        let launchedHelperPath = try XCTUnwrap(helperPath.all().first)
        let scriptContents = try String(contentsOf: launchedHelperPath, encoding: .utf8)
        XCTAssertTrue(scriptContents.contains("/Volumes/X Island/X Island.app"))
        XCTAssertTrue(scriptContents.contains("/Applications/X Island.app"))
    }

    func testBuildsDmgFilenameFromVersion() {
        XCTAssertEqual(AppUpdater.dmgFilename(for: "1.2.5"), "XIsland-1.2.5.dmg")
    }

    func testBuildsDmgFilenameFromGitHubStyleTag() {
        XCTAssertEqual(AppUpdater.dmgFilename(for: "v1.2.6"), "XIsland-1.2.6.dmg")
    }

    func testAppUpdaterErrorDescriptions() {
        let cases: [(AppUpdaterError, String)] = [
            (.downloadFailed, "Unable to download the update."),
            (.mountFailed, "Unable to mount the downloaded update."),
            (.appNotFound, "The downloaded update did not contain X Island.app."),
            (.installFailed, "Unable to replace the installed app."),
            (.relaunchFailed, "The update installed, but the app could not relaunch."),
            (.integrityCheckFailed, "The downloaded update failed integrity verification."),
            (.codeSigningFailed, "The installed app failed code signing verification.")
        ]

        for (error, description) in cases {
            XCTAssertEqual(error.errorDescription, description)
        }
    }
}
