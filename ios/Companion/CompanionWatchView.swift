import SwiftUI
import CompanionShared

#if os(watchOS)
/// 手表端：只保留"最紧急的一条 + 两个按钮"。
///
/// 手表屏幕放不下列表，也不该放——抬手两秒内要能做完一个决定。
/// 批准前多一次确认：手表误触概率高于手机，且批准不可撤销。
///
/// 通信链路刻意不是"手表直连 Mac"：**watchOS 没有 MultipeerConnectivity**，
/// 摘要由 iPhone 经 WatchConnectivity 转发，命令也原路返回。
struct CompanionWatchView: View {
    @State private var relay = WatchRelay.shared
    @State private var confirming: CompanionSession?

    private var focus: CompanionSession? {
        relay.digest?.focus
    }

    var body: some View {
        Group {
            if let session = focus {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.agent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(session.project)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if session.phase.needsUser {
                        if relay.digest?.allowsDecisions == true {
                            HStack {
                                Button("批准") { confirming = session }
                                    .tint(.green)
                                Button("拒绝") { relay.send(.deny(sessionId: session.id)) }
                                    .tint(.red)
                            }
                        } else {
                            // Mac 未开启远程审批时明确告知，而不是给两个按不动的按钮。
                            Text("需在 Mac 上处理")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text(relay.isReachable ? "无待处理会话" : "未连接 iPhone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { relay.activate() }
        .confirmationDialog("确认批准？", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        )) {
            Button("批准") {
                if let target = confirming {
                    relay.send(.approve(sessionId: target.id))
                }
                confirming = nil
            }
            Button("取消", role: .cancel) { confirming = nil }
        }
    }
}
#endif
