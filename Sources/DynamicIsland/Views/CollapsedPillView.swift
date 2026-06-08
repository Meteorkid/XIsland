import AppKit
import SwiftUI

struct CollapsedPillView: View {
    @Environment(SessionManager.self) private var manager
    @Environment(AudioEngine.self) private var audio
    /// Obscured: left = expanded-list session that last received a message; right = active count.
    /// Unobscured: same session count/order as the expanded list (`visibleSessions`).
    let obscuredByNotch: Bool
    let onTap: () -> Void

    private var visible: [AgentSession] { manager.visibleSessions }

    var body: some View {
        Button(action: onTap) {
            Group {
                if obscuredByNotch {
                    obscuredBarContent
                } else {
                    unobscuredCenteredIcons
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(TestAccessibility.collapsedPill)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var obscuredBarContent: some View {
        HStack(spacing: 0) {
            obscuredLeadingIcon
            Spacer(minLength: 6)
            activeCountLabel
            if audio.isQuietHoursActive {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.6))
                    .padding(.leading, 8)
            }
            if manager.bypassMode {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green.opacity(0.7))
                    .padding(.leading, 6)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
    }

    private var unobscuredCenteredIcons: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if visible.isEmpty {
                idleContent.transition(.opacity)
            } else {
                let maxIcons = 5
                let shown = Array(visible.prefix(maxIcons))
                let overflow = visible.count - maxIcons
                HStack(spacing: 6) {
                    ForEach(shown) { session in
                        AgentIcon(agentType: session.agentType, size: 22, status: session.status)
                    }
                    if overflow > 0 {
                        Text("+\(overflow)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            if audio.isQuietHoursActive {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.6))
                    .padding(.leading, 8)
            }
            if manager.bypassMode {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green.opacity(0.7))
                    .padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    private func sessionNeedsAttention(_ session: AgentSession) -> Bool {
        session.status == .waitingPermission || session.status == .waitingAnswer || session.status == .waitingPlanReview
    }

    @ViewBuilder
    private var obscuredLeadingIcon: some View {
        let sessions = visible
        if sessions.isEmpty {
            appIconFallback
        } else if sessions.count == 1 || reduceMotion {
            sessionIcon(for: sessions[0])
        } else {
            RotatingSessionIcon(sessions: sessions)
        }
    }

    private func sessionIcon(for session: AgentSession) -> some View {
        ZStack(alignment: .topTrailing) {
            AgentIcon(agentType: session.agentType, size: 20, status: session.status)
            if sessionNeedsAttention(session) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .offset(x: 4, y: -2)
            }
        }
        .accessibilityLabel("Session: \(session.displayTitle)")
    }

    private var appIconFallback: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.green.opacity(0.85))
                        .frame(width: 20, height: 20)
                }
            }
            if visible.contains(where: sessionNeedsAttention) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: -1)
            }
        }
        .accessibilityLabel("X Island")
    }

    @AppStorage("reduceMotion") private var reduceMotion = false

    @ViewBuilder
    private var activeCountLabel: some View {
        let trulyActiveCount = manager.trulyActiveSessions.count
        let totalCount = manager.sessions.count
        if reduceMotion {
            countPair(count: trulyActiveCount, label: L10n.active,
                      accessibility: "\(trulyActiveCount) active agents")
        } else {
            TimelineView(.periodic(from: .now, by: 5.0)) { timeline in
                let tick = Int(timeline.date.timeIntervalSince1970)
                let showTotal = tick % 2 == 1
                let displayCount = showTotal ? totalCount : trulyActiveCount
                let displayLabel = showTotal ? L10n.total : L10n.active
                let a11y = showTotal
                    ? "\(totalCount) total agents"
                    : "\(trulyActiveCount) active agents"
                countPair(count: displayCount, label: displayLabel, accessibility: a11y)
            }
        }
    }

    private func countPair(count: Int, label: String, accessibility: String) -> some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
        }
        .accessibilityLabel(accessibility)
    }

    private var idleContent: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green.opacity(0.6))
                .frame(width: 6, height: 6)
            Text(L10n.ready)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// 轮换显示多个会话的吉祥物图标，带淡入淡出效果
private struct RotatingSessionIcon: View {
    let sessions: [AgentSession]
    @State private var currentIndex = 0
    @State private var showingNext = false  // 控制交叉淡入淡出

    var body: some View {
        let count = sessions.count
        ZStack {
            // 当前 icon
            sessionIcon(for: sessions[currentIndex])
                .opacity(showingNext ? 0 : 1)
                .animation(.easeInOut(duration: 0.35), value: showingNext)
            // 下一个 icon
            if count > 1 {
                let nextIndex = (currentIndex + 1) % count
                sessionIcon(for: sessions[nextIndex])
                    .opacity(showingNext ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: showingNext)
            }
        }
        .onAppear {
            guard count > 1 else { return }
            // 用 TimelineView 驱动旋转，避免手动 Timer 生命周期问题
        }
        .background {
            if sessions.count > 1 {
                TimelineView(.periodic(from: .now, by: 3.0)) { _ in
                    Color.clear
                        .task(id: currentIndex) {
                            // 每 3 秒触发一次旋转
                            try? await Task.sleep(for: .milliseconds(350))
                            showingNext = true
                            try? await Task.sleep(for: .milliseconds(400))
                            currentIndex = (currentIndex + 1) % sessions.count
                            showingNext = false
                        }
                }
            }
        }
    }

    private func sessionIcon(for session: AgentSession) -> some View {
        ZStack(alignment: .topTrailing) {
            AgentIcon(agentType: session.agentType, size: 20, status: session.status)
            if session.status == .waitingPermission
                || session.status == .waitingAnswer
                || session.status == .waitingPlanReview {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .offset(x: 4, y: -2)
            }
        }
        .accessibilityLabel("Session: \(session.displayTitle)")
    }
}
