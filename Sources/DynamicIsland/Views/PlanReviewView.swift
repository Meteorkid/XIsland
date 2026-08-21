import SwiftUI

/// 计划审查面板：向用户展示待审计划（Markdown 正文），
/// 支持先填写反馈意见，再批准或拒绝。
struct PlanReviewView: View {
    let session: AgentSession
    let onComplete: () -> Void

    @Environment(SessionManager.self) private var manager
    @Environment(ThemeManager.self) private var themeManager

    @State private var draftFeedback = ""
    @State private var isFeedbackExpanded = false

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            separator
            if let plan = session.pendingPlanReview {
                planBody(plan)
            }
        }
        .accessibilityIdentifier(TestAccessibility.planPanel)
    }

    // MARK: - 顶部标题栏

    /// 发起审查的代理：优先取待审计划中声明的代理，回退到会话代理。
    private var resolvedAgent: AgentType {
        session.pendingPlanReview?.requestingAgent ?? session.agentType
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            AgentIcon(agentType: resolvedAgent, size: 20)
            Text(resolvedAgent.shortName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IslandStyle.primaryText)
            Spacer()
            reviewChip
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var reviewChip: some View {
        Text("Plan Review")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.purple)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.purple.opacity(0.15))
            .clipShape(Capsule())
    }

    private var separator: some View {
        Divider()
            .background(IslandStyle.divider(for: scheme).opacity(IslandStyle.dividerOpacity(for: scheme)))
    }

    // MARK: - 正文与操作区

    private func planBody(_ plan: PendingPlanReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            markdownScroller(plan)
            if isFeedbackExpanded {
                feedbackField
            }
            actionRow(plan)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func markdownScroller(_ plan: PendingPlanReview) -> some View {
        ScrollView {
            MarkdownView(markdown: plan.markdown)
                .padding(12)
        }
        .frame(maxHeight: 300)
        .background(IslandStyle.codeWell(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var feedbackField: some View {
        TextField("Feedback...", text: $draftFeedback, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(IslandStyle.primaryText)
            .padding(8)
            .background(IslandStyle.insetFill(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .lineLimit(3)
            .accessibilityIdentifier(TestAccessibility.planFeedbackField)
    }

    private func actionRow(_ plan: PendingPlanReview) -> some View {
        HStack(spacing: 10) {
            feedbackToggle
            decisionButton(
                title: "Reject",
                tint: .red,
                shortcut: KeyEquivalent("n"),
                identifier: TestAccessibility.planRejectButton
            ) {
                submit(plan, approved: false)
            }
            decisionButton(
                title: "Approve",
                tint: .green,
                shortcut: KeyEquivalent("y"),
                identifier: TestAccessibility.planApproveButton
            ) {
                submit(plan, approved: true)
            }
        }
    }

    private var feedbackToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isFeedbackExpanded.toggle()
            }
        } label: {
            Image(systemName: "text.bubble")
                .font(.system(size: 12))
                .foregroundStyle(IslandStyle.secondaryText)
                .frame(width: 32, height: 32)
                .background(IslandStyle.insetFill(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func decisionButton(
        title: String,
        tint: Color,
        shortcut: KeyEquivalent,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(tint.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .accessibilityIdentifier(identifier)
    }

    private func submit(_ plan: PendingPlanReview, approved: Bool) {
        manager.respondToPlan(
            session: session,
            approved: approved,
            feedback: draftFeedback.isEmpty ? nil : draftFeedback
        )
        onComplete()
    }
}
