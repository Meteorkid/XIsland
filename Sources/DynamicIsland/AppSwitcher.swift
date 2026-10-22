import AppKit

/// 负责在灵动岛应用之间快速切换
///
/// 每个灵动岛使用独立 URL Scheme 进行跨应用通信。
/// URL 格式: `{target-app-name}://{target-app-name}/show`
struct IslandPeerStatus {
    let island: IslandApp
    let isInstalled: Bool
    let isRunning: Bool
    let isProtocolConfigured: Bool
}

@MainActor
final class AppSwitcher {
    static let shared = AppSwitcher()

    private let appName = "xisland"

    /// 灵动岛应用注册表：应用名 → BundleID
    /// 新增灵动岛时在此添加映射
    private let islandApps: [String: String] = [
        "xnook": "com.meteorkid.xnook",
        "xisland": "dev.xisland.app",
    ]

    /// 灵动岛应用注册表：应用名 → URL Scheme
    /// 每个应用使用独立的 URL Scheme，避免 Launch Services 冲突
    private let islandSchemes: [String: String] = [
        "xnook": "xnook",
        "xisland": "xisland",
    ]

    struct Environment {
        var applicationURL: (String) -> URL?
        var open: (URL, URL, @escaping @MainActor (Bool) -> Void) -> Void
        var isVisible: (String) -> Bool
        var isFrontmost: (String) -> Bool
        var setSwitching: (Bool) -> Void
        var hideSource: () -> Void
        var restoreSource: () -> Void
        var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    }

    private let environment: Environment
    private var requestID: UUID?
    private var targetName: String?
    private var cancelTimeout: (() -> Void)?
    private var cancelPoll: (() -> Void)?
    private(set) var lastSwitchFailed = false

    init(environment: Environment? = nil) {
        self.environment = environment ?? Self.liveEnvironment
    }

    private static func applicationURL(for bundleID: String) -> URL? {
        // 优先正式安装位置，避免 URL scheme 被构建目录或备份 App 抢占。
        let name = bundleID == "com.meteorkid.xnook" ? "X Nook.app" : "X Island.app"
        for directory in [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            let url = directory.appendingPathComponent(name)
            if Bundle(url: url)?.bundleIdentifier == bundleID { return url }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static var liveEnvironment: Environment {
        Environment(
            applicationURL: { applicationURL(for: $0) },
            open: { url, appURL, completion in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { app, error in
                    DispatchQueue.main.async { completion(app != nil && error == nil) }
                }
            },
            isVisible: { bundleID in
                IslandHandoffVisibility.isPeerVisible(bundleIdentifier: bundleID, applicationURL: applicationURL(for: bundleID))
            },
            isFrontmost: { bundleID in
                IslandHandoffVisibility.isPeerFrontmost(bundleIdentifier: bundleID, applicationURL: applicationURL(for: bundleID))
            },
            setSwitching: { AppDelegate.shared?.notchWindow?.isSwitchingApps = $0 },
            hideSource: {
                guard let window = AppDelegate.shared?.notchWindow else { return }
                window.isHiddenByIslandSwitch = true
                window.orderOut(nil)
            },
            restoreSource: { AppDelegate.shared?.notchWindow?.showWindow() },
            schedule: { delay, action in
                let work = DispatchWorkItem { action() }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return { work.cancel() }
            }
        )
    }

    /// 当前应用名
    var currentAppName: String? {
        appName
    }

    var currentIsland: IslandApp? {
        IslandApp(rawValue: appName)
    }

    var currentURLScheme: String? {
        islandSchemes[appName]
    }

    /// 切换到下一个灵动岛（跳过未安装的应用）
    func switchToNextIsland() {
        guard let currentName = currentAppName else { return }
        let allNames = Array(islandApps.keys).sorted()

        // 找到下一个已安装的应用
        guard let currentIndex = allNames.firstIndex(of: currentName) else { return }
        let count = allNames.count
        for i in 1...count {
            let nextIndex = (currentIndex + i) % count
            let nextName = allNames[nextIndex]
            if isIslandInstalled(named: nextName) {
                switchToIsland(named: nextName)
                return
            }
        }
        // 没有其他已安装的应用，不做任何操作
    }

    /// 切换到指定的灵动岛
    func switchToIsland(named targetName: String) {
        guard targetName != currentAppName,
              let bundleID = islandApps[targetName],
              let url = switchURL(for: targetName) else { return }
        guard let appURL = environment.applicationURL(bundleID) else {
            cancelSwitch()
            lastSwitchFailed = true
            environment.restoreSource()
            return
        }
        guard self.targetName != targetName else { return }
        cancelSwitch()
        let id = UUID()
        requestID = id
        self.targetName = targetName
        lastSwitchFailed = false
        environment.setSwitching(true)
        cancelTimeout = environment.schedule(8) { [weak self] in self?.failSwitch(id) }
        environment.open(url, appURL) { [weak self] opened in
            guard let self, self.requestID == id else { return }
            if opened { self.checkTarget(id) } else { self.failSwitch(id) }
        }
    }

    private func checkTarget(_ id: UUID) {
        guard requestID == id, let targetName, let bundleID = islandApps[targetName] else { return }
        // 打开请求成功不等于窗口已显示；继续保留来源，直到窗口服务器确认目标岛。
        if environment.isVisible(bundleID) {
            cancelSwitch()
            environment.hideSource()
        } else {
            cancelPoll = environment.schedule(0.1) { [weak self] in self?.checkTarget(id) }
        }
    }

    private func failSwitch(_ id: UUID) {
        guard requestID == id else { return }
        cancelSwitch()
        lastSwitchFailed = true
        environment.restoreSource()
    }

    var isSwitchInProgress: Bool { requestID != nil }

    func cancelSwitch() {
        let wasSwitching = requestID != nil
        requestID = nil
        targetName = nil
        cancelTimeout?(); cancelTimeout = nil
        cancelPoll?(); cancelPoll = nil
        if wasSwitching { environment.setSwitching(false) }
    }

    /// 兼容旧版裸 hide 通知：无正在进行的切换时，只有置顶的目标岛可要求让位。
    func acceptPeerHideRequest(from peer: String? = nil, shownAt: TimeInterval? = nil,
                               after lastExplicitShow: TimeInterval = 0) -> Bool {
        let ready: Bool
        if peer != nil || shownAt != nil {
            guard let peer, let shownAt, shownAt.isFinite, shownAt > lastExplicitShow,
                  otherIslandNames.contains(peer), let bundleID = islandApps[peer] else { return false }
            ready = environment.isVisible(bundleID)
        } else if let targetName, let bundleID = islandApps[targetName] {
            ready = environment.isVisible(bundleID)
        } else {
            ready = otherIslandNames.contains { name in
                islandApps[name].map(environment.isFrontmost) ?? false
            }
        }
        guard ready else { return false }
        cancelSwitch()
        return true
    }

    func isIslandVisible(named name: String) -> Bool {
        guard let bundleID = islandApps[name] else { return false }
        return environment.isVisible(bundleID)
    }

    func switchURL(for targetName: String) -> URL? {
        guard islandApps[targetName] != nil,
              let scheme = islandSchemes[targetName] else { return nil }
        // URL 格式: {targetName}://{targetName}/show
        return URL(string: "\(scheme)://\(targetName)/show")
    }

    func isIslandInstalled(named islandName: String) -> Bool {
        guard let bundleID = islandApps[islandName] else { return false }
        return environment.applicationURL(bundleID) != nil
    }

    func isIslandRunning(named islandName: String) -> Bool {
        guard let bundleID = islandApps[islandName] else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }

    /// 检查另一个应用是否在运行
    func isOtherAppRunning() -> Bool {
        guard let currentName = currentAppName else { return false }
        let otherApps = islandApps.filter { $0.key != currentName }
        return otherApps.values.contains { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 0
        }
    }

    /// 获取其他灵动岛的名称
    var otherIslandNames: [String] {
        guard let currentName = currentAppName else { return [] }
        return islandApps.keys.filter { $0 != currentName }.sorted()
    }

    var otherIsland: IslandApp? {
        otherIslandNames.compactMap(IslandApp.init(rawValue:)).first
    }

    func peerStatus(for island: IslandApp) -> IslandPeerStatus {
        let expectedBundleID = islandApps[island.rawValue]
        let installed = isIslandInstalled(named: island.rawValue)
        let running = isIslandRunning(named: island.rawValue)
        let protocolConfigured = expectedBundleID == registeredHandlerBundleIdentifier(for: island)
        return IslandPeerStatus(
            island: island,
            isInstalled: installed,
            isRunning: running,
            isProtocolConfigured: protocolConfigured
        )
    }

    private func registeredHandlerBundleIdentifier(for island: IslandApp) -> String? {
        guard let scheme = islandSchemes[island.rawValue],
              let url = URL(string: "\(scheme)://island/show"),
              let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        else {
            return nil
        }

        return Bundle(url: applicationURL)?.bundleIdentifier
    }
}
