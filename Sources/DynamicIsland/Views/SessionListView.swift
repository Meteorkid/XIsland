import SwiftUI

struct SessionListView: View {
    @Environment(SessionManager.self) private var manager
    @Environment(ThemeManager.self) private var themeManager
    var onJump: (() -> Void)?
    @State private var showFilterBar = false
    @AppStorage("reduceMotion") private var appReduceMotion = false
    @AppStorage("disableAnimations") private var disableAnimations = false
    @AppStorage("cascadeEntranceEnabled") private var cascadeEntranceEnabled = true
    @AppStorage("proximityLiftEnabled") private var proximityLiftEnabled = false
    /// 指针在列表坐标系中的 y。仅当距离感应开启时才更新，避免无谓的状态写入。
    @State private var pointerY: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool {
        !IslandMotionPolicy(reduceMotion: appReduceMotion, systemReduceMotion: systemReduceMotion,
                            disableAnimations: disableAnimations).allowsContinuousAnimation
    }

    private let cardTransition = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
    )

    /// 列表内卡片的估算宽度，用于推导距离感应的作用半径。
    private static let estimatedCardWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            // 过滤栏头部
            HStack {
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : IslandMotionTokens.elementTransition) {
                        showFilterBar.toggle()
                    }
                } label: {
                    Image(systemName: showFilterBar ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(showFilterBar ? .cyan : IslandStyle.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)

            // 过滤栏
            if showFilterBar {
                SessionFilterBar()
                    .padding(.bottom, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    // 待处理任务置顶区域
                    ForEach(Array(manager.pendingInteractionSessions.enumerated()), id: \.element.id) { index, session in
                        PendingTaskCardView(session: session)
                            .modifier(CardEntranceCascade(
                                index: index,
                                reduceMotion: reduceMotion,
                                isEnabled: cascadeEntranceEnabled
                            ))
                            .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                    }

                    if manager.grouping == .none {
                        ForEach(Array(Self.regularSessions(in: manager.filteredSessions).enumerated()), id: \.element.id) { index, session in
                            SessionCardView(session: session, onJump: onJump)
                                .modifier(CardEntranceCascade(
                                    index: index + manager.pendingInteractionSessions.count,
                                    reduceMotion: reduceMotion,
                                    isEnabled: cascadeEntranceEnabled
                                ))
                                .modifier(ProximityLiftModifier(
                                    pointerY: pointerY,
                                    itemMidY: cardMidY(forIndex: index + manager.pendingInteractionSessions.count),
                                    itemWidth: Self.estimatedCardWidth,
                                    isEnabled: proximityLiftEnabled,
                                    reduceMotion: reduceMotion
                                ))
                                .transition(reduceMotion ? .identity : cardTransition)
                        }
                    } else {
                        ForEach(manager.groupedSessions) { group in
                            let sessions = Self.regularSessions(in: group.sessions)
                            if !sessions.isEmpty {
                                Section(header:
                                    Text(group.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14)
                                        .padding(.top, 8)
                                ) {
                                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                        SessionCardView(session: session, onJump: onJump)
                                            .modifier(CardEntranceCascade(
                                                index: index,
                                                reduceMotion: reduceMotion,
                                                isEnabled: cascadeEntranceEnabled
                                            ))
                                            .transition(reduceMotion ? .identity : cardTransition)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .animation(reduceMotion ? nil : IslandMotionTokens.elementTransition, value: manager.filteredSessions.count)
            .animation(reduceMotion ? nil : IslandMotionTokens.elementTransition, value: manager.grouping)
            .onContinuousHover { phase in
                guard proximityLiftEnabled, !reduceMotion else {
                    if pointerY != nil { pointerY = nil }
                    return
                }
                switch phase {
                case .active(let location):
                    // 只在位移超过 1pt 时写入状态，过滤亚像素抖动。
                    if let current = pointerY, abs(current - location.y) < 1 { return }
                    pointerY = location.y
                case .ended:
                    pointerY = nil
                }
            }
        }
        .accessibilityIdentifier(TestAccessibility.sessionList)
        .onReceive(NotificationCenter.default.publisher(for: .xislandToggleSearch)) { _ in
            withAnimation(reduceMotion ? nil : IslandMotionTokens.elementTransition) {
                showFilterBar.toggle()
            }
        }
    }

    /// 估算第 index 张卡片的中心 y。用于距离感应——卡片高度不一，
    /// 这里用平均高度近似，精度足够（隆起半径远大于高度误差）。
    private func cardMidY(forIndex index: Int) -> CGFloat {
        let averageCardHeight: CGFloat = 96
        let spacing: CGFloat = 10
        return CGFloat(index) * (averageCardHeight + spacing) + averageCardHeight / 2
    }

    static func regularSessions(in sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { !$0.hasPendingInteraction }
    }
}

struct SessionCardView: View {
    @Environment(SessionManager.self) private var manager
    @Environment(ThemeManager.self) private var themeManager
    let session: AgentSession
    var onJump: (() -> Void)?
    @State private var jumpState = SessionJumpState()
    @State private var isHovered = false
    @State private var recapExpanded = false
    @State private var childrenExpanded = false
    @State private var showExportSheet = false
    @State private var previousStatus: SessionStatus?
    @State private var statusChangeTrigger = 0
    @AppStorage("compactBadgesInExpandedView") private var compactBadges = true
    @AppStorage("displayTimestamp") private var displayTimestamp = true
    @AppStorage("reduceMotion") private var appReduceMotion = false
    @AppStorage("disableAnimations") private var disableAnimations = false
    @AppStorage("symbolEffectsEnabled") private var symbolEffectsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool {
        !IslandMotionPolicy(reduceMotion: appReduceMotion, systemReduceMotion: systemReduceMotion,
                            disableAnimations: disableAnimations).allowsContinuousAnimation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 可跳转的卡片内容
            Button {
                jumpState.request(session, manager: manager, onAccepted: { onJump?() })
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    cardHeader
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    if !session.prompt.isEmpty && !session.hasPromptTitle {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(session.agentType.color.opacity(0.5))
                                .padding(.top, 2)
                            Text("\(L10n.youPrefix): \(session.prompt)")
                                .font(.system(size: 11))
                                .foregroundStyle(IslandStyle.secondaryText)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                    }

                    if !session.agentResponse.isEmpty {
                        streamingThoughtView(for: session)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 6)
                    }

                    if session.currentTool != nil {
                        HStack(spacing: 5) {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 10, height: 10)
                            Text(session.currentTool ?? "")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.blue.opacity(0.7))
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }

                    if !session.events.isEmpty {
                        Divider()
                            .background(IslandStyle.divider(for: themeManager.resolvedScheme).opacity(IslandStyle.dividerOpacity(for: themeManager.resolvedScheme)))
                            .padding(.horizontal, 12)
                        toolActivity
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
            }
            .buttonStyle(.plain)

            if manager.unsavedSessionIDs.contains(session.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.historySaveFailed)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Button(L10n.retryHistorySave) { manager.retryPendingHistorySaves() }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            // 摘要区（独立于跳转 Button）
            if let recap = session.recapText, !recap.isEmpty {
                Divider()
                    .background(IslandStyle.divider(for: themeManager.resolvedScheme).opacity(IslandStyle.dividerOpacity(for: themeManager.resolvedScheme)))
                    .padding(.horizontal, 12)
                recapSection(recap)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            // 子代理区（独立于跳转 Button）
            if !session.subagentIds.isEmpty {
                let children = manager.subagents(of: session)
                if !children.isEmpty {
                    Divider()
                        .background(IslandStyle.divider(for: themeManager.resolvedScheme).opacity(IslandStyle.dividerOpacity(for: themeManager.resolvedScheme)))
                        .padding(.horizontal, 12)
                    childrenSection(children)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(.leading, session.isSubagent ? 24 : 0)
        .background(
            ZStack(alignment: .leading) {
                if session.isSubagent {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.purple.opacity(0.4))
                        .frame(width: 2)
                        .padding(.leading, 10)
                }
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered
                          ? IslandStyle.cardHover(for: themeManager.resolvedScheme)
                          : IslandStyle.cardRest(for: themeManager.resolvedScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                IslandStyle.cardStrokeColor(for: themeManager.resolvedScheme)
                                    .opacity(isHovered ? IslandStyle.cardStrokeHover(for: themeManager.resolvedScheme)
                                                       : IslandStyle.cardStrokeRest(for: themeManager.resolvedScheme)),
                                lineWidth: 0.5
                            )
                    )
            }
            .padding(.leading, session.isSubagent ? 24 : 0)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier(TestAccessibility.sessionCard(id: session.id))
        .modifier(SessionJumpFeedback(state: jumpState))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : IslandMotionTokens.hoverTransition) {
                isHovered = hovering
            }
        }
        .contextMenu {
            if session.status == .completed && session.completionNeedsReview {
                Button(L10n.markCompletionReviewed) { manager.markCompletionReviewed(sessionID: session.id) }
            }
            Button {
                showExportSheet = true
            } label: {
                Label(L10n.exportSession, systemImage: "square.and.arrow.up")
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportView(session: session)
        }
        .modifier(ActiveSessionGlow(
            isRunning: session.status == .active || session.status == .thinking || session.status == .compacting,
            color: session.agentType.color,
            reduceMotion: reduceMotion
        ))
        .modifier(StatusChangeSweep(
            statusColor: session.status.uiColor,
            trigger: statusChangeTrigger,
            reduceMotion: reduceMotion
        ))
        .onAppear {
            previousStatus = session.status
        }
        .onChange(of: session.status) { _, newStatus in
            guard let prev = previousStatus, prev != newStatus else {
                previousStatus = newStatus
                return
            }
            previousStatus = newStatus
            statusChangeTrigger += 1
            fireHaptic(for: newStatus)
        }
    }

    /// 会话状态迁移时的触觉反馈。
    ///
    /// 只在**迁移进入**需要关注的状态时触发，避免每次重绘都振动：
    /// - 进入权限等待 → `permissionRequest`（最关键，需穿透注意力）
    /// - 进入问答/计划评审等待 → `inputRequired`
    /// - 进入错误 → `failure`
    ///
    /// 映射为纯函数 `IslandHapticPolicy` 的一部分逻辑，便于单测覆盖。
    private func fireHaptic(for status: SessionStatus) {
        switch status {
        case .waitingPermission:
            IslandHapticEngine.fire(.permissionRequest)
        case .waitingAnswer, .waitingPlanReview:
            IslandHapticEngine.fire(.inputRequired)
        case .error:
            IslandHapticEngine.fire(.failure)
        default:
            break
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            AgentIcon(session: session, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IslandStyle.primaryText)
                    .lineLimit(1)

                if session.hasPromptTitle {
                    Text(session.workspaceName)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                        .lineLimit(1)
                }
                if session.status == .completed && session.completionNeedsReview {
                    Label(L10n.completedNeedsReview, systemImage: "sparkle")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if !session.tokenUsage.model.isEmpty {
                    Text(session.tokenUsage.model)
                        .font(.system(size: 9))
                        .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                        .lineLimit(1)
                        .help(session.tokenUsage.model)
                }
            }

            Spacer()

            HStack(spacing: 5) {
                let identity = MascotTaskIdentityRegistry.shared.identity(for: session)
                TagBadge(text: "\(session.agentType.shortName) · \(identity.shortLabel)", color: identity.color)
                    .fixedSize(horizontal: true, vertical: false)
                TagBadge(text: sourceBadgeText, color: IslandStyle.secondaryText)

                if displayTimestamp {
                    Text(session.formattedDuration)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: session.formattedDuration)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(IslandStyle.insetFill(for: themeManager.resolvedScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                if isHovered {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            manager.dismissSession(session)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                            .frame(width: 18, height: 18)
                            .background(IslandStyle.insetFill(for: themeManager.resolvedScheme))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var toolActivity: some View {
        VStack(alignment: .leading, spacing: 4) {
            let recentEvents = session.events.suffix(5)
            let taskStatuses = session.kimiCodeApprovalObservation?.backgroundTaskStatuses(sessionID: session.id) ?? [:]
            ForEach(recentEvents) { event in
                let failed = event.hasFailedOutcome || KimiCodeApprovalObservation.isFailedBackgroundTask(taskStatuses[event.id])
                let uncertain = event.completionUnconfirmed || event.hasUnknownOutcome
                HStack(spacing: 6) {
                    Image(systemName: failed ? "xmark.square.fill" : event.wasCancelled ? "minus.square" : uncertain ? "questionmark.square" : event.isComplete ? "checkmark.square.fill" : "square")
                        .font(.system(size: 9))
                        .foregroundStyle(failed ? .red.opacity(0.7) : event.wasCancelled || uncertain ? .orange.opacity(0.7) : event.isComplete ? .green.opacity(0.5) : IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                        .modifier(ToolCompletionSymbolEffect(
                            isComplete: event.isComplete && !failed && !event.wasCancelled && !uncertain,
                            isFailed: failed,
                            reduceMotion: reduceMotion,
                            isEnabled: symbolEffectsEnabled
                        ))

                    Text("\(event.displayName)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(event.isComplete ? IslandStyle.tertiaryText(for: themeManager.resolvedScheme) : IslandStyle.secondaryText)

                    if event.isComplete || event.completionUnconfirmed {
                        Text(event.summary)
                            .font(.system(size: 9))
                            .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                            .lineLimit(1)
                    }
                }
            }

            if let tool = session.currentTool {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                    Text(L10n.toolRunning(tool))
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.secondaryText)
                }
            }

        }
    }

    private func streamingThoughtView(for session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if session.status == .thinking {
                    Image(systemName: "brain.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.blue.opacity(0.5))
                        .phaseAnimator([false, true]) { content, phase in
                            content.opacity(phase ? 1.0 : 0.3)
                        } animation: { _ in .easeInOut(duration: 0.8) }

                    Text(L10n.thinking)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.blue.opacity(0.4))
                }
            }

            Text(session.agentResponse)
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.secondaryText)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: session.agentResponse)
        }
    }

    private func childrenSection(_ children: [AgentSession]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.purple.opacity(0.6))
                Text(L10n.subagentCount(children.count))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.purple.opacity(0.5))
                Image(systemName: childrenExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.purple.opacity(0.4))
            }
            .onTapGesture {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    childrenExpanded.toggle()
                }
            }

            if childrenExpanded {
                VStack(spacing: 6) {
                    ForEach(children) { child in
                        SessionCardView(session: child, onJump: onJump)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func recapSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Recap 标题
            HStack(spacing: 4) {
                Image(systemName: "text.document")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.cyan.opacity(0.6))
                Text(L10n.recap)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.6))
            }

            // 直接显示摘要内容
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.secondaryText)
                .lineLimit(recapExpanded ? nil : 3)
                .multilineTextAlignment(.leading)
                .padding(.top, 2)

            // 展开/收起（仅在内容超过3行时显示）
            if text.components(separatedBy: "\n").count > 3 || text.count > 120 {
                HStack(spacing: 2) {
                    Text(recapExpanded ? L10n.showLess : L10n.showMore)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.cyan.opacity(0.4))
                    Image(systemName: recapExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.cyan.opacity(0.4))
                }
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        if !recapExpanded { manager.markCompletionReviewed(sessionID: session.id) }
                        recapExpanded.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.cyan.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var sourceBadgeText: String {
        let terminal = normalizedTerminalToken(session.terminal)

        if session.agentType == .cursor {
            if terminal == "cursor" {
                return "cursor ide"
            }
            if terminal == "terminal", (session.termSessionId ?? "").isEmpty {
                return "cursor ide"
            }
            if !terminal.isEmpty {
                return terminal
            }
            return "cursor cli"
        }

        if session.agentType == .codex {
            return terminal == "codex" ? "codex ide" : "codex cli"
        }

        if terminal == "cursor" {
            return "cursor ide"
        }
        if terminal == "codex" {
            return "codex ide"
        }

        if !terminal.isEmpty {
            return terminal
        }

        switch session.agentType {
        case .cursor:
            return "cursor cli"
        case .codex:
            return "codex cli"
        default:
            return session.agentType.shortName.lowercased() + " cli"
        }
    }

    private func normalizedTerminalToken(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return "" }

        if lower.contains("iterm") { return "iterm" }
        if lower.contains("warp") { return "warp" }
        if lower == "terminal" || lower.contains("apple_terminal") || lower.contains("com.apple.terminal") {
            return "terminal"
        }
        if lower.contains("cursor") { return "cursor" }
        if lower.contains("codex") { return "codex" }
        if lower.contains("ghostty") { return "ghostty" }
        if lower.contains("kitty") { return "kitty" }
        if lower.contains("alacritty") { return "alacritty" }
        if lower.contains("vscode") || lower.contains("visual studio code") || lower == "code" {
            return "vscode"
        }

        return lower
    }

}

struct TagBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
