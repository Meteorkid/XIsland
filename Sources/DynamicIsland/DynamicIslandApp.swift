import SwiftUI

/// 应用入口。
///
/// X Island 是一个无主窗口的 accessory 应用：灵动岛窗口、菜单栏状态项与设置面板
/// 统一由 `AppDelegate` 在启动流程中创建和管理；系统设置入口也转到同一个面板。
@main
struct XIslandApp: App {
    /// 在应用结构体初始化时解析一次命令行 / 环境变量中的测试配置。
    /// 该属性本身不被 `body` 消费，但保留它可维持与 `AppDelegate` 相同的启动求值时序
    /// （测试模式、fixture 等实际由 `AppDelegate` 内部读取）。
    private let testConfiguration = AppTestConfiguration.current()

    /// 将应用生命周期委托给 `AppDelegate`：单实例锁、状态栏、灵动岛窗口、设置窗口等。
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsSceneRedirect { appDelegate.routeSettingsScene() }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.settings + "…") { appDelegate.openPreferences() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// 系统恢复旧 Settings scene 时，只关闭当前托管窗口，不搜索或干预其他窗口。
struct SettingsSceneRedirect: NSViewRepresentable {
    let onRequest: @MainActor () -> Void

    func makeNSView(context: Context) -> SettingsSceneRedirectView {
        SettingsSceneRedirectView(onRequest: onRequest)
    }

    func updateNSView(_ view: SettingsSceneRedirectView, context: Context) {
        view.onRequest = onRequest
        view.scheduleRedirect()
    }
}

@MainActor
final class SettingsSceneRedirectView: NSView {
    var onRequest: @MainActor () -> Void
    private weak var scheduledWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []

    init(onRequest: @escaping @MainActor () -> Void) {
        self.onRequest = onRequest
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        scheduledWindow = nil
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRedirect() }
            })
        }
        scheduleRedirect()
    }

    func scheduleRedirect() {
        guard let window, scheduledWindow !== window else { return }
        scheduledWindow = window
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, self.scheduledWindow === window else { return }
            self.scheduledWindow = nil
            guard window.isVisible else { return }
            window.orderOut(nil)
            window.close()
            self.onRequest()
        }
    }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }
}
