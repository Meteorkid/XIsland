import Observation
import AppKit
import Foundation

@MainActor
@Observable
final class UpdateManager {
    typealias ReleaseFetcher = () async throws -> Data

    struct ReleaseInfo: Codable, Equatable {
        struct Asset: Codable, Equatable {
            let name: String
            let browserDownloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let publishedAt: Date
        let assets: [Asset]

        init(tagName: String, htmlURL: URL, publishedAt: Date, assets: [Asset] = []) {
            self.tagName = tagName
            self.htmlURL = htmlURL
            self.publishedAt = publishedAt
            self.assets = assets
        }

        var normalizedVersion: String {
            UpdateManager.normalize(version: tagName)
        }

        var dmgURL: URL? {
            assets.first(where: { $0.name.localizedCaseInsensitiveContains(".dmg") })?.browserDownloadURL
        }

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try container.decode(String.self, forKey: .tagName)
            htmlURL = try container.decode(URL.self, forKey: .htmlURL)
            publishedAt = try container.decode(Date.self, forKey: .publishedAt)
            assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String)
        case installing(stage: String)
        case failed(message: String)
    }

    var state: State = .idle
    var latestRelease: ReleaseInfo?
    var lastCheckedAt: Date?
    @ObservationIgnored private let fetchReleaseData: ReleaseFetcher
    @ObservationIgnored private let updater: AppUpdater

    static let githubReleaseDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let latestReleaseURL = URL(string: "https://github.com/user/xisland/releases/latest")!
    init(
        fetchReleaseData: @escaping ReleaseFetcher = UpdateManager.fetchLatestReleaseData,
        updater: AppUpdater = AppUpdater()
    ) {
        self.fetchReleaseData = fetchReleaseData
        self.updater = updater
    }

    var currentVersion: String {
        let rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return Self.normalize(version: rawVersion)
    }

    var installedAppPath: String {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.path
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           let installedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return installedURL.path
        }

        return "/Applications/X Island.app"
    }

    nonisolated static func normalize(version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "v" || first == "V" else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }

    nonisolated static func isRemoteVersionNewer(_ remote: String, than local: String) -> Bool {
        guard let remoteParts = normalizedVersionParts(remote),
              let localParts = normalizedVersionParts(local) else {
            return false
        }
        let upperBound = max(remoteParts.count, localParts.count)

        for index in 0..<upperBound {
            let remotePart = index < remoteParts.count ? remoteParts[index] : 0
            let localPart = index < localParts.count ? localParts[index] : 0

            if remotePart > localPart {
                return true
            }
            if remotePart < localPart {
                return false
            }
        }

        return false
    }

    nonisolated private static func normalizedVersionParts(_ version: String) -> [Int]? {
        let components = normalize(version: version).split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty else { return nil }

        var parts: [Int] = []
        parts.reserveCapacity(components.count)

        for component in components {
            guard !component.isEmpty else { return nil }
            guard component.allSatisfy({ $0.isNumber }) else { return nil }
            guard let value = Int(component) else { return nil }
            parts.append(value)
        }

        return parts
    }

    func checkForUpdates() async {
        state = .checking

        do {
            let data = try await fetchReleaseData()
            let release = try Self.githubReleaseDecoder.decode(ReleaseInfo.self, from: data)
            applyCheckResult(release)
        } catch is CancellationError {
            state = .idle
        } catch let urlError as URLError where urlError.code == .cancelled {
            state = .idle
        } catch {
            latestRelease = nil
            state = .failed(message: "Unable to check for updates.")
            lastCheckedAt = Date()
        }
    }

    func applyCheckResult(_ release: ReleaseInfo) {
        latestRelease = release
        lastCheckedAt = Date()

        guard Self.normalizedVersionParts(release.normalizedVersion) != nil else {
            state = .failed(message: "Malformed release version: \(release.tagName)")
            return
        }

        guard Self.isRemoteVersionNewer(release.normalizedVersion, than: currentVersion) else {
            state = .upToDate
            return
        }

        state = .updateAvailable(version: release.normalizedVersion)
    }

    func installUpdate() async {
        guard let release = latestRelease else {
            state = .failed(message: "No release is available to install.")
            return
        }
        guard let dmgURL = release.dmgURL else {
            state = .failed(message: "No DMG asset is available for this release.")
            return
        }

        let stageHandler: @MainActor (AppUpdaterStage) -> Void = { [weak self] stage in
            self?.state = .installing(stage: Self.installStageDescription(for: stage))
        }

        do {
            try await updater.install(
                version: release.normalizedVersion,
                releaseURL: dmgURL,
                appPath: installedAppPath,
                onStage: stageHandler
            )
            state = .idle
        } catch {
            state = .failed(message: "Unable to install the update.")
        }
    }

    func applyFixture(_ fixture: AppTestFixture.UpdateFixture?) {
        latestRelease = fixture?.release
        lastCheckedAt = nil

        guard let fixture else {
            state = .idle
            return
        }

        switch fixture.state {
        case .idle:
            state = .idle
        case .checking:
            state = .checking
            lastCheckedAt = Date()
        case .upToDate:
            state = .upToDate
            lastCheckedAt = Date()
        case .updateAvailable:
            state = .updateAvailable(version: fixture.version ?? fixture.release?.normalizedVersion ?? "")
            lastCheckedAt = Date()
        case .installing:
            state = .installing(stage: fixture.stage ?? "downloading")
            lastCheckedAt = Date()
        case .failed:
            state = .failed(message: fixture.message ?? "Fixture configured failure.")
            lastCheckedAt = Date()
        }
    }

    nonisolated private static func installStageDescription(for stage: AppUpdaterStage) -> String {
        switch stage {
        case .downloading:
            return "downloading"
        case .mounting:
            return "mounting"
        case .installing:
            return "installing"
        case .relaunching:
            return "restarting"
        }
    }

    nonisolated static func releaseDataFromLatestRedirectURL(_ finalURL: URL, checkedAt: Date) throws -> Data {
        let pathComponents = finalURL.pathComponents
        guard pathComponents.count >= 6,
              pathComponents[1] == "g535879",
              pathComponents[2] == "xisland",
              pathComponents[3] == "releases",
              pathComponents[4] == "tag"
        else {
            throw URLError(.badServerResponse)
        }

        let tag = pathComponents[5]
        guard !tag.isEmpty else {
            throw URLError(.badServerResponse)
        }

        let dmgURL = URL(string: "https://github.com/user/xisland/releases/download")!
            .appendingPathComponent(tag)
            .appendingPathComponent("XIsland.dmg")

        let payload: [String: Any] = [
            "tag_name": tag,
            "html_url": finalURL.absoluteString,
            "published_at": ISO8601DateFormatter().string(from: checkedAt),
            "assets": [
                [
                    "name": "XIsland.dmg",
                    "browser_download_url": dmgURL.absoluteString
                ]
            ]
        ]

        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func fetchLatestReleaseData() async throws -> Data {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "HEAD"
        request.setValue("XIsland", forHTTPHeaderField: "User-Agent")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let finalURL = response.url else {
            throw URLError(.badServerResponse)
        }
        return try releaseDataFromLatestRedirectURL(finalURL, checkedAt: Date())
    }
}
