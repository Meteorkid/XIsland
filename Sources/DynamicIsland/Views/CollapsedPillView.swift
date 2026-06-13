import AppKit
import SwiftUI

struct CollapsedPillView: View {
    @Environment(SessionManager.self) private var manager
    @Environment(AudioEngine.self) private var audio
    @Environment(ThemeManager.self) private var themeManager
    /// Obscured: left = expanded-list session that last received a message; right = active count.
    /// Unobscured: same session count/order as the expanded list (`visibleSessions`).
    let obscuredByNotch: Bool
    let isExpanded: Bool
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
                            .foregroundStyle(IslandStyle.secondaryText)
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
        if isExpanded {
            // 展开面板时显示总会话数
            countPair(count: totalCount, label: L10n.total,
                      accessibility: "\(totalCount) total agents")
        } else if reduceMotion {
            countPair(count: trulyActiveCount, label: L10n.active,
                      accessibility: "\(trulyActiveCount) active agents")
        } else {
            // 折叠时交替显示活跃/总计
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
                .foregroundStyle(IslandStyle.primaryText)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
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
                .foregroundStyle(IslandStyle.secondaryText)
        }
    }
}

/// 轮换显示多个会话的吉祥物图标，带淡入淡出效果
/// 等待处理的会话（error/waiting*）轮换慢，运行中的会话轮换快
private struct RotatingSessionIcon: View {
    let sessions: [AgentSession]

    /// 按状态优先级排序的会话列表（数值越小越优先）
    private var sortedSessions: [AgentSession] {
        sessions.sorted { a, b in
            if a.status.statusPriority != b.status.statusPriority {
                return a.status.statusPriority < b.status.statusPriority
            }
            return a.lastActivityTime > b.lastActivityTime
        }
    }

    /// 根据会话状态决定轮换周期（秒）
    /// 等待处理：5s（让用户有时间看到），运行中：0.8s（快速轮换突出等待）
    private func cycleDuration(for status: SessionStatus) -> Double {
        switch status {
        case .error, .waitingPermission, .waitingAnswer, .waitingPlanReview:
            return 5.0
        case .active, .thinking, .compacting:
            return 0.8
        case .idle, .completed:
            return 0.6
        }
    }

    /// 根据 elapsed 时间计算当前应显示的会话索引和淡入淡出进度
    private func rotationState(elapsed: Double, count: Int, sorted: [AgentSession]) -> (outIdx: Int, inIdx: Int, progress: Double) {
        let totalCycle = sorted.reduce(0) { $0 + cycleDuration(for: $1.status) }
        let posInCycle = elapsed.truncatingRemainder(dividingBy: totalCycle)

        var cumTime: Double = 0
        var outIdx = 0
        var outDur: Double = 1.5
        for (i, session) in sorted.enumerated() {
            let dur = cycleDuration(for: session.status)
            if posInCycle >= cumTime && posInCycle < cumTime + dur {
                outIdx = i
                outDur = dur
                break
            }
            cumTime += dur
        }
        let inIdx = (outIdx + 1) % count
        let cyclePos = posInCycle - cumTime
        let crossfadeZone = min(0.35, outDur * 0.1)
        let progress: Double
        if cyclePos >= (outDur - crossfadeZone) {
            progress = (cyclePos - (outDur - crossfadeZone)) / crossfadeZone
        } else {
            progress = 0
        }
        return (outIdx, inIdx, progress)
    }

    var body: some View {
        let sorted = sortedSessions
        let count = sorted.count
        ZStack {
            if count <= 1 {
                sessionIcon(for: sorted[0])
            } else {
                TimelineView(.periodic(from: .now, by: 0.15)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince1970
                    let state = rotationState(elapsed: elapsed, count: count, sorted: sorted)

                    ZStack {
                        sessionIcon(for: sorted[state.outIdx])
                            .opacity(1 - state.progress)
                        sessionIcon(for: sorted[state.inIdx])
                            .opacity(state.progress)
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
