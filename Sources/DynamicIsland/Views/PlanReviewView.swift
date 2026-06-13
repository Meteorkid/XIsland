import SwiftUI

struct PlanReviewView: View {
    let session: AgentSession
    let onComplete: () -> Void
    @Environment(SessionManager.self) private var manager
    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }
    @State private var feedback = ""
    @State private var showFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(IslandStyle.divider(for: scheme).opacity(IslandStyle.dividerOpacity(for: scheme)))

            if let plan = session.pendingPlanReview {
                planContent(plan)
            }
        }
        .accessibilityIdentifier(TestAccessibility.planPanel)
    }

    private var displayAgent: AgentType {
        session.pendingPlanReview?.requestingAgent ?? session.agentType
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentIcon(agentType: displayAgent, size: 20)
            Text(displayAgent.shortName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IslandStyle.primaryText)
            Spacer()
            Text("Plan Review")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.purple)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.purple.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func planContent(_ plan: PendingPlanReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                MarkdownView(markdown: plan.markdown)
                    .padding(12)
            }
            .frame(maxHeight: 300)
            .background(IslandStyle.codeWell(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if showFeedback {
                TextField("Feedback...", text: $feedback, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(IslandStyle.primaryText)
                    .padding(8)
                    .background(IslandStyle.insetFill(for: scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .lineLimit(3)
                    .accessibilityIdentifier(TestAccessibility.planFeedbackField)
            }

            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFeedback.toggle()
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

                Button {
                    manager.respondToPlan(session: session, approved: false, feedback: feedback.isEmpty ? nil : feedback)
                    onComplete()
                } label: {
                    Text("Reject")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier(TestAccessibility.planRejectButton)

                Button {
                    manager.respondToPlan(session: session, approved: true, feedback: feedback.isEmpty ? nil : feedback)
                    onComplete()
                } label: {
                    Text("Approve")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.green.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("y", modifiers: .command)
                .accessibilityIdentifier(TestAccessibility.planApproveButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
