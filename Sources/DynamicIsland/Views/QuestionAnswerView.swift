import SwiftUI

struct QuestionAnswerView: View {
    let session: AgentSession
    let onComplete: () -> Void
    @Environment(SessionManager.self) private var manager
    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }
    /// Snapshot captured at init time; persists after `pendingQuestion` is cleared on answer,
    /// keeping the layout stable throughout the collapse animation.
    @State private var frozenQuestion: PendingQuestion?
    @State private var submittedAnswer: String? = nil

    init(session: AgentSession, onComplete: @escaping () -> Void) {
        self.session = session
        self.onComplete = onComplete
        _frozenQuestion = State(initialValue: session.pendingQuestion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(IslandStyle.divider(for: scheme).opacity(IslandStyle.dividerOpacity(for: scheme)))

            if let q = frozenQuestion {
                // Render from snapshot; updated live until an answer is submitted
                // (prevents layout freeze on OpenCode's streaming question updates).
                questionContent(q, selectedAnswer: submittedAnswer)
            } else {
                // Question was handled externally before this view mounted.
                Color.clear.frame(height: 1).onAppear { onComplete() }
            }
        }
        .accessibilityIdentifier(TestAccessibility.questionPanel)
        // Keep frozenQuestion in sync until user submits (handles agents like OpenCode that
        // fire multiple question.asked events as the question is streamed/updated).
        // Once submittedAnswer is set the snapshot is locked — preventing height jump on answer.
        .onChange(of: session.pendingQuestion?.id) { _, _ in
            guard submittedAnswer == nil, let newQ = session.pendingQuestion else { return }
            frozenQuestion = newQ
        }
    }

    private var displayAgent: AgentType {
        frozenQuestion?.requestingAgent ?? session.agentType
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentIcon(agentType: displayAgent, size: 20)
            Text(displayAgent.shortName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IslandStyle.primaryText)
            Spacer()
            Text("Question")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func questionContent(_ q: PendingQuestion, selectedAnswer: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 16))
                Text(q.text)
                    .font(.system(size: 12))
                    .foregroundStyle(IslandStyle.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { index, option in
                    let isSelected = selectedAnswer == option
                    Button {
                        guard submittedAnswer == nil else { return }
                        submittedAnswer = option
                        manager.answerQuestion(session: session, answer: option)
                        onComplete()
                    } label: {
                        HStack {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.green.opacity(0.9))
                                    .frame(width: 24)
                            } else {
                                Text("⌘\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(submittedAnswer == nil
                                        ? IslandStyle.tertiaryText(for: scheme)
                                        : IslandStyle.tertiaryText(for: scheme).opacity(0.5))
                                    .frame(width: 24)
                            }
                            Text(option)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isSelected
                                    ? .white
                                    : (submittedAnswer == nil
                                        ? IslandStyle.primaryText
                                        : IslandStyle.secondaryText))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isSelected ? Color.green.opacity(0.12) : IslandStyle.insetFill(for: scheme))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isSelected ? Color.green.opacity(0.3) : IslandStyle.strokeColor(for: scheme).opacity(IslandStyle.strokeOpacity(for: scheme)),
                                    lineWidth: 0.5
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(submittedAnswer != nil)
                    .accessibilityIdentifier(TestAccessibility.questionOption(index: index))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
