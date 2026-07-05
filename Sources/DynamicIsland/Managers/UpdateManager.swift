import Observation
import AppKit
import Foundation
import os.log

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
        let body: String?

        init(tagName: String, htmlURL: URL, publishedAt: Date, assets: [Asset] = [], body: String? = nil) {
            self.tagName = tagName
            self.htmlURL = htmlURL
            self.publishedAt = publishedAt
            self.assets = assets
            self.body = body
        }

        var normalizedVersion: String {
            UpdateManager.normalize(version: tagName)
        }

        var dmgURL: URL? {
            let expectedName = AppUpdater.dmgFilename(for: normalizedVersion)
            return assets.first(where: { $0.name.compare(expectedName, options: .caseInsensitive) == .orderedSame })?.browserDownloadURL
                ?? assets.first(where: { $0.name.localizedCaseInsensitiveContains(".dmg") })?.browserDownloadURL
        }

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
            case body
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try container.decode(String.self, forKey: .tagName)
            htmlURL = try container.decode(URL.self, forKey: .htmlURL)
            publishedAt = try container.decode(Date.self, forKey: .publishedAt)
            assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
            body = try container.decodeIfPresent(String.self, forKey: .body)
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

    /// 是否开启自动检查更新
    var autoCheckForUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "autoCheckForUpdates") }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckForUpdates") }
    }

    @ObservationIgnored private let fetchReleaseData: ReleaseFetcher
    @ObservationIgnored private let updater: AppUpdater
    @ObservationIgnored private var autoCheckTimer: Timer?

    static let githubReleaseDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let latestReleaseURL = URL(string: "https://github.com/Meteorkid/XIsland/releases/latest")!
    init(
        fetchReleaseData: @escaping ReleaseFetcher = UpdateManager.fetchLatestReleaseData,
        updater: AppUpdater = AppUpdater()
    ) {
        self.fetchReleaseData = fetchReleaseData
        self.updater = updater
        // 注册默认设置
        UserDefaults.standard.register(defaults: [
            "autoCheckForUpdates": true
        ])
    }

    /// 启动自动检查更新（应用启动时调用）
    func startAutoCheck() {
        stopAutoCheck()
        guard autoCheckForUpdates else { return }

        // 启动时立即检查一次
        Task { @MainActor in
            await checkForUpdates()
        }

        // 每 24 小时检查一次
        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.autoCheckForUpdates else { return }
                await self.checkForUpdates()
            }
        }
    }

    /// 停止自动检查
    func stopAutoCheck() {
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil
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

        let expectedSHA256: String?
        if let body = release.body {
            let dmgFilename = AppUpdater.dmgFilename(for: release.normalizedVersion)
            expectedSHA256 = Self.extractSHA256(from: body, for: dmgFilename)
            if expectedSHA256 == nil {
                os_log(.info, "SHA256 not found in release notes for %{public}@", dmgFilename)
                // SHA256 缺失时提示用户
                state = .failed(message: "Release notes 中未包含 SHA256 校验和，无法验证下载完整性。请手动下载安装。")
                return
            }
        } else {
            expectedSHA256 = nil
            state = .failed(message: "Release notes 为空，无法验证下载完整性。请手动下载安装。")
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
                expectedSHA256: expectedSHA256,
                onStage: stageHandler
            )
            state = .idle
        } catch {
            state = .failed(message: "Unable to install the update.")
        }
    }

    nonisolated private static func extractSHA256(from releaseBody: String, for filename: String) -> String? {
        let escapedFilename = NSRegularExpression.escapedPattern(for: filename)
        let pattern = "\(escapedFilename).*?([a-fA-F0-9]{64})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(releaseBody.startIndex..., in: releaseBody)
        guard let match = regex.firstMatch(in: releaseBody, options: [], range: range),
              let hashRange = Range(match.range(at: 1), in: releaseBody) else {
            return nil
        }
        return String(releaseBody[hashRange])
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

    nonisolated static func releaseDataFromLatestRedirectURL(_ finalURL: URL, checkedAt: Date, body: String? = nil) throws -> Data {
        let pathComponents = finalURL.pathComponents
        guard pathComponents.count >= 6,
              pathComponents[1].lowercased() == "meteorkid",
              pathComponents[2].lowercased() == "xisland",
              pathComponents[3] == "releases",
              pathComponents[4] == "tag"
        else {
            throw URLError(.badServerResponse)
        }

        let tag = pathComponents[5]
        guard !tag.isEmpty else {
            throw URLError(.badServerResponse)
        }

        // 注意：不再伪造 DMG URL。如果没有真实的 DMG 资产，assets 数组为空，
        // 用户将看到 "Download..." 而非 "Install..."，点击后会打开发布页面。
        var payload: [String: Any] = [
            "tag_name": tag,
            "html_url": finalURL.absoluteString,
            "published_at": ISO8601DateFormatter().string(from: checkedAt),
            "assets": []
        ]
        if let body {
            payload["body"] = body
        }

        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func fetchLatestReleaseData() async throws -> Data {
        // 获取重定向 URL 以确定最新版本 tag
        var headRequest = URLRequest(url: latestReleaseURL)
        headRequest.httpMethod = "HEAD"
        headRequest.setValue("XIsland", forHTTPHeaderField: "User-Agent")

        let (_, headResponse) = try await URLSession.shared.data(for: headRequest)
        guard let httpResponse = headResponse as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let finalURL = headResponse.url else {
            throw URLError(.badServerResponse)
        }

        // 从 GitHub API 获取 release body（包含 SHA256 校验和）
        let pathComponents = finalURL.pathComponents
        guard pathComponents.count >= 6,
              pathComponents[3] == "releases",
              pathComponents[4] == "tag"
        else {
            return try releaseDataFromLatestRedirectURL(finalURL, checkedAt: Date())
        }
        let tag = pathComponents[5]
        let apiURL = URL(string: "https://api.github.com/repos/Meteorkid/XIsland/releases/tags/\(tag)")!
        var apiRequest = URLRequest(url: apiURL)
        apiRequest.setValue("XIsland", forHTTPHeaderField: "User-Agent")
        apiRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        var body: String? = nil
        if let (apiData, apiResponse) = try? await URLSession.shared.data(for: apiRequest),
           let apiHTTPResponse = apiResponse as? HTTPURLResponse,
           (200..<300).contains(apiHTTPResponse.statusCode) {
            if (try? githubReleaseDecoder.decode(ReleaseInfo.self, from: apiData)) != nil {
                return apiData
            }
            if let json = try? JSONSerialization.jsonObject(with: apiData) as? [String: Any] {
                body = json["body"] as? String
            }
        }

        return try releaseDataFromLatestRedirectURL(finalURL, checkedAt: Date(), body: body)
    }
}
