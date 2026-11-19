import AppKit

/// 用户在客户端里直接查看会话后，把「完成待查看」标记清掉。
///
/// 依据是窗口标题：客户端把当前会话或项目写进标题，若某个待查看会话的标题出现在
/// 目标应用的窗口标题里，就认为它已被查看。标题不含会话名时不做任何处理，避免误清。
@MainActor
final class ViewedSessionObserver {
    static let shared = ViewedSessionObserver()
    private var token: NSObjectProtocol?

    func start(manager: SessionManager) {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak manager] note in
            guard let manager,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }
            guard let agent = AgentType.allCases.first(where: { $0.meta.bundleIds.contains(bundleId) }) else { return }
            let titles = Self.windowTitles(of: app.processIdentifier)
            guard !titles.isEmpty else { return }
            for session in manager.sessions
            where session.agentType == agent && session.completionNeedsReview {
                let title = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard title.count >= 4 else { continue }
                if titles.contains(where: { $0.localizedCaseInsensitiveContains(title) }) {
                    manager.markCompletionReviewed(sessionID: session.id)
                }
            }
        }
    }

    /// 窗口标题需要屏幕录制权限；拿不到时返回空数组，调用方不做任何标记。
    private static func windowTitles(of pid: pid_t) -> [String] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return windows.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int32, owner == pid,
                  let name = entry[kCGWindowName as String] as? String,
                  !name.isEmpty else { return nil }
            return name
        }
    }
}
