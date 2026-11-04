import SwiftUI

/// iOS 端入口。
///
/// 必须显式提供：SwiftPM 只能产出库/可执行文件，App bundle 的 `@main` 由这个文件承担。
/// 缺少它时，用户在 Xcode 建好 target 后会直接编译失败。
@main
struct XIslandCompanionApp: App {
    /// 在 App 层持有连接，而不是放在视图里。
    ///
    /// 放在 `@State`（视图内）会导致视图重建或切后台时连接被释放——
    /// 表现为"锁屏再解锁就断线"，而重连要重新走一遍 Bonjour 发现。
    @State private var connection = CompanionConnection()
    @State private var relay = WatchRelay.shared

    var body: some Scene {
        WindowGroup {
            CompanionRootView(connection: connection, relay: relay)
        }
    }
}
