import SwiftUI

/// 问题回答面板：展示代理抛出的问题与选项，用户点选后回传答案。
struct QuestionAnswerView: View {
    let session: AgentSession
    let onComplete: () -> Void

    @Environment(SessionManager.self) private var manager
    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    /// init 时对问题做的快照；回答后 `pendingQuestion` 被清空，快照仍保留，
    /// 从而在收起动画期间保持布局稳定。
    @State private var snapshotQuestion: PendingQuestion?
    @State private var submittedAnswer: String? = nil

    init(session: AgentSession, onComplete: @escaping () -> Void) {
        self.session = session
        self.onComplete = onComplete
        _snapshotQuestion = State(initialValue: session.pendingQuestion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            separator

            if let question = snapshotQuestion {
                // 从快照渲染；提交前会实时跟随流式问题更新（适配 OpenCode 的分次
                // question.asked 事件），提交后锁定，避免回答瞬间高度跳动。
                questionBody(question, selectedAnswer: submittedAnswer)
            } else {
                // 挂载前问题已被外部处理，直接走完成回调。
                Color.clear.frame(height: 1).onAppear { onComplete() }
            }
        }
        .accessibilityIdentifier(TestAccessibility.questionPanel)
        .onChange(of: session.pendingQuestion?.id) { _, _ in
            guard submittedAnswer == nil, let latest = session.pendingQuestion else { return }
            snapshotQuestion = latest
        }
    }

    // MARK: - 顶部标题栏

    private var resolvedAgent: AgentType {
        snapshotQuestion?.requestingAgent ?? session.agentType
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            AgentIcon(agentType: resolvedAgent, size: 20)
            Text(resolvedAgent.shortName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IslandStyle.primaryText)
            Spacer()
            questionChip
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var questionChip: some View {
        Text("Question")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.blue.opacity(0.15))
            .clipShape(Capsule())
    }

    private var separator: some View {
        Divider()
            .background(IslandStyle.divider(for: scheme).opacity(IslandStyle.dividerOpacity(for: scheme)))
    }

    // MARK: - 问题与选项

    private func questionBody(_ question: PendingQuestion, selectedAnswer: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            prompt(question)
            optionsList(question, selectedAnswer: selectedAnswer)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func prompt(_ question: PendingQuestion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 16))
            Text(question.text)
                .font(.system(size: 12))
                .foregroundStyle(IslandStyle.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionsList(_ question: PendingQuestion, selectedAnswer: String?) -> some View {
        VStack(spacing: 6) {
            ForEach(question.options.indices, id: \.self) { index in
                let option = question.options[index]
                optionRow(option, index: index, isSelected: selectedAnswer == option)
            }
        }
    }

    private func optionRow(_ option: String, index: Int, isSelected: Bool) -> some View {
        Button {
            submit(option)
        } label: {
            optionLabel(option, index: index, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        .disabled(submittedAnswer != nil)
        .accessibilityIdentifier(TestAccessibility.questionOption(index: index))
    }

    private func optionLabel(_ option: String, index: Int, isSelected: Bool) -> some View {
        HStack {
            leadingMarker(index: index, isSelected: isSelected)
            Text(option)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(optionTextColor(isSelected: isSelected))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.green.opacity(0.12) : IslandStyle.insetFill(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { optionBorder(isSelected: isSelected) }
    }

    @ViewBuilder
    private func leadingMarker(index: Int, isSelected: Bool) -> some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green.opacity(0.9))
                .frame(width: 24)
        } else {
            Text("⌘\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(shortcutHintColor)
                .frame(width: 24)
        }
    }

    private var shortcutHintColor: Color {
        let base = IslandStyle.tertiaryText(for: scheme)
        return submittedAnswer == nil ? base : base.opacity(0.5)
    }

    private func optionTextColor(isSelected: Bool) -> Color {
        if isSelected { return .white }
        return submittedAnswer == nil ? IslandStyle.primaryText : IslandStyle.secondaryText
    }

    private func optionBorder(isSelected: Bool) -> some View {
        let stroke: Color = isSelected
            ? Color.green.opacity(0.3)
            : IslandStyle.strokeColor(for: scheme).opacity(IslandStyle.strokeOpacity(for: scheme))
        return RoundedRectangle(cornerRadius: 8)
            .strokeBorder(stroke, lineWidth: 0.5)
    }

    private func submit(_ option: String) {
        guard submittedAnswer == nil else { return }
        submittedAnswer = option
        manager.answerQuestion(session: session, answer: option)
        onComplete()
    }
}
