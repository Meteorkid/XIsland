import AppKit

/// 负责在 X Island 和 X Nook 之间快速切换
@MainActor
final class AppSwitcher {
    static let shared = AppSwitcher()

    private let xnookBundleID = "com.meteorkid.xnook"
    private let xislandBundleID = "dev.xisland.app"

    /// 切换到另一个应用
    func switchToOtherApp(swipeDirection: SwipeDirection? = nil) {
        let currentAppBundleID = Bundle.main.bundleIdentifier
        let targetScheme = currentAppBundleID == xislandBundleID ? "xnook" : "xisland"

        // 通过 URL Scheme 唤醒目标应用
        guard let url = URL(string: "\(targetScheme)://island/show") else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false  // 不自动激活，让目标自行决定显示方式

        NSWorkspace.shared.open(url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if error != nil {
                    // 目标不存在或启动失败，保留当前岛
                    return
                }
                // 指令成功交给 Launch Services，隐藏当前窗口
                self?.hideCurrentIsland()
            }
        }
    }

    /// 隐藏当前岛窗口
    private func hideCurrentIsland() {
        guard let appDelegate = AppDelegate.shared,
              let window = appDelegate.notchWindow else { return }
        window.orderOut(nil)
    }

    /// 在当前岛显示窗口（URL Scheme 收到 show 指令时调用）
    func showCurrentIsland() {
        guard let appDelegate = AppDelegate.shared,
              let window = appDelegate.notchWindow else { return }
        window.showAtMouseScreen()
    }

    /// 检查另一个应用是否在运行
    func isOtherAppRunning() -> Bool {
        let currentAppBundleID = Bundle.main.bundleIdentifier
        let targetBundleID = currentAppBundleID == xislandBundleID ? xnookBundleID : xislandBundleID

        return NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).count > 0
    }

    /// 获取另一个应用的名称
    var otherAppName: String {
        let currentAppBundleID = Bundle.main.bundleIdentifier
        return currentAppBundleID == xislandBundleID ? "X Nook" : "X Island"
    }
}
