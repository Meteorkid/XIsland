import SwiftUI

/// 保留对可观察管理器的读取，让异步授权检测及时更新已经打开的窗口。
struct IntegrationSetupHost: View {
    let manager: IntegrationSetupManager
    let onOpenClient: (AgentType) -> Void
    let onOpenGuide: (AgentType) -> Void
    let onLater: () -> Void
    var onPrepareFiles: ((AgentType) -> Void)? = nil

    var body: some View {
        IntegrationSetupView(rows: manager.rows, isRefreshing: manager.isRefreshing,
            onConfigure: { agent in Task { await manager.configure(agent) } },
            onOpenClient: onOpenClient, onOpenGuide: onOpenGuide,
            onRefresh: { Task { await manager.refresh(prepareAutomatically: true) } },
            onLater: onLater, onPrepareFiles: onPrepareFiles)
    }
}
