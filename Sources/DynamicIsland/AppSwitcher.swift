import AppKit

/// 负责在灵动岛应用之间快速切换
///
/// 每个灵动岛使用独立 URL Scheme 进行跨应用通信。
/// URL 格式: `{target-app-name}://island/show`
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

    var currentURLScheme: String? {
        islandSchemes[appName]
    }

    /// 切换到下一个灵动岛
    func switchToNextIsland() {
        guard let currentName = currentAppName else { return }
        let allNames = Array(islandApps.keys).sorted()
        guard let currentIndex = allNames.firstIndex(of: currentName) else { return }
        let nextIndex = (currentIndex + 1) % allNames.count
        switchToIsland(named: allNames[nextIndex])
    }

    /// 切换到指定的灵动岛
    func switchToIsland(named targetName: String) {
        // 防止切换到自身
        guard targetName != currentAppName,
              islandApps[targetName] != nil else { return }

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
}
