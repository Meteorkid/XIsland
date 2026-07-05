import AppKit

/// 负责在灵动岛应用之间快速切换
///
/// 每个灵动岛使用独立 URL Scheme 进行跨应用通信。
/// URL 格式: `{target-app-name}://island/show`
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
    private let islandSchemes: [String: String] = [
        "xnook": "xnook",
        "xisland": "xisland",
    ]

    /// 用于延迟清除 isSwitchingApps 标志的 WorkItem
    private var clearSwitchingAppsWorkItem: DispatchWorkItem?

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
        // 防止切换到自身
        guard targetName != currentAppName,
              islandApps[targetName] != nil else { return }

        // 检查目标应用是否已安装
        guard isIslandInstalled(named: targetName) else {
            // 目标应用未安装，不执行切换
            return
        }

        // 设置切换标志，防止 activeSpaceDidChange 重新显示窗口
        if let window = AppDelegate.shared?.notchWindow {
            window.isSwitchingApps = true
        }

        // 通过目标应用独立的 URL Scheme 唤醒它
        guard let url = switchURL(for: targetName) else {
            AppDelegate.shared?.notchWindow?.isSwitchingApps = false
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    // 目标未确认显示，立即清除切换标志
                    AppDelegate.shared?.notchWindow?.isSwitchingApps = false
                } else {
                    // 成功打开 URL，延迟清除切换标志（确保空间切换完成）
                    // 使用 DispatchWorkItem 以便在需要时取消
                    let clearWork = DispatchWorkItem { [weak self] in
                        guard self != nil else { return }
                        AppDelegate.shared?.notchWindow?.isSwitchingApps = false
                    }
                    self.clearSwitchingAppsWorkItem = clearWork
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: clearWork)
                }
            }
        }
    }

    func switchURL(for targetName: String) -> URL? {
        guard islandApps[targetName] != nil,
              let scheme = islandSchemes[targetName] else { return nil }
        return URL(string: "\(scheme)://island/show")
    }

    /// 在当前岛显示窗口（URL Scheme 收到 show 指令时调用）
    func showCurrentIsland() {
        guard let appDelegate = AppDelegate.shared,
              let window = appDelegate.notchWindow else { return }
        window.showAtMouseScreen()
    }

    func isIslandInstalled(named islandName: String) -> Bool {
        guard let bundleID = islandApps[islandName] else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
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
