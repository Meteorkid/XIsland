import AppKit
import SwiftUI

struct CollapsedPillView: View {
    @Environment(SessionManager.self) private var manager
    @Environment(AudioEngine.self) private var audio
    @Environment(QuotaTracker.self) private var quotaTracker
    @Environment(ThemeManager.self) private var themeManager
    /// 两种布局共享最近任务候选；数量限制只影响图标，不影响完整列表及计数。
    let obscuredByNotch: Bool
    let isExpanded: Bool
    let onTap: () -> Void

    private var visible: [AgentSession] { manager.visibleSessions }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var appReduceMotion = false
    @AppStorage("disableAnimations") private var disableAnimations = false
    @AppStorage("showCollapsedAgentIcon") private var showCollapsedAgentIcon = true
    @AppStorage("collapsedRecentTaskLimit") private var collapsedRecentTaskLimit = CollapsedTaskSelection.defaultLimit
    @AppStorage("showCollapsedSessionCount") private var showCollapsedSessionCount = true
    @AppStorage("showCollapsedQuota") private var showCollapsedQuota = true

    private var displayedSessions: [AgentSession] {
        CollapsedTaskSelection.select(from: visible, limit: collapsedRecentTaskLimit)
    }

    private var reduceMotion: Bool {
        !IslandMotionPolicy(
            reduceMotion: appReduceMotion,
            systemReduceMotion: systemReduceMotion,
            disableAnimations: disableAnimations
        ).allowsContinuousAnimation
    }

    enum CountKind {
        case active
        case total
    }

    static let countRotationInterval: TimeInterval = 5

    static func countKind(isExpanded: Bool, at date: Date) -> CountKind {
        if isExpanded { return .total }
        let slot = Int(floor(date.timeIntervalSince1970 / countRotationInterval))
        return slot % 2 == 0 ? .active : .total
    }

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
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private var obscuredBarContent: some View {
        HStack(spacing: 0) {
            if showCollapsedAgentIcon {
                obscuredLeadingIcon
            }
            Spacer(minLength: showCollapsedAgentIcon ? 6 : 0)
            if showCollapsedSessionCount {
                activeCountLabel
            }
            if let quotaBadge = quotaBadgeContent {
                quotaBadge
                    .padding(.leading, showCollapsedSessionCount ? 8 : 0)
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
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
    }

    private var unobscuredCenteredIcons: some View {
        HStack(spacing: 8) {
            if showCollapsedAgentIcon {
                if visible.isEmpty {
                    appIconFallback
                } else {
                    let shown = displayedSessions
                    HStack(spacing: 6) {
                        ForEach(shown) { session in
                            AgentIcon(session: session, size: 22)
                        }
                    }
                }
            }

            if let compactModules = compactTrailingModules {
                if showCollapsedAgentIcon {
                    Spacer(minLength: 0)
                }
                compactModules
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionNeedsAttention(_ session: AgentSession) -> Bool {
        session.status == .waitingPermission || session.status == .waitingAnswer || session.status == .waitingPlanReview
    }

    @ViewBuilder
    private var obscuredLeadingIcon: some View {
        let sessions = displayedSessions
        if sessions.isEmpty {
            appIconFallback
        } else if sessions.count == 1 || reduceMotion {
            sessionIcon(for: sessions[0])
        } else {
            RotatingSessionIcon(sessions: sessions)
        }
    }

    private func sessionIcon(for session: AgentSession) -> some View {
        let icon = AgentIcon(session: session, size: 20)
        return icon.accessibilityLabel("\(icon.accessibilityDescription)")
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

    private var activeCountLabel: some View {
        countLabel(compact: false)
    }

    @ViewBuilder
    private func countLabel(compact: Bool) -> some View {
        let trulyActiveCount = manager.trulyActiveSessions.count
        let totalCount = manager.sessions.count
        if isExpanded {
            // 展开面板时显示总会话数
            countPair(count: totalCount, label: L10n.total,
                      accessibility: "\(totalCount) total agents", compact: compact)
        } else {
            // 计数轮换属于状态更新，减少动态效果时也保留低频刷新。
            TimelineView(.periodic(from: .now, by: Self.countRotationInterval)) { timeline in
                let showTotal = Self.countKind(isExpanded: false, at: timeline.date) == .total
                let displayCount = showTotal ? totalCount : trulyActiveCount
                let displayLabel = showTotal ? L10n.total : L10n.active
                let a11y = showTotal
                    ? "\(totalCount) total agents"
                    : "\(trulyActiveCount) active agents"
                countPair(count: displayCount, label: displayLabel, accessibility: a11y, compact: compact)
            }
        }
    }

    private func countPair(count: Int, label: String, accessibility: String, compact: Bool) -> some View {
        HStack(spacing: 3) {
            ZStack(alignment: .trailing) {
                Text("\(max(manager.sessions.count, count))").hidden()
                Text("\(count)")
            }
            .font(.system(size: compact ? 10 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(IslandStyle.primaryText)
            .monospacedDigit()
            ZStack {
                Text(L10n.active).hidden()
                Text(L10n.total).hidden()
                Text(label)
            }
            .font(.system(size: compact ? 9 : 10, weight: .medium))
            .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var compactTrailingModules: AnyView? {
        let hasCount = showCollapsedSessionCount
        let hasQuota = quotaBadgeContent != nil
        let hasQuietHours = audio.isQuietHoursActive
        let hasBypass = manager.bypassMode

        guard hasCount || hasQuota || hasQuietHours || hasBypass else { return nil }

        return AnyView(HStack(spacing: 6) {
            if hasCount {
                compactCountBadge
            }
            if let quotaBadgeContent {
                quotaBadgeContent
            }
            if hasQuietHours {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.6))
            }
            if hasBypass {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green.opacity(0.7))
            }
        })
    }

    private var compactCountBadge: some View {
        countLabel(compact: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(IslandStyle.insetFill(for: themeManager.resolvedScheme))
            )
    }

    private var quotaBadgeContent: AnyView? {
        guard showCollapsedQuota,
              let (label, value, color) = collapsedQuotaSummary
        else { return nil }

        return AnyView(HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(IslandStyle.secondaryText)
            Text(value)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
        )
    }

    private var collapsedQuotaSummary: (String, String, Color)? {
        for quota in quotaTracker.quotas {
            switch quota.provider {
            case "Anthropic":
                if let remaining = quota.tokensRemaining {
                    return ("Claude", L10n.quotaTokensRemaining(formatTokens(remaining)), Color(red: 0.85, green: 0.45, blue: 0.25))
                }
            case "OpenAI":
                if let used = quota.tokensUsed {
                    return ("Codex", L10n.quotaTokensUsed(formatTokens(used)), Color(red: 0.2, green: 0.8, blue: 0.4))
                }
            case "Kimi":
                if let balance = quota.balanceText {
                    return ("Kimi", balance, Color(red: 0.95, green: 0.35, blue: 0.45))
                }
            case "DeepSeek":
                if let balance = quota.balanceText {
                    return ("DeepSeek", balance, Color(red: 0.25, green: 0.75, blue: 0.55))
                }
            default:
                continue
            }
        }
        guard let quota = quotaTracker.quotas.first else { return nil }
        let label = quota.provider == "Anthropic" ? "Claude" : quota.provider == "OpenAI" ? "Codex" : quota.provider
        return (label, L10n.quotaUnknown, IslandStyle.secondaryText)
    }

    private func formatTokens(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return String(format: "%.1fK", Double(count) / 1000) }
        return String(format: "%.2fM", Double(count) / 1_000_000)
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
        case .idle, .completed, .observationUnavailable, .completionUnconfirmed:
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
        let icon = AgentIcon(session: session, size: 20)
        return icon.accessibilityLabel("\(icon.accessibilityDescription)")
    }
}
