import Foundation
import MultipeerConnectivity
import Observation
import CompanionShared

#if os(iOS)
import UIKit
#endif

/// iPhone / Watch 侧的连接器：浏览局域网里的 Mac、接收快照、下发命令。
///
/// 与 Mac 端的约定：
/// - serviceType 必须与 `CompanionPublisher` 一致
/// - 邀请时把协议版本放进 context，Mac 据此拒绝版本不符的端
/// - 命令一律带 sessionId
@MainActor
@Observable
final class CompanionConnection: NSObject {

    enum State: Equatable {
        case idle
        case searching
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var snapshot: CompanionSnapshot?
    private(set) var digest: CompanionDigest?
    private(set) var lastError: String?

    /// 为 true 时才允许下发 approve / deny / answer。
    ///
    /// 由 Mac 端在快照里下发的 `allowsDecisions` 决定，**不接受手机端自行放开**——
    /// 否则任何连上来的设备都能给自己授权审批。
    private(set) var remoteDecisionsAllowed = false

    private static let serviceType = "xisland-buddy"

    private let peerID: MCPeerID
    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?
    /// 已收到的最大序号，用于丢弃迟到的旧包。快照与摘要分别记录。
    private var latestSnapshotSequence: UInt64 = 0
    private var latestDigestSequence: UInt64 = 0
    /// 是否经历过一次后台。回前台时据此决定是否重建连接，
    /// 而不是信任可能已陈旧的 `connectedPeers`。
    private var wasBackgrounded = false

    /// 序号所属的通道。快照与摘要复用同一串序号，但必须分别判定。
    private enum Channel { case snapshot, digest }

    override init() {
        self.peerID = MCPeerID(displayName: UIDeviceName.current)
        super.init()
    }

    // MARK: - 生命周期

    func start() {
        guard session == nil else { return }
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()

        self.session = session
        self.browser = browser
        state = .searching
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        browser = nil
        session = nil
        state = .idle
        wasBackgrounded = false
    }

    func reconnect() {
        stop()
        start()
    }

    /// 应用回到前台时调用。
    ///
    /// iOS 会在后台挂断 Multipeer 会话，且 `MCSession` 不会自动恢复；
    /// 更麻烦的是 `connectedPeers` 可能仍是陈旧的非空值——
    /// 若只看它决定"无需重连"，就会永久停在断线状态，且发现也已被停掉。
    ///
    /// 因此这里不信任 `connectedPeers`：只要进过后台就重建。
    func handleForeground() {
        guard wasBackgrounded else {
            // 没进过后台：确保发现仍在运行即可。
            if browser == nil { start() }
            return
        }
        wasBackgrounded = false
        reconnect()
    }

    /// 应用进入后台时调用。停止发现以减少无谓唤醒；
    /// 会话本身交给系统回收，回前台时统一重建。
    func handleBackground() {
        wasBackgrounded = true
        browser?.stopBrowsingForPeers()
    }

    private var hasConnectedPeer: Bool {
        guard let session else { return false }
        return !session.connectedPeers.isEmpty
    }

    // MARK: - 下发

    func send(_ command: CompanionCommand) {
        guard let session, !session.connectedPeers.isEmpty else {
            lastError = "未连接"
            return
        }
        if command.decidesForTheUser, !remoteDecisionsAllowed {
            lastError = "这台 Mac 未开启远程审批"
            return
        }
        guard let data = try? CompanionCodec.encode(command) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    func approve(_ sessionID: String) { send(.approve(sessionId: sessionID)) }
    func deny(_ sessionID: String) { send(.deny(sessionId: sessionID)) }
    func answer(_ sessionID: String, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(.answer(sessionId: sessionID, text: text))
    }

    // MARK: - 接收

    fileprivate func accept(_ data: Data) {
        // 先按摘要解，再按快照解：两种载荷都走同一条通道。
        if let digest = try? CompanionCodec.decodeDigest(data) {
            guard acceptSequence(digest.sequence, channel: .digest) else { return }
            self.digest = digest
            // 能力位以 Mac 端下发的为准。
            self.remoteDecisionsAllowed = digest.allowsDecisions
            return
        }
        if let snapshot = try? CompanionCodec.decodeSnapshot(data) {
            guard acceptSequence(snapshot.sequence, channel: .snapshot) else { return }
            self.snapshot = snapshot
            self.digest = CompanionDigest(snapshot: snapshot)
            self.remoteDecisionsAllowed = snapshot.allowsDecisions
            return
        }
    }

    /// 序号必须严格递增，否则丢弃——防止网络乱序让界面回跳。
    ///
    /// **两条通道各记各的**：快照与摘要复用同一串序号，若共用一个游标，
    /// 摘要会先把序号推高，随后到达的快照（序号相同）会被误判为旧包而丢弃——
    /// 表现是"手机只显示一条摘要，完整列表永远不出现"。
    private func acceptSequence(_ value: UInt64, channel: Channel) -> Bool {
        let latest = latestSequence(for: channel)
        guard value > latest else { return false }
        setLatestSequence(value, for: channel)
        return true
    }

    private func latestSequence(for channel: Channel) -> UInt64 {
        switch channel {
        case .snapshot: return latestSnapshotSequence
        case .digest: return latestDigestSequence
        }
    }

    private func setLatestSequence(_ value: UInt64, for channel: Channel) {
        switch channel {
        case .snapshot: latestSnapshotSequence = value
        case .digest: latestDigestSequence = value
        }
    }
}

/// UIDevice 在 watchOS 上不可用，用条件编译隔离。
private enum UIDeviceName {
    static var current: String {
        #if os(iOS)
        // 按字节截断：MCPeerID 超过 63 字节会抛不可捕获的异常。
        return CompanionPeerName.sanitized(UIDevice.current.name, fallback: "iPhone")
        #else
        return "Apple Watch"
        #endif
    }
}

// MARK: - MCSessionDelegate

extension CompanionConnection: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.state = .connected(peerID.displayName)
                self.lastError = nil
            case .connecting:
                self.state = .connecting(peerID.displayName)
            case .notConnected:
                if case .connected = self.state { self.state = .searching }
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data,
                             fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.accept(data) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession,
                             didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession,
                             didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceBrowserDelegate

extension CompanionConnection: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard let session = self.session else { return }
            // 邀请时带上协议版本，交由 Mac 端裁决。
            let context = Data(String(CompanionSnapshot.currentProtocolVersion).utf8)
            browser.invitePeer(peerID, to: session, withContext: context, timeout: 15)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
