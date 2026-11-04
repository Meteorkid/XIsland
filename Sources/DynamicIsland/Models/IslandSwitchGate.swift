import Foundation

/// 岛切换的让位判定。
///
/// 背景：仅安装、未运行的 XNook 无法接管显示。若此时仍让位，本岛隐藏后没有接管者，
/// 用户会彻底找不到窗口。因此「是否有对端正在运行」必须成为让位的前置条件，
/// 而不是只看「是否安装」。
enum IslandSwitchGate {
    /// 是否允许发起切换。没有对端在运行时不应切换，也不应隐藏。
    static func canInitiateSwitch(isAnyPeerRunning: Bool) -> Bool {
        isAnyPeerRunning
    }

    /// 让位后是否需要兜底恢复：仍隐藏、且没有任何对端在运行。
    static func shouldRestoreAfterHandoff(isHiddenByIslandSwitch: Bool,
                                          isVisible: Bool,
                                          isAnyPeerRunning: Bool) -> Bool {
        isHiddenByIslandSwitch && !isVisible && !isAnyPeerRunning
    }
}
