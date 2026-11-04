import SwiftUI
import CompanionShared

#if os(iOS)
import UIKit
#endif

/// iPhone 端主界面：连接状态 + 待处理会话 + 就地审批。
///
/// 连接对象由 App 层注入而不是这里 `@State` 持有：
/// 视图内持有会在视图重建或切后台时释放连接，导致"锁屏再解锁就断线"。
struct CompanionRootView: View {
    let connection: CompanionConnection
    let relay: WatchRelay
    @State private var answering: CompanionSession?
    @State private var answerText = ""

    private var orderedSessions: [CompanionSession] {
        connection.snapshot?.ordered ?? []
    }

    var body: some View {
        NavigationStack {
            Group {
                if orderedSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("X Island")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { connectionBadge }
            }
            .task {
                connection.start()
                relay.activate()
                // 手表发来的命令原样交给 Mac 连接层。
                relay.onWatchCommand = { command in connection.send(command) }
            }
            // 刻意不在 onDisappear 里 stop：连接由 App 层持有，
            // 视图消失（切后台、被系统回收）不等于要断开。
            // 停连接会让用户切回来时必须重走一遍 Bonjour 发现。
            #if os(iOS)
            // iOS 会在后台挂断 Multipeer 且不会自动恢复，回前台必须主动重连。
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in
                connection.handleForeground()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didEnterBackgroundNotification)) { _ in
                connection.handleBackground()
            }
            #endif
            .onChange(of: connection.digest) { _, newDigest in
                // 只有摘要变化才转发，减少 WatchConnectivity 的无效唤醒。
                if let newDigest { relay.push(digest: newDigest) }
            }
            .alert("回答", isPresented: Binding(
                get: { answering != nil },
                set: { if !$0 { answering = nil } }
            )) {
                TextField("输入回答", text: $answerText)
                Button("发送") {
                    if let target = answering {
                        connection.answer(target.id, text: answerText)
                    }
                    answerText = ""
                    answering = nil
                }
                Button("取消", role: .cancel) {
                    answerText = ""
                    answering = nil
                }
            } message: {
                Text(answering?.title ?? "")
            }
        }
    }

    private var sessionList: some View {
        List(orderedSessions) { session in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(session.agent)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    phaseBadge(session.phase)
                }
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(session.project)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if session.phase.needsUser {
                    actionRow(for: session)
                }
            }
            .padding(.vertical, 4)
        }
        .refreshable { connection.reconnect() }
    }

    @ViewBuilder
    private func actionRow(for session: CompanionSession) -> some View {
        HStack(spacing: 10) {
            Button("批准") { connection.approve(session.id) }
                .buttonStyle(.borderedProminent)
                .disabled(!connection.remoteDecisionsAllowed)

            Button("拒绝") { connection.deny(session.id) }
                .buttonStyle(.bordered)
                .disabled(!connection.remoteDecisionsAllowed)

            if session.phase == .waitingQuestion {
                Button("回答") {
                    answering = session
                    answerText = ""
                }
                .buttonStyle(.bordered)
                .disabled(!connection.remoteDecisionsAllowed)
            }
            Spacer()
        }
        .font(.caption)
    }

    private func phaseBadge(_ phase: CompanionPhase) -> some View {
        Text(label(for: phase))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint(for: phase).opacity(0.16), in: Capsule())
            .foregroundStyle(tint(for: phase))
    }

    private func label(for phase: CompanionPhase) -> String {
        switch phase {
        case .idle: return "空闲"
        case .processing: return "处理中"
        case .running: return "运行中"
        case .waitingApproval: return "待批准"
        case .waitingQuestion: return "待回答"
        }
    }

    private func tint(for phase: CompanionPhase) -> Color {
        switch phase {
        case .waitingApproval, .waitingQuestion: return .orange
        case .running, .processing: return .blue
        case .idle: return .secondary
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connected ? .green : .secondary)
                .frame(width: 6, height: 6)
            Text(connectionText)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
    }

    private var connected: Bool {
        if case .connected = connection.state { return true }
        return false
    }

    private var connectionText: String {
        switch connection.state {
        case .idle: return "未启动"
        case .searching: return "搜索中"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .failed(let reason): return reason
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            connected ? "没有进行中的会话" : "未连接 Mac",
            systemImage: connected ? "checkmark.circle" : "wifi.slash",
            description: Text(connected
                ? "在 Mac 上开始一个 Agent 会话后，这里会显示出来。"
                : "确认两台设备在同一 Wi-Fi，且 Mac 端已开启伴端广播。")
        )
    }
}
