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
        var hideSourceWithMotion: ((IslandSwitchMotion?) -> Void)? = nil
        var cancelPreview: () -> Void = {}
        var reduceMotion: () -> Bool = { false }
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sourceGeometry: () -> IslandSwitchGeometry? = { nil }
        var startInteractiveSwitch: ((SwipeDirection) -> Bool)? = nil
        var captureAttentionEpoch: () -> IslandAttentionEpoch.Admission? = { nil }
        var isAttentionEpochCurrent: (IslandAttentionEpoch.Admission) -> Bool = { _ in true }
    }

    private let environment: Environment
    private var requestID: UUID?
    private var targetName: String?
    private var pendingMotion: IslandSwitchMotion?
    private var pendingAttentionEpoch: IslandAttentionEpoch.Admission?
    private var acknowledgedMotion: IslandSwitchMotion?
    private var visiblePollsAwaitingMotion = 0
    private(set) var acceptedPeerMotion: IslandSwitchMotion?
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
            hideSource: { AppDelegate.shared?.notchWindow?.hideWindowForIslandSwitch() },
            restoreSource: {
                guard let window = AppDelegate.shared?.notchWindow else { return }
                if window.isVisible { window.cancelIslandSwitchPreview() }
                else { window.showWindow() }
            },
            schedule: { delay, action in
                let work = DispatchWorkItem { action() }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return { work.cancel() }
            },
            hideSourceWithMotion: { AppDelegate.shared?.notchWindow?.hideWindowForIslandSwitch(motion: $0) },
            cancelPreview: { AppDelegate.shared?.notchWindow?.cancelIslandSwitchPreview() },
            reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || AppPreferences.defaults.bool(forKey: "reduceMotion") || AppPreferences.defaults.bool(forKey: "disableAnimations") },
            sourceGeometry: { AppDelegate.shared?.notchWindow?.switchGeometry },
            startInteractiveSwitch: { AppDelegate.shared?.notchWindow?.startLinkedIslandSwitch(direction: $0) ?? false },
            captureAttentionEpoch: { IslandAttentionEpoch.capture() },
            isAttentionEpochCurrent: { IslandAttentionEpoch.isCurrent($0) }
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
    var canSwitchToAnotherIsland: Bool { otherIslandNames.contains { isIslandInstalled(named: $0) } }

    func switchToNextIsland(direction: SwipeDirection? = nil) {
        guard let currentName = currentAppName else { return }
        let allNames = Array(islandApps.keys).sorted()

        // 找到下一个已安装的应用
        guard let currentIndex = allNames.firstIndex(of: currentName) else { return }
        let count = allNames.count
        for i in 1...count {
            let increment = direction == .right ? -i : i
            let nextIndex = (currentIndex + increment + count) % count
            let nextName = allNames[nextIndex]
            if isIslandInstalled(named: nextName) {
                switchToIsland(named: nextName, direction: direction)
                return
            }
        }
        // 没有其他已安装的应用，不做任何操作
    }

    func switchToIslandWithPreview(named targetName: String, direction: SwipeDirection = .left) {
        guard targetName != currentAppName, islandApps[targetName] != nil else { return }
        if environment.startInteractiveSwitch?(direction) == true { return }
        switchToIsland(named: targetName, direction: direction)
    }

    /// 切换到指定的灵动岛
    func switchToIsland(named targetName: String, direction: SwipeDirection? = nil,
                        animationAlreadyPresented: Bool = false) {
        guard targetName != currentAppName, let bundleID = islandApps[targetName] else {
            if animationAlreadyPresented { environment.setSwitching(false) }
            environment.cancelPreview(); return
        }
        guard let appURL = environment.applicationURL(bundleID) else {
            // 画布阶段已阻止交互，但此时尚无requestID，clearSwitchState不会替它解除阻止。
            if animationAlreadyPresented { environment.setSwitching(false) }
            cancelSwitch()
            lastSwitchFailed = true
            environment.restoreSource()
            return
        }
        guard self.targetName != targetName else { return }
        clearSwitchState()
        let id = UUID()
        let motion = direction.map { IslandSwitchMotion(requestID: id, direction: $0,
            reduceMotion: animationAlreadyPresented || environment.reduceMotion(), issuedUptime: environment.uptime(),
            sourceGeometry: environment.sourceGeometry()) }
        guard var url = switchURL(for: targetName, motion: motion) else {
            if animationAlreadyPresented { environment.setSwitching(false) }
            environment.cancelPreview(); return
        }
        let attentionEpoch = environment.captureAttentionEpoch()
        if let attentionEpoch {
            guard let protectedURL = IslandAttentionEpoch.adding(attentionEpoch, to: url) else {
                if animationAlreadyPresented { environment.setSwitching(false) }
                environment.cancelPreview(); return
            }
            url = protectedURL
        }
        requestID = id
        self.targetName = targetName
        pendingMotion = motion
        pendingAttentionEpoch = attentionEpoch
        visiblePollsAwaitingMotion = 0
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
        guard pendingAttentionIsCurrent else { cancelSwitch(); return }
        if environment.isVisible(bundleID) {
            if let acknowledgedMotion, acknowledgedMotion.isTimely(at: environment.uptime()) {
                let readyMotion = acknowledgedMotion.starting(at: acknowledgedMotion.startUptime!,
                    reduceMotion: environment.reduceMotion() || pendingMotion?.reduceMotion == true)
                clearSwitchState()
                if let hide = environment.hideSourceWithMotion { hide(readyMotion) } else { environment.hideSource() }
                return
            }
            // 新端优先使用带事务身份和统一起点的回执；旧端可见后安全退回淡出。
            if pendingMotion != nil, visiblePollsAwaitingMotion < 3 {
                visiblePollsAwaitingMotion += 1
                cancelPoll = environment.schedule(0.05) { [weak self] in self?.checkTarget(id) }
                return
            }
            clearSwitchState()
            if let hide = environment.hideSourceWithMotion { hide(nil) } else { environment.hideSource() }
        } else {
            visiblePollsAwaitingMotion = 0
            cancelPoll = environment.schedule(0.1) { [weak self] in self?.checkTarget(id) }
        }
    }

    private func failSwitch(_ id: UUID) {
        guard requestID == id else { return }
        // 提醒已经夺回显示权时，旧超时/失败不能把来源岛再次显示出来。
        guard pendingAttentionIsCurrent else { cancelSwitch(); return }
        cancelSwitch()
        lastSwitchFailed = true
        environment.restoreSource()
    }

    private var pendingAttentionIsCurrent: Bool {
        pendingAttentionEpoch.map(environment.isAttentionEpochCurrent) ?? true
    }

    var isSwitchInProgress: Bool { requestID != nil }

    func cancelSwitch() {
        clearSwitchState()
        environment.cancelPreview()
    }

    private func clearSwitchState() {
        let wasSwitching = requestID != nil
        requestID = nil
        targetName = nil
        pendingMotion = nil
        pendingAttentionEpoch = nil
        acknowledgedMotion = nil
        visiblePollsAwaitingMotion = 0
        cancelTimeout?(); cancelTimeout = nil
        cancelPoll?(); cancelPoll = nil
        if wasSwitching { environment.setSwitching(false) }
    }

    /// 兼容旧版裸 hide 通知：无正在进行的切换时，只有置顶的目标岛可要求让位。
    func acceptPeerHideRequest(from peer: String? = nil, shownAt: TimeInterval? = nil,
                               after lastExplicitShow: TimeInterval = 0,
                               motion: IslandSwitchMotion? = nil) -> Bool {
        acceptedPeerMotion = nil
        if let motion {
            guard requestID == motion.requestID, targetName == peer,
                  let pendingMotion, pendingMotion.direction == motion.direction,
                  pendingMotion.issuedUptime == motion.issuedUptime,
                  pendingMotion.sourceGeometry == motion.sourceGeometry,
                  motion.startUptime != nil, motion.isTimely(at: environment.uptime()) else { return false }
        }
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
        // orderFront 和 CG 列表之间可能差一帧，保留唯一合法回执等待可见确认。
        if let motion { acknowledgedMotion = motion }
        guard ready else { return false }
        if let motion {
            acceptedPeerMotion = motion.starting(at: motion.startUptime!,
                reduceMotion: environment.reduceMotion() || pendingMotion?.reduceMotion == true)
        }
        clearSwitchState()
        return true
    }

    func isIslandVisible(named name: String) -> Bool {
        guard let bundleID = islandApps[name] else { return false }
        return environment.isVisible(bundleID)
    }

    func switchURL(for targetName: String, motion: IslandSwitchMotion? = nil) -> URL? {
        guard islandApps[targetName] != nil,
              let scheme = islandSchemes[targetName] else { return nil }
        // URL 格式: {targetName}://{targetName}/show
        guard let url = URL(string: "\(scheme)://\(targetName)/show") else { return nil }
        return motion?.adding(to: url) ?? url
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
        let protocolConfigured: Bool
        if let expectedBundleID, let appURL = environment.applicationURL(expectedBundleID) {
            protocolConfigured = Self.supportsSwitchURL(
                bundleInfo: Bundle(url: appURL)?.infoDictionary,
                bundleIdentifier: expectedBundleID,
                scheme: islandSchemes[island.rawValue] ?? ""
            )
        } else {
            protocolConfigured = false
        }
        return IslandPeerStatus(
            island: island,
            isInstalled: installed,
            isRunning: running,
            isProtocolConfigured: protocolConfigured
        )
    }

    /// 定向启动使用目标包自己的 URL 声明；不能要求目标先运行过，也不依赖默认处理器。
    static func supportsSwitchURL(bundleInfo: [String: Any]?, bundleIdentifier: String, scheme: String) -> Bool {
        guard !scheme.isEmpty, bundleInfo?["CFBundleIdentifier"] as? String == bundleIdentifier,
              let types = bundleInfo?["CFBundleURLTypes"] as? [[String: Any]] else { return false }
        return types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }
    }
}
