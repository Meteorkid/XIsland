import Foundation
import Observation
import WatchConnectivity
import CompanionShared

/// iPhone ⇄ Apple Watch 的转发层。
///
/// 为什么需要它：**watchOS 没有 MultipeerConnectivity**。手表无法直连 Mac，
/// 必须由 iPhone 收到快照后再转发。这也是 CodeIsland 采用的结构。
///
/// 两端职责：
/// - iPhone：把 Mac 推来的摘要塞进 `applicationContext`（系统会保活最新一份），
///   并把手表发来的命令转交给 `CompanionConnection`
/// - Watch：从 `receivedApplicationContext` 读摘要，命令经 `sendMessage` 回传
@MainActor
@Observable
final class WatchRelay: NSObject {
    static let shared = WatchRelay()

    /// Watch 侧读到的摘要。
    private(set) var digest: CompanionDigest?
    /// Watch 侧是否与 iPhone 建立了会话。
    private(set) var isReachable = false

    /// iPhone 侧：把手表命令交给上层处理。
    #if os(iOS)
    var onWatchCommand: ((CompanionCommand) -> Void)?
    #endif

    nonisolated private static let digestKey = "digest"

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    #if os(iOS)
    /// iPhone 侧：把最新摘要转给手表。
    func push(digest: CompanionDigest) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              let data = try? CompanionCodec.encode(digest) else { return }
        // applicationContext 只保留最新一份，正合适：手表醒来即见当前状态。
        try? session.updateApplicationContext([Self.digestKey: data])
    }
    #else
    /// Watch 侧：把命令经 iPhone 转发。
    func send(_ command: CompanionCommand) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              let data = try? CompanionCodec.encode(command) else { return }
        // reachable 时立即送达；否则排进 transferUserInfo，等 iPhone 下次可用。
        if session.isReachable {
            session.sendMessage([Self.digestKey: data], replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo([Self.digestKey: data])
        }
    }
    #endif

    fileprivate func acceptDigest(_ data: Data) {
        guard let digest = try? CompanionCodec.decodeDigest(data) else { return }
        self.digest = digest
    }
}

extension WatchRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            #if os(watchOS)
            if let data = session.receivedApplicationContext[Self.digestKey] as? Data {
                self.acceptDigest(data)
            }
            #endif
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // 换新手表后需要重新激活，否则后续转发全部静默失败。
        WCSession.default.activate()
    }
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.isReachable = session.isReachable }
    }

    #if os(watchOS)
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[Self.digestKey] as? Data else { return }
        Task { @MainActor in self.acceptDigest(data) }
    }
    #endif

    #if os(iOS)
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[Self.digestKey] as? Data,
              let command = try? CompanionCodec.decodeCommand(data) else { return }
        Task { @MainActor in self.onWatchCommand?(command) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[Self.digestKey] as? Data,
              let command = try? CompanionCodec.decodeCommand(data) else { return }
        Task { @MainActor in self.onWatchCommand?(command) }
    }
    #endif
}
