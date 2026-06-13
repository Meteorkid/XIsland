import SwiftUI

struct SessionListView: View {
    @Environment(SessionManager.self) private var manager
    @Environment(ThemeManager.self) private var themeManager
    var onJump: (() -> Void)?
    @State private var showFilterBar = false
    @AppStorage("reduceMotion") private var reduceMotion = false

    private let cardTransition = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
    )

    var body: some View {
        VStack(spacing: 0) {
            // 过滤栏头部
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
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
                    ForEach(pendingSessions) { session in
                        PendingTaskCardView(session: session)
                            .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                    }

                    if manager.grouping == .none {
                        ForEach(manager.filteredSessions) { session in
                            SessionCardView(session: session, onJump: onJump)
                                .transition(reduceMotion ? .identity : cardTransition)
                        }
                    } else {
                        ForEach(manager.groupedSessions) { group in
                            Section(header:
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 8)
                            ) {
                                ForEach(group.sessions) { session in
                                    SessionCardView(session: session, onJump: onJump)
                                        .transition(reduceMotion ? .identity : cardTransition)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .animation(.easeInOut(duration: 0.2), value: manager.filteredSessions.count)
            .animation(.easeInOut(duration: 0.2), value: manager.grouping)
        }
        .accessibilityIdentifier(TestAccessibility.sessionList)
        .onReceive(NotificationCenter.default.publisher(for: .xislandToggleSearch)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                showFilterBar.toggle()
            }
        }
    }

    /// 有待处理交互的会话（问题/权限/计划审查），置顶显示
    private var pendingSessions: [AgentSession] {
        manager.sessions.filter { s in
            s.pendingQuestion != nil || s.pendingPermission != nil || s.pendingPlanReview != nil
        }
    }
}

// MARK: - PendingTaskCardView

/// 展开面板顶部的待处理任务卡片，内联显示选项，无需跳转窗口
struct PendingTaskCardView: View {
    let session: AgentSession
    @Environment(SessionManager.self) private var manager
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 会话标识头
            HStack(spacing: 6) {
                AgentIcon(agentType: session.agentType, size: 14)
                Text(session.agentType.shortName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandStyle.secondaryText)
                Spacer()
                if session.pendingPermission != nil {
                    Text(L10n.permission)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15))
                        .clipShape(Capsule())
                } else if session.pendingQuestion != nil {
                    Text(L10n.question)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15))
                        .clipShape(Capsule())
                } else if session.pendingPlanReview != nil {
                    Text(L10n.review)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.purple.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            // 内容：根据 pending 类型渲染
            if let perm = session.pendingPermission {
                permissionContent(perm)
            } else if let question = session.pendingQuestion {
                questionContent(question)
            } else if let plan = session.pendingPlanReview {
                planContent(plan)
            }
        }
        .padding(12)
        .background(IslandStyle.cardRest(for: themeManager.resolvedScheme))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    IslandStyle.cardStrokeColor(for: themeManager.resolvedScheme)
                        .opacity(IslandStyle.cardStrokeRest(for: themeManager.resolvedScheme)),
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Permission

    private func permissionContent(_ perm: PendingPermission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 10))
                Text(perm.tool)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(IslandStyle.primaryText)
            }
            if !perm.description.isEmpty {
                Text(perm.description)
                    .font(.system(size: 10))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button {
                    manager.denyPermission(session: session)
                } label: {
                    Text("Deny")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.red.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                Button {
                    manager.approvePermission(session: session)
                } label: {
                    Text("Allow")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.green.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Question

    private func questionContent(_ q: PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(q.text)
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                ForEach(q.options, id: \.self) { option in
                    Button {
                        manager.answerQuestion(session: session, answer: option)
                    } label: {
                        Text(option)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(IslandStyle.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(IslandStyle.insetFill(for: themeManager.resolvedScheme))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Plan Review

    private func planContent(_ plan: PendingPlanReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.markdown)
                .font(.system(size: 10))
                .foregroundStyle(IslandStyle.secondaryText)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button {
                    manager.respondToPlan(session: session, approved: false, feedback: nil)
                } label: {
                    Text("Reject")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.red.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                Button {
                    manager.respondToPlan(session: session, approved: true, feedback: nil)
                } label: {
                    Text("Approve")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.green.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SessionCardView: View {
    @Environment(SessionManager.self) private var manager
    @Environment(ThemeManager.self) private var themeManager
    let session: AgentSession
    var onJump: (() -> Void)?
    @State private var isHovered = false
    @State private var recapExpanded = false
    @State private var childrenExpanded = false
    @State private var showExportSheet = false
    @State private var previousStatus: SessionStatus?
    @State private var statusChangeTrigger = 0
    @AppStorage("compactBadgesInExpandedView") private var compactBadges = true
    @AppStorage("displayTimestamp") private var displayTimestamp = true
    @AppStorage("reduceMotion") private var reduceMotion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 可跳转的卡片内容
            Button {
                TerminalJumpManager.jump(to: session)
                onJump?()
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
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
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            AgentIcon(agentType: session.agentType, size: 24, status: session.status)

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
            }

            Spacer()

            HStack(spacing: 5) {
                TagBadge(text: session.agentType.shortName, color: session.agentType.color)
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
                        withAnimation(.easeOut(duration: 0.2)) {
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
            ForEach(recentEvents) { event in
                HStack(spacing: 6) {
                    Image(systemName: event.isComplete ? "checkmark.square.fill" : "square")
                        .font(.system(size: 9))
                        .foregroundStyle(event.isComplete ? .green.opacity(0.5) : IslandStyle.tertiaryText(for: themeManager.resolvedScheme))

                    Text("\(event.displayName)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(event.isComplete ? IslandStyle.tertiaryText(for: themeManager.resolvedScheme) : IslandStyle.secondaryText)

                    if event.isComplete {
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
                .animation(.easeInOut(duration: 0.3), value: session.agentResponse)
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
                withAnimation(.easeInOut(duration: 0.2)) {
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
                    withAnimation(.easeInOut(duration: 0.2)) {
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
