import Foundation
import MultipeerConnectivity
import Observation
import CompanionShared

/// 把会话状态广播给 iPhone / Watch，并接收它们下发的操作。
///
/// 设计约束：
/// - **默认关闭**。广播会话标题与项目名属于隐私暴露，必须由用户显式开启。
/// - 加密要求 `.required`，不接受明文连接。
/// - 收到的命令必须带 `sessionId` 且该会话仍然存在，否则丢弃——
///   避免用户在队列变动后批准到错误的会话。
@MainActor
@Observable
final class CompanionPublisher: NSObject {
    static let shared = CompanionPublisher()

    /// 与 iOS 端约定一致，长度 ≤ 15，仅小写字母数字与连字符。
    private static let serviceType = "xisland-buddy"

    private(set) var isEnabled = false
    private(set) var connectedPeerNames: [String] = []
    private(set) var lastError: String?
    private(set) var lastPublishedSequence: UInt64 = 0

    /// 允许伴端执行决定类命令（approve / deny / answer）。
    /// 关闭时只推状态，手机端按钮置灰。
    var allowsRemoteDecisions = false

    /// 收到命令后的处理入口，由 AppDelegate 接到 SessionManager。
    var onCommand: ((CompanionCommand) -> Void)?

    /// 伴端刚连上时索要当前状态的回调。
    ///
    /// 没有它，手机连上后要等到下一次会话事件才能看到内容——
    /// 而"打开 app 就想看现在什么情况"正是最常见的用法。
    var onRequestState: (() -> [AgentSession])?

    private var sequence = CompanionSequence()
    private let peerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var lastDigestData: Data?
    /// 记住最近一次发布的快照，供新连上的设备立即补齐。
    private var lastSnapshot: CompanionSnapshot?

    private override init() {
        let name = Host.current().localizedName ?? "Mac"
        // 必须按字节截断：超过 63 字节时 MCPeerID 会抛不可捕获的异常直接崩溃。
        self.peerID = MCPeerID(displayName: CompanionPeerName.sanitized("XIsland \(name)"))
        super.init()
    }

    // MARK: - 生命周期

    func start() {
        guard !isEnabled else { return }
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["protocol": String(CompanionSnapshot.currentProtocolVersion)],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()

        self.session = session
        self.advertiser = advertiser
        isEnabled = true
        lastError = nil
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        session?.disconnect()
        advertiser = nil
        session = nil
        isEnabled = false
        connectedPeerNames = []
        lastDigestData = nil
        // 必须一并清掉缓存快照：否则用户关闭广播、稍后重新开启时，
        // 新连上的设备会立刻收到一份"关闭之前"的会话列表。
        lastSnapshot = nil
    }

    // MARK: - 发布

    /// 把当前会话列表发布给已连接的伴端。
    ///
    /// 没有已连接设备时直接返回，避免无谓的编码开销。
    func publish(_ sessions: [AgentSession], now: Date = Date()) {
        guard isEnabled, let session, !session.connectedPeers.isEmpty else { return }

        // 只在"需要用户处理"或"正在运行"的会话上停留：把全部会话都推给手表，
        // 手表会不停刷新却看不到重点。空闲会话不进列表。
        let payload = sessions
            .filter { $0.hasPendingInteraction || Self.phase(for: $0.status) != .idle }
            .map(Self.project)
        let snapshot = CompanionSnapshot(
            sequence: sequence.next(),
            generatedAt: now,
            sessions: payload,
            allowsDecisions: allowsRemoteDecisions
        )
        lastPublishedSequence = snapshot.sequence
        lastSnapshot = snapshot

        if let data = try? CompanionCodec.encode(snapshot) {
            // 完整快照走可靠传输；失败不抛给调用方，广播不该影响主流程。
            try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        }

        // 摘要只在"最关心的那条"变化时才发，减少蓝牙通道的无效唤醒。
        //
        // 摘要复用快照的序号：它在语义上是"同一时刻状态的精简视图"，
        // 不是独立的一次发布。伴端对两个通道分别记序号，
        // 否则摘要会把序号吃掉，导致随后的快照被当成旧包丢弃。
        let digest = CompanionDigest(snapshot: snapshot)
        if let data = try? CompanionCodec.encode(digest), data != lastDigestData {
            try? session.send(data, toPeers: session.connectedPeers, with: .unreliable)
            lastDigestData = data
        }
    }

    /// 把内部会话投影成伴端模型。标题与项目名都做长度截断，
    /// 手表一屏放不下更长的内容。
    static func project(_ session: AgentSession) -> CompanionSession {
        CompanionSession(
            id: session.id,
            agent: session.agentType.shortName,
            title: String(session.displayTitle.prefix(80)),
            project: String(session.workspaceName.prefix(40)),
            phase: phase(for: session.status),
            updatedAt: session.lastActivityTime
        )
    }

    static func phase(for status: SessionStatus) -> CompanionPhase {
        switch status {
        case .waitingPermission: return .waitingApproval
        case .waitingAnswer, .waitingPlanReview: return .waitingQuestion
        case .active, .thinking, .compacting: return .running
        case .idle, .completed, .error, .observationUnavailable, .completionUnconfirmed:
            return .idle
        }
    }

    // MARK: - 接收

    /// 新设备连上时立即补发一次当前状态。
    ///
    /// **优先向上层索要实时数据**，缓存只作为兜底：`publish` 在无连接时提前返回，
    /// 所以 `lastSnapshot` 可能停留在很久以前——直接发缓存会让刚连上的手机
    /// 看到一批早已结束的会话。
    fileprivate func sendCurrentState() {
        guard isEnabled, let session, !session.connectedPeers.isEmpty else { return }
        if let sessions = onRequestState?() {
            publish(sessions)
            return
        }
        if let lastSnapshot, let data = try? CompanionCodec.encode(lastSnapshot) {
            try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        }
    }

    fileprivate func handleIncoming(_ data: Data, from peer: MCPeerID) {
        guard let command = try? CompanionCodec.decodeCommand(data) else { return }
        guard !command.decidesForTheUser || allowsRemoteDecisions else {
            lastError = "ignored command from \(peer.displayName): remote decisions disabled"
            return
        }
        onCommand?(command)
    }
}

// MARK: - MCSessionDelegate

extension CompanionPublisher: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                if !self.connectedPeerNames.contains(peerID.displayName) {
                    self.connectedPeerNames.append(peerID.displayName)
                }
                // 刚连上就补齐状态，手机端不必等下一次事件。
                self.sendCurrentState()
            case .notConnected:
                self.connectedPeerNames.removeAll { $0 == peerID.displayName }
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data,
                             fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.handleIncoming(data, from: peerID) }
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

// MARK: - MCNearbyServiceAdvertiserDelegate

extension CompanionPublisher: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            // 只接受同一协议版本的伴端，避免新旧协议互相误解。
            let accepted: Bool
            if let context, let version = String(data: context, encoding: .utf8), !version.isEmpty {
                accepted = version == String(CompanionSnapshot.currentProtocolVersion)
            } else {
                accepted = true
            }
            if !accepted { self.lastError = "rejected \(peerID.displayName): protocol mismatch" }
            invitationHandler(accepted, accepted ? self.session : nil)
        }
    }
}
