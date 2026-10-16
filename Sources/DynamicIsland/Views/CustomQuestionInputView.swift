import SwiftUI

struct CustomQuestionInputView: View {
    let question: PendingQuestion
    let sessionID: String
    let onFocus: () -> Void
    let submit: (String) -> Void
    @FocusState private var textFocused: Bool

    var body: some View {
        @Bindable var state = question.state
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L10n.customAnswer, text: $state.draftAnswer, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($textFocused)
                .onChange(of: textFocused) { _, focused in
                    if focused && state.canSubmit { onFocus() }
                }
                .disabled(!state.canSubmit)
                .accessibilityIdentifier(TestAccessibility.interactionControl(TestAccessibility.customAnswerField, sessionID: sessionID, requestID: question.id))
            Button(L10n.sendAnswer) { submit(state.draftAnswer) }
                .disabled(!state.canSubmit || !question.acceptsAnswer(state.draftAnswer))
                .accessibilityIdentifier(TestAccessibility.interactionControl(TestAccessibility.customAnswerSubmit, sessionID: sessionID, requestID: question.id))
        }
    }
}
