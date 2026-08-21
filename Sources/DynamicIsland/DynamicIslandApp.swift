import SwiftUI

/// 应用入口。
///
/// X Island 是一个无主窗口的 accessory 应用：灵动岛窗口、菜单栏状态项与设置面板
/// 统一由 `AppDelegate` 在启动流程中创建和管理。这里只声明一个空的 `Settings` scene，
/// 满足 SwiftUI `App` 对 scene 的最低要求。
@main
struct XIslandApp: App {
    /// 在应用结构体初始化时解析一次命令行 / 环境变量中的测试配置。
    /// 该属性本身不被 `body` 消费，但保留它可维持与 `AppDelegate` 相同的启动求值时序
    /// （测试模式、fixture 等实际由 `AppDelegate` 内部读取）。
    private let testConfiguration = AppTestConfiguration.current()

    /// 将应用生命周期委托给 `AppDelegate`：单实例锁、状态栏、灵动岛窗口、设置窗口等。
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 设置窗口由 `AppDelegate.openPreferences()` 手动创建并展示，
        // 因此这里提供空壳 scene，避免重复创建。
        Settings {
            EmptyView()
        }
    }
}
