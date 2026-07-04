import XCTest
@testable import XIsland

final class UpdateManagerTests: XCTestCase {
    actor FetchGate {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    actor InstallGate {
        private var permits = 0
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if permits > 0 {
                permits -= 1
                return
            }
            await withCheckedContinuation { continuations.append($0) }
        }

        func resume() {
            if continuations.isEmpty {
                permits += 1
            } else {
                continuations.removeFirst().resume()
            }
        }
    }

    actor URLCapture {
        private(set) var value: URL?

        func store(_ url: URL) {
            value = url
        }

        func get() -> URL? {
            value
        }
    }

    actor StringCapture {
        private(set) var value: String?

        func store(_ value: String?) {
            self.value = value
        }

        func get() -> String? {
            value
        }
    }

    actor FetchSequence {
        private var queue: [Result<Data, Error>]

        init(_ queue: [Result<Data, Error>]) {
            self.queue = queue
        }

        func next() throws -> Data {
            guard !queue.isEmpty else {
                throw URLError(.unknown)
            }
            return try queue.removeFirst().get()
        }
    }

    @MainActor
    private func waitForState(
        _ expectedState: UpdateManager.State,
        in manager: UpdateManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 {
            if manager.state == expectedState {
                XCTAssertEqual(manager.state, expectedState, file: file, line: line)
                return
            }
            await Task.yield()
        }

        XCTAssertEqual(manager.state, expectedState, file: file, line: line)
    }

    @MainActor
    func testParsesGitHubReleasePayload() throws {
        let data = #"{"tag_name":"v1.2.6","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z","assets":[{"name":"XIsland-1.2.6.dmg","browser_download_url":"https://example.com/XIsland-1.2.6.dmg"}]}"#.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)
        let expectedDate = ISO8601DateFormatter().date(from: "2026-04-14T12:00:00Z")

        XCTAssertEqual(release.tagName, "v1.2.6")
        XCTAssertEqual(release.htmlURL, URL(string: "https://example.com/release"))
        XCTAssertEqual(release.publishedAt, expectedDate)
        XCTAssertEqual(release.dmgURL, URL(string: "https://example.com/XIsland-1.2.6.dmg"))
    }

    @MainActor
    func testReleaseInfoPrefersExactVersionedDmgAsset() throws {
        let data = #"{"tag_name":"v1.2.6","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z","assets":[{"name":"XIsland-intel.dmg","browser_download_url":"https://example.com/wrong.dmg"},{"name":"XIsland-1.2.6.dmg","browser_download_url":"https://example.com/XIsland-1.2.6.dmg"}]}"#.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)

        XCTAssertEqual(release.dmgURL, URL(string: "https://example.com/XIsland-1.2.6.dmg"))
    }

    @MainActor
    func testApplyCheckResultTransitionsToUpdateAvailable() throws {
        let manager = UpdateManager()
        let currentVersion = manager.currentVersion
        let remoteVersion = {
            let parts = currentVersion.split(separator: ".").compactMap { Int($0) }
            guard !parts.isEmpty else { return "v1" }
            var bumpedParts = parts
            bumpedParts[bumpedParts.count - 1] += 1
            return "v" + bumpedParts.map(String.init).joined(separator: ".")
        }()
        let data = #"{"tag_name":"\#(remoteVersion)","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z"}"#.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)

        manager.applyCheckResult(release)

        XCTAssertEqual(manager.latestRelease?.tagName, remoteVersion)
        XCTAssertEqual(manager.state, .updateAvailable(version: UpdateManager.normalize(version: remoteVersion)))
        XCTAssertNotNil(manager.lastCheckedAt)
    }

    @MainActor
    func testApplyCheckResultTransitionsToUpToDateForNonNewerRelease() throws {
        let manager = UpdateManager()
        let currentVersion = manager.currentVersion
        let data = #"{"tag_name":"v\#(currentVersion)","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z"}"#.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)

        manager.applyCheckResult(release)

        XCTAssertEqual(manager.latestRelease?.tagName, "v\(currentVersion)")
        XCTAssertEqual(manager.state, .upToDate)
        XCTAssertNotNil(manager.lastCheckedAt)
    }

    @MainActor
    func testApplyCheckResultRejectsMalformedReleaseTag() throws {
        let manager = UpdateManager()
        let currentVersion = manager.currentVersion
        let data = #"{"tag_name":"v\#(currentVersion)-beta","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z"}"#.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)

        manager.applyCheckResult(release)

        XCTAssertEqual(manager.latestRelease?.tagName, "v\(currentVersion)-beta")
        XCTAssertNotNil(manager.lastCheckedAt)
        if case .failed(let message) = manager.state {
            XCTAssertTrue(message.contains("Malformed release version"))
        } else {
            XCTFail("Expected failed state for malformed release tag")
        }
    }

    @MainActor
    func testCheckForUpdatesClearsStaleReleaseOnDecodeFailure() async throws {
        let manager = UpdateManager(fetchReleaseData: {
            Data("not valid json".utf8)
        })
        let staleData = #"{"tag_name":"v9.9.9","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z"}"#.data(using: .utf8)!
        manager.latestRelease = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: staleData)

        await manager.checkForUpdates()

        XCTAssertNil(manager.latestRelease)
        if case .failed(let message) = manager.state {
            XCTAssertEqual(message, "Unable to check for updates.")
        } else {
            XCTFail("Expected failed state when release payload cannot be decoded")
        }
        XCTAssertNotNil(manager.lastCheckedAt)
    }

    @MainActor
    func testInstallUpdateReportsStageProgressAndReturnsToIdle() async throws {
        let gate = InstallGate()
        let release = UpdateManager.ReleaseInfo(
            tagName: "v1.2.6",
            htmlURL: URL(string: "https://example.com/release")!,
            publishedAt: ISO8601DateFormatter().date(from: "2026-04-14T12:00:00Z")!,
            assets: [
                .init(
                    name: "XIsland-1.2.6.dmg",
                    browserDownloadURL: URL(string: "https://example.com/XIsland-1.2.6.dmg")!
                )
            ]
        )
        let expectedDMGURL = URL(string: "https://example.com/XIsland-1.2.6.dmg")!
        let capturedReleaseURL = URLCapture()
        let updater = AppUpdater(
            runCommand: { _, _ in "" },
            downloadFile: { _, _ in },
            relaunchApp: { _ in },
            installImpl: { _, releaseURL, _, _, onStage in
                await capturedReleaseURL.store(releaseURL)
                await MainActor.run { onStage(.downloading) }
                await gate.wait()
                await MainActor.run { onStage(.mounting) }
                await gate.wait()
                await MainActor.run { onStage(.installing) }
                await gate.wait()
                await MainActor.run { onStage(.relaunching) }
                await gate.wait()
            }
        )
        let manager = UpdateManager(updater: updater)
        manager.latestRelease = release

        let task = Task { @MainActor in
            await manager.installUpdate()
        }

        await waitForState(.installing(stage: "downloading"), in: manager)

        await gate.resume()
        await waitForState(.installing(stage: "mounting"), in: manager)

        await gate.resume()
        await waitForState(.installing(stage: "installing"), in: manager)

        await gate.resume()
        await waitForState(.installing(stage: "restarting"), in: manager)

        await gate.resume()
        await task.value

        let recordedURL = await capturedReleaseURL.get()
        XCTAssertEqual(recordedURL, expectedDMGURL)
        XCTAssertEqual(manager.state, UpdateManager.State.idle)
    }

    @MainActor
    func testInstallUpdateRequiresDmgAsset() async {
        let release = UpdateManager.ReleaseInfo(
            tagName: "v1.2.6",
            htmlURL: URL(string: "https://example.com/release")!,
            publishedAt: ISO8601DateFormatter().date(from: "2026-04-14T12:00:00Z")!,
            assets: []
        )
        let manager = UpdateManager()
        manager.latestRelease = release

        await manager.installUpdate()

        if case .failed(let message) = manager.state {
            XCTAssertEqual(message, "No DMG asset is available for this release.")
        } else {
            XCTFail("Expected failed state when the release has no DMG asset")
        }
    }

    @MainActor
    func testInstallUpdateRequiresKnownRelease() async {
        let manager = UpdateManager()

        await manager.installUpdate()

        if case .failed(let message) = manager.state {
            XCTAssertEqual(message, "No release is available to install.")
        } else {
            XCTFail("Expected failed state when no release is available")
        }
    }

    @MainActor
    func testInstallUpdateExtractsSHA256ForVersionedDmgAsset() async throws {
        let expectedHash = String(repeating: "a", count: 64)
        let capturedHash = StringCapture()
        let release = UpdateManager.ReleaseInfo(
            tagName: "v1.2.6",
            htmlURL: URL(string: "https://example.com/release")!,
            publishedAt: ISO8601DateFormatter().date(from: "2026-04-14T12:00:00Z")!,
            assets: [
                .init(
                    name: "XIsland-1.2.6.dmg",
                    browserDownloadURL: URL(string: "https://example.com/XIsland-1.2.6.dmg")!
                )
            ],
            body: "XIsland-1.2.6.dmg SHA256: \(expectedHash)"
        )
        let updater = AppUpdater(
            installImpl: { _, _, _, expectedSHA256, _ in
                await capturedHash.store(expectedSHA256)
            }
        )
        let manager = UpdateManager(updater: updater)
        manager.latestRelease = release

        await manager.installUpdate()

        let actualHash = await capturedHash.get()
        XCTAssertEqual(actualHash, expectedHash)
    }

    @MainActor
    func testCheckForUpdatesCancellationDoesNotStampCompletionOrFailure() async {
        let gate = FetchGate()
        let manager = UpdateManager(fetchReleaseData: {
            await gate.wait()
            if Task.isCancelled {
                throw CancellationError()
            }
            return Data()
        })
        let staleData = #"{"tag_name":"v9.9.9","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z"}"#.data(using: .utf8)!
        let staleRelease = try! UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: staleData)
        manager.latestRelease = staleRelease
        let task = Task { @MainActor in
            await manager.checkForUpdates()
        }

        await Task.yield()
        XCTAssertEqual(manager.state, UpdateManager.State.checking)
        task.cancel()
        await gate.resume()
        await task.value

        XCTAssertEqual(manager.state, UpdateManager.State.idle)
        XCTAssertNil(manager.lastCheckedAt)
        XCTAssertEqual(manager.latestRelease?.tagName, staleRelease.tagName)
    }

    @MainActor
    func testCheckForUpdatesURLErrorCancelledPreservesExistingReleaseState() async throws {
        let manager = UpdateManager(fetchReleaseData: {
            throw URLError(.cancelled)
        })
        let staleData = #"{"tag_name":"v9.9.9","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z"}"#.data(using: .utf8)!
        let staleRelease = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: staleData)
        manager.latestRelease = staleRelease

        await manager.checkForUpdates()

        XCTAssertEqual(manager.state, UpdateManager.State.idle)
        XCTAssertEqual(manager.latestRelease?.tagName, staleRelease.tagName)
        XCTAssertNil(manager.lastCheckedAt)
    }

    @MainActor
    func testCheckForUpdatesTransitionsToUpdateAvailableUsingInjectedData() async throws {
        let currentVersion = UpdateManager().currentVersion
        let parts = currentVersion.split(separator: ".").compactMap { Int($0) }
        var bumpedParts = parts.isEmpty ? [1] : parts
        bumpedParts[bumpedParts.count - 1] += 1
        let remoteVersion = "v" + bumpedParts.map(String.init).joined(separator: ".")
        let data = #"{"tag_name":"\#(remoteVersion)","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z"}"#.data(using: .utf8)!
        let gate = FetchGate()
        let manager = UpdateManager(fetchReleaseData: {
            await gate.wait()
            return data
        })
        let task = Task { @MainActor in
            await manager.checkForUpdates()
        }

        await Task.yield()
        XCTAssertEqual(manager.state, UpdateManager.State.checking)
        await gate.resume()
        await task.value

        XCTAssertEqual(
            manager.state,
            UpdateManager.State.updateAvailable(version: UpdateManager.normalize(version: remoteVersion))
        )
        XCTAssertNotNil(manager.latestRelease)
        XCTAssertNotNil(manager.lastCheckedAt)
    }

    @MainActor
    func testCheckForUpdatesTransitionsToFailedMessageOnFetchError() async {
        let manager = UpdateManager(fetchReleaseData: {
            throw URLError(.notConnectedToInternet)
        })

        await manager.checkForUpdates()

        if case .failed(let message) = manager.state {
            XCTAssertEqual(message, "Unable to check for updates.")
        } else {
            XCTFail("Expected failed state when update check cannot complete")
        }
        XCTAssertNil(manager.latestRelease)
        XCTAssertNotNil(manager.lastCheckedAt)
    }

    @MainActor
    func testCheckForUpdatesRecoversAfterTransientFailure() async {
        let currentVersion = UpdateManager().currentVersion
        let successData = #"{"tag_name":"v\#(currentVersion)","html_url":"https://example.com/release","published_at":"2026-04-15T07:00:00Z","assets":[{"name":"XIsland.dmg","browser_download_url":"https://example.com/XIsland.dmg"}]}"#
            .data(using: .utf8)!
        let sequence = FetchSequence([
            .failure(URLError(.cannotConnectToHost)),
            .success(successData)
        ])
        let manager = UpdateManager(fetchReleaseData: {
            try await sequence.next()
        })

        await manager.checkForUpdates()
        if case .failed(let message) = manager.state {
            XCTAssertEqual(message, "Unable to check for updates.")
        } else {
            XCTFail("Expected first check to fail for transient network error")
        }
        XCTAssertNil(manager.latestRelease)
        XCTAssertNotNil(manager.lastCheckedAt)

        await manager.checkForUpdates()
        XCTAssertEqual(manager.state, .upToDate)
        XCTAssertEqual(manager.latestRelease?.tagName, "v\(currentVersion)")
        XCTAssertNotNil(manager.lastCheckedAt)
    }

    @MainActor
    func testApplyFixtureStampsLastCheckedAtForSeededUpdateScenario() {
        let manager = UpdateManager()
        let fixture = AppTestFixture.UpdateFixture(
            state: .updateAvailable,
            release: UpdateManager.ReleaseInfo(
                tagName: "v1.2.9",
                htmlURL: URL(string: "https://example.com/release")!,
                publishedAt: ISO8601DateFormatter().date(from: "2026-04-15T08:00:00Z")!,
                assets: [
                    .init(
                        name: "XIsland-1.2.9.dmg",
                        browserDownloadURL: URL(string: "https://example.com/XIsland-1.2.9.dmg")!
                    )
                ]
            ),
            version: "1.2.9",
            stage: nil,
            message: nil
        )

        manager.applyFixture(fixture)

        XCTAssertEqual(manager.state, .updateAvailable(version: "1.2.9"))
        XCTAssertNotNil(manager.lastCheckedAt)
    }

    @MainActor
    func testApplyFixtureKeepsLastCheckedAtNilForIdleFixture() {
        let manager = UpdateManager()
        let fixture = AppTestFixture.UpdateFixture(
            state: .idle,
            release: UpdateManager.ReleaseInfo(
                tagName: "v1.2.9",
                htmlURL: URL(string: "https://example.com/release")!,
                publishedAt: ISO8601DateFormatter().date(from: "2026-04-15T08:00:00Z")!,
                assets: []
            ),
            version: nil,
            stage: nil,
            message: nil
        )

        manager.applyFixture(fixture)

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.lastCheckedAt)
        XCTAssertEqual(manager.latestRelease?.tagName, "v1.2.9")
    }

    func testNormalizesReleaseTagsByRemovingLeadingV() {
        XCTAssertEqual(UpdateManager.normalize(version: " v1.2.3 "), "1.2.3")
        XCTAssertEqual(UpdateManager.normalize(version: "V2.0.0"), "2.0.0")
    }

    func testDetectsRemoteVersionIsNewer() {
        XCTAssertTrue(UpdateManager.isRemoteVersionNewer("v1.2.4", than: "1.2.3"))
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2.3", than: "1.2.4"))
    }

    func testTreatsEqualVersionsAsNotNewer() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2.3", than: "1.2.3"))
    }

    func testTreatsMissingPatchComponentAsEqual() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2.0", than: "1.2"))
    }

    func testTreatsMalformedVersionsAsNotNewer() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2.3-beta", than: "1.2.3"))
    }

    func testTreatsEmptyComponentVersionsAsNotNewer() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1..2", than: "1.2.0"))
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer(".1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.", than: "1.0.0"))
    }

    func testTreatsSignedNumericComponentsAsNotNewer() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.-1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.+1.0", than: "1.0.0"))
    }

    func testTreatsMalformedLocalVersionsAsNotNewer() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2.4", than: "1.2.3-beta"))
    }

    func testTreatsWhitespaceOnlyVersionsAsNotNewer() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("   ", than: "1.0.0"))
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.0.1", than: "   "))
    }
}
