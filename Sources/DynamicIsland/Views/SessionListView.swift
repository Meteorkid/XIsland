import SwiftUI

struct SessionListView: View {
    @Environment(SessionManager.self) private var manager
    var onJump: (() -> Void)?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(manager.visibleSessions) { session in
                    SessionCardView(session: session, onJump: onJump)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier(TestAccessibility.sessionList)
    }
}

struct SessionCardView: View {
    @Environment(SessionManager.self) private var manager
    let session: AgentSession
    var onJump: (() -> Void)?
    @State private var isHovered = false
    @State private var recapExpanded = false
    @AppStorage("compactBadgesInExpandedView") private var compactBadges = true
    @AppStorage("displayTimestamp") private var displayTimestamp = true

    var body: some View {
        Button {
            _ = TerminalJumpManager.jump(to: session)
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
                        Text("You: \(session.prompt)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
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
                        .background(.white.opacity(0.06))
                        .padding(.horizontal, 12)
                    toolActivity
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }

                if session.status == .completed, let recap = session.recapText, !recap.isEmpty {
                    Divider()
                        .background(.white.opacity(0.06))
                        .padding(.horizontal, 12)
                    recapSection(recap)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered ? IslandStyle.cardHover : IslandStyle.cardRest)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                .white.opacity(isHovered ? IslandStyle.cardStrokeHover : IslandStyle.cardStrokeRest),
                                lineWidth: 0.5
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(TestAccessibility.sessionCard(id: session.id))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            AgentIcon(agentType: session.agentType, size: 24, status: session.status)
            StatusDot(status: session.status)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                if session.hasPromptTitle {
                    Text(session.workspaceName)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 5) {
                TagBadge(text: session.agentType.shortName, color: session.agentType.color)
                TagBadge(text: sourceBadgeText, color: .white.opacity(0.58))

                if displayTimestamp {
                    TagBadge(text: session.formattedDuration, color: .white.opacity(0.3))
                }

                if isHovered {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            manager.dismissSession(session)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: 18, height: 18)
                            .background(.white.opacity(0.1))
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
                        .foregroundStyle(event.isComplete ? .green.opacity(0.5) : .white.opacity(0.25))

                    Text("\(event.displayName)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(event.isComplete ? .white.opacity(0.35) : .white.opacity(0.7))

                    if event.isComplete {
                        Text(event.summary)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.25))
                            .lineLimit(1)
                    }
                }
            }

            if let tool = session.currentTool {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                    Text("Running \(tool)...")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            if !session.subagentIds.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundStyle(.purple.opacity(0.6))
                    Text("\(session.subagentIds.count) subagent\(session.subagentIds.count > 1 ? "s" : "") running")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple.opacity(0.5))
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

                    Text("Thinking...")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.blue.opacity(0.4))
                }
            }

            Text(session.agentResponse)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .animation(.easeInOut(duration: 0.3), value: session.agentResponse)
        }
    }

    private func recapSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    recapExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: recapExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.blue.opacity(0.5))
                    Text(recapExpanded ? "Hide recap" : "Show recap")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.blue.opacity(0.5))
                }
            }
            .buttonStyle(.plain)

            if recapExpanded {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)
            }
        }
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

struct StatusDot: View {
    let status: SessionStatus
    @AppStorage("reduceMotion") private var reduceMotion = false

    private var color: Color {
        switch status {
        case .active, .thinking: .blue
        case .idle: .green
        case .waitingPermission, .waitingAnswer, .waitingPlanReview: .orange
        case .completed: .green
        case .error: .red
        case .compacting: .yellow
        }
    }

    private var shouldBounce: Bool {
        switch status {
        case .active, .thinking, .compacting: true
        case .waitingPermission, .waitingAnswer, .waitingPlanReview: true
        default: false
        }
    }

    var body: some View {
        ZStack {
            if shouldBounce && !reduceMotion {
                Circle()
                    .fill(color.opacity(0.25))
                    .frame(width: 10, height: 10)
                    .phaseAnimator([false, true]) { content, phase in
                        content.scaleEffect(phase ? 1.8 : 1.0)
                              .opacity(phase ? 0.0 : 0.5)
                    } animation: { _ in .easeOut(duration: 1.2) }
            }

            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.6), radius: 3)
                .modifier(BounceModifier(shouldBounce: shouldBounce && !reduceMotion, isWaiting: isWaiting))
        }
        .frame(width: 10, height: 10)
    }

    private var isWaiting: Bool {
        status == .waitingPermission || status == .waitingAnswer || status == .waitingPlanReview
    }
}

private struct BounceModifier: ViewModifier {
    let shouldBounce: Bool
    let isWaiting: Bool

    func body(content: Content) -> some View {
        if isWaiting {
            content.phaseAnimator([false, true]) { view, phase in
                view.offset(y: phase ? -3 : 1)
            } animation: { phase in
                phase ? .easeOut(duration: 0.3) : .easeIn(duration: 0.3).delay(0.15)
            }
        } else if shouldBounce {
            content.phaseAnimator([false, true]) { view, phase in
                view.scaleEffect(phase ? 1.2 : 0.85)
            } animation: { _ in .easeInOut(duration: 0.8) }
        } else {
            content
        }
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
