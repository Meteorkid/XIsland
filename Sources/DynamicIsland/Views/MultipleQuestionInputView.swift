import SwiftUI

struct MultipleQuestionInputView: View {
    let question: PendingQuestion
    let sessionID: String
    let onFocus: () -> Void
    let submit: ([String]) -> Void
    @FocusState private var focusedControl: Int?

    var body: some View {
        @Bindable var state = question.state
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(question.options.indices, id: \.self) { index in
                        let option = question.options[index]
                        Toggle(option, isOn: Binding(get: { state.selectedAnswers.contains(option) }, set: { selected in
                            guard state.canSubmit else { return }
                            onFocus()
                            if selected { state.selectedAnswers.insert(option) }
                            else { state.selectedAnswers.remove(option) }
                        }))
                        .toggleStyle(.checkbox)
                        .focused($focusedControl, equals: index)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(TestAccessibility.interactionControl(TestAccessibility.questionOption(index: index), sessionID: sessionID, requestID: question.id))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: min(180, CGFloat(question.options.count) * 28), maxHeight: 180)
            if question.allowsCustomAnswer {
                TextField(L10n.customAnswer, text: $state.draftAnswer, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedControl, equals: -1)
                    .accessibilityIdentifier(TestAccessibility.interactionControl(TestAccessibility.customAnswerField, sessionID: sessionID, requestID: question.id))
            }
            Button(L10n.sendAnswer) { submit(question.selectedAnswerValues) }
                .disabled(!question.acceptsAnswers(question.selectedAnswerValues))
                .accessibilityIdentifier(TestAccessibility.interactionControl(TestAccessibility.multipleAnswerSubmit, sessionID: sessionID, requestID: question.id))
        }
        .font(.system(size: 12))
        .disabled(!state.canSubmit)
        .onChange(of: focusedControl) { _, control in
            if control != nil && state.canSubmit { onFocus() }
        }
    }
}
