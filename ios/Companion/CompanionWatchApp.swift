import SwiftUI

/// watchOS 端入口。
///
/// 与 iOS 端分开成独立 `@main`：Watch App 是独立 target，
/// 两个 `@main` 不能出现在同一个 target 里，所以用 `#if os(watchOS)` 隔离。
#if os(watchOS)
@main
struct XIslandWatchApp: App {
    var body: some Scene {
        WindowGroup {
            CompanionWatchView()
        }
    }
}
#endif
