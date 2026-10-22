import SwiftUI

struct IntegrationSetupRow: Identifiable {
    let agent: AgentType
    let phase: IntegrationSetupPhase
    let detail: String
    let canConfigure: Bool
    let lastSeen: Date?

    var id: String { agent.rawValue }
}

struct IntegrationSetupView: View {
    let rows: [IntegrationSetupRow]
    let isRefreshing: Bool
    let onConfigure: (AgentType) -> Void
    let onOpenClient: (AgentType) -> Void
    let onOpenGuide: (AgentType) -> Void
    let onRefresh: () -> Void
    let onLater: () -> Void
    var onPrepareFiles: ((AgentType) -> Void)? = nil
    var onPrepareAll: (() -> Void)? = nil
    var focusRequest: IntegrationSetupFocusRequest? = nil
    var clientLaunchFailure: IntegrationClientLauncher.Failure? = nil
    var openingAgent: AgentType? = nil

    @State private var showsReadySources = false
    @State private var showsAllSources = false
    @State private var expandedDetails: Set<String> = []
    @State private var handledFocusID: UUID?

    private var pendingRows: [IntegrationSetupRow] { IntegrationSetupPresentation.pendingRows(rows) }
    private var readyRows: [IntegrationSetupRow] { IntegrationSetupPresentation.readyRows(rows) }
    private var otherRows: [IntegrationSetupRow] { IntegrationSetupPresentation.otherRows(rows) }
    private var hasDisabledSources: Bool { otherRows.contains { $0.phase == .disabled } }
    private var focusTarget: IntegrationSetupFocusTarget? {
        IntegrationSetupPresentation.focusTarget(focusRequest, rows: rows, handledID: handledFocusID)
    }
    private var allConnected: Bool {
        pendingRows.isEmpty && !readyRows.isEmpty && readyRows.allSatisfy { $0.phase == .connected }
    }
    private var primaryAction: IntegrationSetupAction? {
        IntegrationSetupPresentation.primaryAction(rows, canPrepareAll: onPrepareAll != nil,
                                                   canPrepareFiles: onPrepareFiles != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if pendingRows.isEmpty { settledStatus }
                        else { pendingSources }
                        if !readyRows.isEmpty { readySources }
                        if !otherRows.isEmpty { otherSources }
                    }
                    .padding(24)
                }
                .task(id: focusTarget) {
                    guard let target = focusTarget else { return }
                    if readyRows.contains(where: { $0.agent == target.request.agent }) { showsReadySources = true }
                    if otherRows.contains(where: { $0.agent == target.request.agent }) { showsAllSources = true }
                    expandedDetails.insert(target.request.agent.rawValue)
                    // 展开目标分组后，让布局先登记行的位置，再执行一次定位。
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    guard !Task.isCancelled, focusTarget == target else { return }
                    proxy.scrollTo(target.request.agent.rawValue, anchor: .top)
                    handledFocusID = target.request.id
                }
            }
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 12)
        }
        .frame(width: 680, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("integration-setup.root")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("X Island")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(copy("完成软件接入", "Connect your apps"))
                .font(.system(size: 26, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(copy("支持的配置自动完成；需要授权的软件，首次确认一次。",
                      "Supported setup is automatic. Confirm once in each app that needs authorization."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let primaryAction {
                HStack(spacing: 16) {
                    Text(copy("还有 \(pendingRows.count) 个软件待完成", pendingRows.count == 1
                              ? "1 app needs a next step" : "\(pendingRows.count) apps need a next step"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { perform(primaryAction) } label: {
                        HStack(spacing: 8) {
                            if isRefreshing { ProgressView().controlSize(.small) }
                            Text(isRefreshing ? copy("正在检查…", "Checking…") : primaryTitle(primaryAction))
                                .frame(minHeight: 32)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isRefreshing || openingAgent != nil)
                    .accessibilityIdentifier("integration-setup.primary")
                }
                .padding(.top, 8)
            }
        }
    }

    private var pendingSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy("待完成", "Next steps"))
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if pendingRows.contains(where: { $0.phase == .needsAuthorization }) {
                Text(copy("授权在原软件中确认，只影响对应软件。", "Confirm authorization in the original app. Other connections are unaffected."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("integration-setup.authorization-notice")
            }
            sourceList(pendingRows)
        }
    }

    private var settledStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(allConnected ? copy("已完成接入", "Your apps are connected")
                  : readyRows.isEmpty ? (hasDisabledSources ? copy("软件接入已关闭", "App connections are disabled")
                                                            : copy("暂未检测到软件", "No apps detected yet"))
                  : copy("配置已准备", "Setup is ready"),
                  systemImage: allConnected ? "checkmark.circle.fill" : "rectangle.connected.to.line.below")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(allConnected ? Color.green : Color.primary)
            Text(allConnected ? copy("这些软件已收到活动，之后会自动记住。", "Activity has been received. These connections are remembered.")
                 : readyRows.isEmpty ? (hasDisabledSources ? copy("已在设置中关闭，可在 X Island 设置中重新开启。", "Connections were disabled in settings. Re-enable them in X Island settings.")
                                                          : copy("安装或打开软件后，点击「重新检查」。", "Install or open an app, then choose Check again."))
                 : copy("在软件中开始一条任务，收到活动后就会显示已接入。", "Start a task in an app. It will show as connected after activity arrives."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier(readyRows.isEmpty ? "integration-setup.empty" : "integration-setup.ready-summary")
    }

    private var readySources: some View {
        DisclosureGroup(isExpanded: $showsReadySources) {
            sourceList(readyRows).padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy("已准备与已连接（\(readyRows.count)）", "Ready and connected (\(readyRows.count))"))
                    .font(.system(size: 12, weight: .medium))
                Text(readyRows.map(\.agent.displayName).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("integration-setup.ready-sources")
    }

    private var otherSources: some View {
        DisclosureGroup(isExpanded: $showsAllSources) {
            sourceList(otherRows).padding(.top, 8)
        } label: {
            Text(copy("其他来源（\(otherRows.count)）", "Other sources (\(otherRows.count))"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("integration-setup.other-sources")
    }

    private func sourceList(_ sources: [IntegrationSetupRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, row in
                sourceRow(row)
                    .id(row.id)
                if index < sources.count - 1 { Divider().padding(.leading, 56) }
            }
        }
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
    }

    private func sourceRow(_ row: IntegrationSetupRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: row.agent.iconSymbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.agent.displayName).font(.system(size: 13, weight: .semibold))
                        Text(row.agent == .glm ? copy("模型来源", "Model source")
                             : row.agent == .codex && isRefreshing ? copy("检查中…", "Checking…") : statusTitle(row.phase))
                            .font(.system(size: 11))
                            .foregroundStyle(row.phase == .connected ? Color.green : Color.secondary)
                    }
                    Text(row.phase == .disabled
                         ? copy("已在设置中关闭，可在 X Island 设置中重新开启。", "Disabled in settings. Re-enable this connection in X Island settings.")
                         : row.agent == .codex && row.phase == .needsAuthorization
                         ? copy("配置已准备，还需你在 Codex 中确认信任。", "Setup is ready. Confirm trust in Codex to continue.") : row.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let action = IntegrationSetupPresentation.rowAction(row, canPrepareFiles: onPrepareFiles != nil) {
                    Button(openingAgent == row.agent ? copy("正在打开…", "Opening…")
                           : row.agent == .codex && row.phase == .needsAuthorization
                           ? copy("打开 Codex 确认", "Open Codex to confirm") : actionTitle(action)) { perform(action) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isRefreshing || openingAgent != nil)
                        .accessibilityIdentifier(isFileAction(action) ? "integration-setup.files.\(row.id)" : "integration-setup.action.\(row.id)")
                }
            }
            if let failure = clientLaunchFailure, failure.agent == row.agent, row.phase == .needsAuthorization {
                Text(failure.message(language: L10n.effectiveLanguage))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 40)
                    .accessibilityIdentifier("integration-setup.open-error.\(row.id)")
            }
            if row.agent == .codex && row.phase == .needsAuthorization {
                CodexAuthorizationSteps()
                    .padding(.leading, 40)
                    .padding(.top, 8)
                Button(copy("打开完整指南", "Open full guide")) { onOpenGuide(.codex) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.leading, 40)
                    .accessibilityIdentifier("integration-setup.guide.codex")
            } else {
                rowDetails(row).padding(.leading, 40)
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("integration-setup.row.\(row.id)")
    }

    private func rowDetails(_ row: IntegrationSetupRow) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedDetails.contains(row.id) }, set: {
            if $0 { expandedDetails.insert(row.id) } else { expandedDetails.remove(row.id) }
        })) {
            VStack(alignment: .leading, spacing: 8) {
                Text(row.detail)
                if row.phase == .connected, let date = row.lastSeen {
                    Text(copy("最近活动：", "Last activity: ") + date.formatted(
                        .dateTime.year().month().day().hour().minute().locale(Locale(identifier: L10n.effectiveLanguage))))
                }
                Button(copy("打开完整指南", "Open full guide")) { onOpenGuide(row.agent) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier(row.phase == .needsSetup && onPrepareFiles != nil && [AgentType.workBuddy, .kiro].contains(row.agent)
                        ? "integration-setup.action.\(row.id)" : "integration-setup.guide.\(row.id)")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
        } label: {
            Text(copy("详情", "Details"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minHeight: 24)
        }
        .accessibilityIdentifier("integration-setup.details.\(row.id)")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onRefresh) {
                HStack(spacing: 8) {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    Text(copy("重新检查", "Check again")).frame(minHeight: 32)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .accessibilityIdentifier("integration-setup.refresh")
            Spacer()
            Text(copy("已完成的接入会自动记住", "Completed connections are remembered"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(allConnected ? copy("完成", "Done") : copy("稍后再说", "Not now"), action: onLater)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("integration-setup.later")
        }
    }

    private func perform(_ action: IntegrationSetupAction) {
        switch action {
        case .prepareAll: onPrepareAll?()
        case .configure(let agent): onConfigure(agent)
        case .openClient(let agent): onOpenClient(agent)
        case .prepareFiles(let agent): onPrepareFiles?(agent)
        case .openGuide(let agent): onOpenGuide(agent)
        case .refresh: onRefresh()
        }
    }

    private func primaryTitle(_ action: IntegrationSetupAction) -> String {
        switch action {
        case .prepareAll, .configure: copy("自动完成配置", "Set up automatically")
        case .refresh: copy("重新检查", "Check again")
        default: copy("继续接入", "Continue setup")
        }
    }

    private func actionTitle(_ action: IntegrationSetupAction) -> String {
        switch action {
        case .prepareAll, .configure: copy("准备接入", "Set up")
        case .openClient: copy("前往确认", "Open app")
        case .prepareFiles: copy("接入文件", "Setup files")
        case .openGuide: copy("查看步骤", "View steps")
        case .refresh: copy("重新检查", "Check again")
        }
    }

    private func isFileAction(_ action: IntegrationSetupAction) -> Bool {
        if case .prepareFiles = action { return true }
        return false
    }

    private func statusTitle(_ phase: IntegrationSetupPhase) -> String {
        switch phase {
        case .notInstalled: copy("未检测到", "Not detected")
        case .disabled: copy("已关闭", "Disabled")
        case .needsConfiguration: copy("待配置", "Needs setup")
        case .needsAuthorization: copy("待确认", "Needs confirmation")
        case .needsSetup: copy("待完成", "Next step needed")
        case .waitingForActivity: copy("等待活动", "Waiting for activity")
        case .connected: copy("已接入", "Connected")
        case .checkFailed: copy("检查失败", "Check failed")
        }
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        L10n.effectiveLanguage == "zh" ? chinese : english
    }
}

struct CodexAuthorizationNotice: View {
    let onShowSteps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(copy("勾选仅启用接入，还需在 Codex 中确认信任。",
                      "The switch enables this connection. Trust still needs confirmation in Codex."))
                .foregroundStyle(.secondary)
            Text(copy("Codex 输入区 → Review hooks → 选择 X Island 项 → Allow selected",
                      "Codex composer → Review hooks → select X Island entries → Allow selected"))
            Button(copy("查看授权步骤", "View authorization steps"), action: onShowSteps)
                .buttonStyle(.link)
                .accessibilityIdentifier("preferences.integration-authorization.codex.open")
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("preferences.integration-authorization.codex")
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        L10n.effectiveLanguage == "zh" ? chinese : english
    }
}

struct CodexAuthorizationSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step("1", copy("在 Codex 输入区点击「审查钩子 / Review hooks」。",
                           "In the Codex composer, choose Review hooks."))
            step("2", copy("核对命令，只勾选 12 条 X Island 钩子，点击「允许所选项 / Allow selected」。",
                           "Review the commands, select only the 12 X Island hooks, then choose Allow selected."))
            step("3", copy("开始一条任务，再回这里点「重新检查」；收到真实活动后才会显示已接入。",
                           "Start a task, then return here and choose Check again. Connected appears after activity arrives."))
            Text(copy("同一组配置的有效授权会记住；配置改变或授权撤销后需要重新确认。不要使用包含其他插件的「全部信任 / Trust all」。",
                      "Valid authorization is remembered for unchanged hooks. Review again after changes or revocation. Avoid Trust all when it includes other plugins."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("integration-setup.codex-guide")
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number).fontWeight(.semibold).foregroundStyle(.secondary).frame(width: 14)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        L10n.effectiveLanguage == "zh" ? chinese : english
    }
}
