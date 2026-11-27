import SwiftUI

/// 每项请求独立保存展开与反馈状态，避免同会话多待办互相遮挡或串稿。
struct PendingTaskCardView: View {
    @State private var jumpState = SessionJumpState()
    let session: AgentSession
    @Environment(SessionManager.self) private var manager
    @Environment(ThemeManager.self) private var themeManager
    @FocusState private var feedbackFocused: Bool
    @FocusState private var denyReasonFocused: Bool
    @FocusState private var inputEditorFocused: Bool
    @State private var denyReason = ""
    @State private var isDenyingWithReason = false
    @State private var stopAfterDeny = false
    @State private var editedInput = ""
    @State private var editedCommand = ""
    @State private var isEditingInput = false
    @State private var inputEditError: String?
    @AppStorage("reduceMotion") private var appReduceMotion = false
    @AppStorage("disableAnimations") private var disableAnimations = false
    @AppStorage("symbolEffectsEnabled") private var symbolEffectsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// 待处理卡片本身就在「等待用户处理」，因此图标脉动恒定生效——
    /// 与 `StatusSymbolEffect` 的 `isWaiting` 语义一致。
    private var reduceMotion: Bool {
        !IslandMotionPolicy(reduceMotion: appReduceMotion, systemReduceMotion: systemReduceMotion,
                            disableAnimations: disableAnimations).allowsContinuousAnimation
    }

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                AgentIcon(session: session, size: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IslandStyle.primaryText)
                        .lineLimit(2)
                    Text(session.workingDirectory.isEmpty ? session.agentType.shortName : session.workingDirectory)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.workingDirectory)
                }
                Spacer(minLength: 0)
                Button {
                    let kind: InteractionKind = session.pendingPermission != nil ? .permission
                        : (session.pendingQuestion != nil ? .question : .plan)
                    manager.focusInteraction(session: session, kind: kind)
                    jumpState.request(session, manager: manager)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12))
                        .frame(width: 30, height: 30)
                        .modifier(AttentionPulseModifier(
                            isActive: true,
                            reduceMotion: reduceMotion,
                            isEnabled: symbolEffectsEnabled
                        ))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.interactionOpenAgent)
                .help(L10n.interactionOpenAgent)
            }

            if let permission = session.pendingPermission {
                permissionContent(permission)
                    .id(permission.id)
            }
            if let question = session.pendingQuestion {
                questionContent(question)
                    .id(question.id)
            }
            if let plan = session.pendingPlanReview {
                planContent(plan)
                    .id(plan.id)
            }
        }
        .modifier(SessionJumpFeedback(state: jumpState))
        .padding(12)
        .background(IslandStyle.cardRest(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    IslandStyle.cardStrokeColor(for: scheme).opacity(IslandStyle.cardStrokeRest(for: scheme)),
                    lineWidth: 0.5
                )
        }
        .onChange(of: session.pendingPermission?.id) { _, _ in
            isDenyingWithReason = false
            denyReason = ""
            stopAfterDeny = false
            isEditingInput = false
            editedInput = ""
            editedCommand = ""
            inputEditError = nil
        }
    }

    private func submitDeny(_ permission: PendingPermission) {
        let reason = denyReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let stop = stopAfterDeny
        isDenyingWithReason = false
        isEditingInput = false
        stopAfterDeny = false
        denyReason = ""
        manager.focusInteraction(session: session, kind: .permission)
        manager.denyPermission(session: session, requestID: permission.id,
                               message: reason.isEmpty ? nil : reason,
                               interrupt: stop)
    }

    private func beginEditingInput(_ permission: PendingPermission) {
        isDenyingWithReason = false
        denyReason = ""
        inputEditError = nil
        if let command = PermissionInputEditing.command(tool: permission.tool,
                                                        toolInput: permission.toolInput) {
            editedCommand = command
            editedInput = ""
        } else {
            editedCommand = ""
            editedInput = PermissionInputEditing.prettyJSON(toolInput: permission.toolInput)
        }
        isEditingInput = true
        inputEditorFocused = true
    }

    private func submitEditedInput(_ permission: PendingPermission) {
        let raw: String
        if PermissionInputEditing.command(tool: permission.tool,
                                          toolInput: permission.toolInput) != nil {
            let command = editedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                inputEditError = L10n.permissionEmptyCommand
                return
            }
            guard let replaced = PermissionInputEditing.replacingCommand(
                toolInput: permission.toolInput, command: command) else {
                inputEditError = L10n.permissionInvalidInput
                return
            }
            raw = replaced
        } else {
            let trimmed = editedInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard PermissionInputEditing.parsedObject(trimmed) != nil else {
                inputEditError = L10n.permissionInvalidInput
                return
            }
            raw = trimmed
        }
        guard manager.approvePermission(session: session, requestID: permission.id,
                                        updatedInput: raw) else {
            inputEditError = L10n.permissionInvalidInput
            return
        }
        isEditingInput = false
        editedInput = ""
        editedCommand = ""
        inputEditError = nil
    }

    private func permissionContent(_ permission: PendingPermission) -> some View {
        let diffPreview = permission.diffPreview
        return VStack(alignment: .leading, spacing: 8) {
            requestHeading(L10n.permission, symbol: "exclamationmark.triangle.fill", color: .orange)
            if let origin = permission.originAgentID, !origin.isEmpty {
                Text(L10n.subagentPermission(origin))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if session.pendingPermissionDepth > 1 {
                Text(L10n.permissionQueueCount(session.pendingPermissionDepth - 1))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IslandStyle.secondaryText)
            }
            Text(permission.tool)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IslandStyle.primaryText)
                .textSelection(.enabled)

            if permission.state.isExpanded {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !permission.operationText.isEmpty {
                            Text(permission.operationText)
                        }
                        if !permission.description.isEmpty, permission.description != permission.operationText {
                            Text(permission.description)
                        }
                        if let input = permission.toolInput, !input.isEmpty, input != permission.operationText {
                            Text(L10n.permissionRawInput)
                                .fontWeight(.semibold)
                            Text(input)
                        }
                        if let path = permission.filePath, !path.isEmpty {
                            Text(path)
                        }
                        if let diff = permission.diff, !diff.isEmpty {
                            Text(diff)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(IslandStyle.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
                }
                .frame(height: 200)
                .background(IslandStyle.codeWell(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                if !permission.operationText.isEmpty {
                    Text(permission.operationText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if let path = permission.filePath, !path.isEmpty {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let diff = permission.diff, !diff.isEmpty, diffPreview == nil {
                    Text(L10n.permissionDiffAvailable)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.secondaryText)
                }
            }

            if let diffPreview {
                PermissionDiffPreviewView(preview: diffPreview,
                                          expanded: permission.state.isExpanded,
                                          scheme: scheme,
                                          requestID: permission.id)
            }
            detailsButton(
                title: L10n.viewPermissionDetails,
                state: permission.state,
                kind: .permission,
                requestID: permission.id,
                base: "island.permission-details"
            )
            ApprovalContextMapView(session: session, pendingKind: .permission)
            ApprovalAuditHistoryView(records: manager.approvalAuditRecords(for: session))
            HStack(spacing: 8) {
                decisionButton(L10n.denyTitle, color: .red, enabled: permission.state.canSubmit,
                               base: TestAccessibility.permissionDenyButton, requestID: permission.id) {
                    isDenyingWithReason = false
                    isEditingInput = false
                    stopAfterDeny = false
                    manager.focusInteraction(session: session, kind: .permission)
                    manager.denyPermission(session: session, requestID: permission.id)
                }
                if permission.requestingAgent == .claudeCode, permission.state.canSubmit {
                    Button {
                        denyReason = ""
                        stopAfterDeny = false
                        isEditingInput = false
                        isDenyingWithReason = true
                        denyReasonFocused = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 10))
                            Text(L10n.permissionDenyWithReason)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(IslandStyle.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(IslandStyle.insetFill(for: scheme))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.permissionDenyWithReason)
                    .accessibilityIdentifier("island.permission-deny-with-reason")
                }
                if permission.canApprove {
                    decisionButton(L10n.approveTitle, color: .green, enabled: permission.state.canSubmit,
                                   base: TestAccessibility.permissionApproveButton, requestID: permission.id) {
                        isDenyingWithReason = false
                        isEditingInput = false
                        manager.focusInteraction(session: session, kind: .permission)
                        manager.approvePermission(session: session, requestID: permission.id)
                    }
                } else {
                    decisionButton(L10n.permissionDeferToNative, color: .orange,
                                   enabled: permission.state.canSubmit,
                                   base: TestAccessibility.permissionDeferButton, requestID: permission.id) {
                        isDenyingWithReason = false
                        isEditingInput = false
                        manager.focusInteraction(session: session, kind: .permission)
                        manager.deferPermission(session: session, requestID: permission.id)
                    }
                }
            }
            if permission.requestingAgent == .claudeCode, permission.state.canSubmit {
                Button {
                    isDenyingWithReason = false
                    isEditingInput = false
                    stopAfterDeny = false
                    manager.focusInteraction(session: session, kind: .permission)
                    manager.denyPermission(session: session, requestID: permission.id,
                                           interrupt: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 10))
                        Text(L10n.permissionDenyAndStop)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(L10n.permissionStopHint)
                .accessibilityIdentifier("island.permission-deny-and-stop")
            }
            if permission.requestingAgent == .claudeCode, permission.tool == "Bash",
               permission.originAgentID == nil,
               permission.state.canSubmit, permission.canApprove,
               PermissionInputEditing.exactBashCommand(toolInput: permission.toolInput) != nil {
                Button {
                    isDenyingWithReason = false
                    isEditingInput = false
                    stopAfterDeny = false
                    manager.focusInteraction(session: session, kind: .permission)
                    manager.approvePermissionForSession(session: session, requestID: permission.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 10))
                        Text(L10n.permissionAllowForSession)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(Color.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(L10n.permissionAllowForSessionHint)
                .accessibilityIdentifier("island.permission-allow-for-session")
            }
            if permission.requestingAgent == .claudeCode, permission.canApprove,
               permission.state.canSubmit, permission.toolInput != nil {
                Button {
                    beginEditingInput(permission)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                        Text(L10n.permissionEditInput)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(IslandStyle.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(IslandStyle.insetFill(for: scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(L10n.permissionEditHint)
                .accessibilityIdentifier("island.permission-edit-input")
            }
            if isEditingInput {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.permissionEditHint)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.secondaryText)
                    if PermissionInputEditing.command(tool: permission.tool,
                                                      toolInput: permission.toolInput) != nil {
                        TextField(L10n.permissionEditCommandLabel, text: $editedCommand, axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(.roundedBorder)
                            .focused($inputEditorFocused)
                            .accessibilityIdentifier("island.permission-edit-command")
                    } else {
                        TextEditor(text: $editedInput)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(minHeight: 72, maxHeight: 110)
                            .padding(4)
                            .background(IslandStyle.codeWell(for: scheme))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .focused($inputEditorFocused)
                            .accessibilityIdentifier("island.permission-edit-json")
                    }
                    if let inputEditError {
                        Text(inputEditError)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                    HStack(spacing: 8) {
                        Button(L10n.permissionCancel) {
                            isEditingInput = false
                            editedInput = ""
                            editedCommand = ""
                            inputEditError = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.secondaryText)
                        Spacer()
                        Button(L10n.permissionApproveEdited) {
                            submitEditedInput(permission)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.green)
                        .accessibilityIdentifier("island.permission-approve-edited")
                    }
                }
            }
            if isDenyingWithReason {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L10n.permissionDenyReasonPlaceholder, text: $denyReason, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .focused($denyReasonFocused)
                        .accessibilityIdentifier("island.permission-deny-reason")
                    Toggle(L10n.permissionStopThisTurn, isOn: $stopAfterDeny)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .accessibilityIdentifier("island.permission-deny-stop")
                    HStack(spacing: 8) {
                        Button(L10n.permissionCancel) {
                            isDenyingWithReason = false
                            denyReason = ""
                            stopAfterDeny = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.secondaryText)
                        Spacer()
                        Button(L10n.permissionSubmitDeny) {
                            submitDeny(permission)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.red)
                        .accessibilityIdentifier("island.permission-submit-deny")
                    }
                }
            }
            deliveryStatus(permission.state, kind: .permission, requestID: permission.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier(TestAccessibility.permissionPanel, requestID: permission.id))
    }

    private func questionContent(_ question: PendingQuestion) -> some View {
        let canAnswer = !question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!question.options.isEmpty || question.allowsCustomAnswer)
        return VStack(alignment: .leading, spacing: 8) {
            requestHeading(L10n.question, symbol: "questionmark.bubble", color: .blue)
            ScrollView {
                Text(question.text)
                    .font(.system(size: 12))
                    .foregroundStyle(IslandStyle.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 100)

            if canAnswer {
                if question.allowsMultipleAnswers {
                    MultipleQuestionInputView(question: question, sessionID: session.id, onFocus: {
                        manager.focusInteraction(session: session, kind: .question, requestID: question.id)
                    }) { values in
                        manager.focusInteraction(session: session, kind: .question)
                        manager.answerQuestion(session: session, answers: values, requestID: question.id)
                    }
                } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            Button {
                                manager.focusInteraction(session: session, kind: .question)
                                manager.answerQuestion(session: session, answer: option, requestID: question.id)
                            } label: {
                                Text(option)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(IslandStyle.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(IslandStyle.insetFill(for: scheme))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .disabled(!question.state.canSubmit)
                            .accessibilityIdentifier(identifier(TestAccessibility.questionOption(index: index), requestID: question.id))
                        }
                    }
                }
                .frame(minHeight: min(200, CGFloat(question.options.count) * 44), maxHeight: 200)
                if question.allowsCustomAnswer {
                    CustomQuestionInputView(question: question, sessionID: session.id, onFocus: {
                        manager.focusInteraction(session: session, kind: .question, requestID: question.id)
                    }) { answer in
                        manager.focusInteraction(session: session, kind: .question)
                        manager.answerQuestion(session: session, answer: answer, requestID: question.id)
                    }
                }
                }
            } else {
                Text(L10n.questionUnavailable)
                    .font(.system(size: 11))
                    .foregroundStyle(IslandStyle.secondaryText)
                if question.state.phase != .failed {
                    jumpButton(kind: .question, requestID: question.id)
                }
            }
            deliveryStatus(question.state, kind: .question, requestID: question.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier(TestAccessibility.questionPanel, requestID: question.id))
    }

    private func planContent(_ plan: PendingPlanReview) -> some View {
        @Bindable var state = plan.state
        return VStack(alignment: .leading, spacing: 8) {
            requestHeading(L10n.review, symbol: "doc.text.magnifyingglass", color: .purple)
            if state.isExpanded {
                ScrollView {
                    MarkdownView(markdown: plan.markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 200)
                .background(IslandStyle.codeWell(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(plan.markdown)
                    .font(.system(size: 11))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            detailsButton(
                title: L10n.viewFullPlan,
                state: state,
                kind: .plan,
                requestID: plan.id,
                base: "island.plan-details"
            )
            TextField(L10n.planFeedback, text: $state.draftFeedback, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(IslandStyle.primaryText)
                .lineLimit(2...4)
                .padding(8)
                .background(IslandStyle.insetFill(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(!state.canSubmit)
                .focused($feedbackFocused)
                .onChange(of: feedbackFocused) { _, focused in
                    if focused { manager.focusInteraction(session: session, kind: .plan) }
                }
                .accessibilityLabel(L10n.planFeedback)
                .accessibilityIdentifier(identifier(TestAccessibility.planFeedbackField, requestID: plan.id))
            ApprovalContextMapView(session: session, pendingKind: .planReview)
            HStack(spacing: 8) {
                decisionButton(L10n.planDeny, color: .red, enabled: state.canSubmit,
                               base: TestAccessibility.planRejectButton, requestID: plan.id) {
                    submitPlan(plan, approved: false)
                }
                decisionButton(L10n.planApprove, color: .green, enabled: state.canSubmit,
                               base: TestAccessibility.planApproveButton, requestID: plan.id) {
                    submitPlan(plan, approved: true)
                }
            }
            deliveryStatus(state, kind: .plan, requestID: plan.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier(TestAccessibility.planPanel, requestID: plan.id))
    }

    private func submitPlan(_ plan: PendingPlanReview, approved: Bool) {
        manager.focusInteraction(session: session, kind: .plan)
        manager.respondToPlan(
            session: session,
            approved: approved,
            feedback: plan.state.draftFeedback.isEmpty ? nil : plan.state.draftFeedback,
            requestID: plan.id
        )
    }

    private func requestHeading(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
    }

    private func detailsButton(
        title: String,
        state: InteractionRequestState,
        kind: InteractionKind,
        requestID: UUID,
        base: String
    ) -> some View {
        Button {
            manager.focusInteraction(session: session, kind: kind)
            state.isExpanded.toggle()
        } label: {
            Label(state.isExpanded ? L10n.showLess : title,
                  systemImage: state.isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .medium))
                .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.cyan)
        .accessibilityIdentifier(identifier(base, requestID: requestID))
    }

    private func decisionButton(
        _ title: String,
        color: Color,
        enabled: Bool,
        base: String,
        requestID: UUID,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IslandStyle.primaryText)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(color.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityIdentifier(identifier(base, requestID: requestID))
    }

    @ViewBuilder
    private func deliveryStatus(_ state: InteractionRequestState, kind: InteractionKind, requestID: UUID) -> some View {
        switch state.phase {
        case .pending:
            EmptyView()
        case .sending:
            Label(L10n.interactionSending, systemImage: "arrow.up.circle")
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.secondaryText)
        case .sent:
            Label(L10n.interactionSent, systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.secondaryText)
        case .failed:
            Text(L10n.interactionFailed)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            jumpButton(kind: kind, requestID: requestID)
        }
    }

    private func jumpButton(kind: InteractionKind, requestID: UUID) -> some View {
        Button {
            manager.focusInteraction(session: session, kind: kind)
            jumpState.request(session, manager: manager)
        } label: {
            Label(L10n.interactionOpenAgent, systemImage: "arrow.up.forward.app")
                .font(.system(size: 11, weight: .medium))
                .frame(minHeight: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.cyan)
        .accessibilityIdentifier(identifier("island.interaction-jump", requestID: requestID))
    }

    private func identifier(_ base: String, requestID: UUID) -> String {
        TestAccessibility.interactionControl(base, sessionID: session.id, requestID: requestID)
    }
}
