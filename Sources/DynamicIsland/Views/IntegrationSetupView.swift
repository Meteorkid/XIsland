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

    @State private var showsAllSources = false
    @State private var showsCodexGuide = true

    private var detectedRows: [IntegrationSetupRow] { rows.filter { $0.phase != .notInstalled } }
    private var missingRows: [IntegrationSetupRow] { rows.filter { $0.phase == .notInstalled } }
    private var needsAuthorization: Bool { rows.contains { $0.phase == .needsAuthorization } }
    private var allConnected: Bool { !detectedRows.isEmpty && detectedRows.allSatisfy { $0.phase == .connected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if needsAuthorization { authorizationNotice }
                    detectedSources
                    if !missingRows.isEmpty { otherSources }
                }
                .padding(24)
            }
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
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
            Text(copy("X Island 会自动准备支持的配置；其他项目请按步骤在客户端启用。需要信任时，由你在原客户端确认。",
                      "Supported connections are prepared automatically. Enable other integrations in their apps, and confirm any trust requests there."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var authorizationNotice: some View {
        Label {
            Text(copy("有软件需要你在原应用中确认授权。未完成时，只影响该软件的接入。",
                      "Some apps need your confirmation in their own settings. Until then, only those connections are limited."))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hand.raised")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("integration-setup.authorization-notice")
    }

    private var detectedSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(copy("已检测到的软件", "Detected apps"))
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(detectedRows.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if detectedRows.isEmpty {
                Text(copy("尚未检测到可接入的软件。安装或打开软件后，点击「重新检查」。",
                          "No supported app detected yet. Install or open an app, then choose Check again."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .accessibilityIdentifier("integration-setup.empty")
            } else {
                sourceList(detectedRows)
            }
        }
    }

    private var otherSources: some View {
        DisclosureGroup(isExpanded: $showsAllSources) {
            sourceList(missingRows)
                .padding(.top, 8)
        } label: {
            Text(copy("查看其他来源（\(missingRows.count)）", "Other sources (\(missingRows.count))"))
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
                if index < sources.count - 1 { Divider().padding(.leading, 60) }
            }
        }
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func sourceRow(_ row: IntegrationSetupRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: row.agent.iconSymbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(row.agent.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        if row.agent == .glm {
                            Text(copy("模型来源", "Model source")).font(.system(size: 11)).foregroundStyle(.secondary)
                        } else if row.agent == .codex && isRefreshing {
                            Text(copy("检查中…", "Checking…")).font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            statusLabel(row.phase)
                        }
                    }
                    Text(row.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.phase == .connected, let lastSeen = row.lastSeen {
                        Text(copy("最近活动：", "Last activity: ") + lastSeen.formatted(
                            .dateTime.year().month().day().hour().minute().locale(Locale(identifier: L10n.effectiveLanguage))))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if row.phase != .connected { actionButton(row) }
            }
            if row.agent == .codex, row.phase == .needsAuthorization {
                DisclosureGroup(isExpanded: $showsCodexGuide) {
                    Text(copy("打开 Codex 的「设置 → 编码 → 钩子」，只审阅并信任 X Island 的钩子。完成后返回这里，点击「重新检查」。",
                              "In Codex, open Settings → Coding → Hooks. Review and trust only the X Island hooks, then return here and choose Check again."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } label: {
                    Text(copy("在 Codex 中完成一次确认", "Confirm once in Codex"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(minHeight: 44)
                }
                .padding(.leading, 44)
                .accessibilityIdentifier("integration-setup.codex-guide")
            }
            if row.phase == .needsSetup, [.workBuddy, .kiro].contains(row.agent), let onPrepareFiles {
                Button(copy("查看接入文件", "Show setup files")) { onPrepareFiles(row.agent) }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshing)
                    .padding(.leading, 44)
                    .accessibilityIdentifier("integration-setup.files.\(row.id)")
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("integration-setup.row.\(row.id)")
    }

    private func statusLabel(_ phase: IntegrationSetupPhase) -> some View {
        Label(statusTitle(phase), systemImage: phase == .connected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(phase == .connected ? Color.green : Color.secondary)
            .fixedSize()
    }

    private func actionButton(_ row: IntegrationSetupRow) -> some View {
        Button {
            switch row.phase {
            case .needsAuthorization: onOpenClient(row.agent)
            case .needsConfiguration, .disabled:
                if row.canConfigure { onConfigure(row.agent) }
                else { onOpenGuide(row.agent) }
            case .waitingForActivity, .checkFailed: onRefresh()
            case .notInstalled, .needsSetup, .connected: onOpenGuide(row.agent)
            }
        } label: {
            Text(actionTitle(row))
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 88, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isRefreshing)
        .accessibilityIdentifier("integration-setup.action.\(row.id)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy("已完成的接入会保留。之后可在 X Island 设置中继续。",
                      "Completed connections are saved. You can continue later in X Island settings."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(action: onRefresh) {
                    HStack(spacing: 8) {
                        if isRefreshing { ProgressView().controlSize(.small) }
                        Text(isRefreshing ? copy("正在检查…", "Checking…") : copy("重新检查", "Check again"))
                    }
                    .frame(minHeight: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isRefreshing)
                .accessibilityIdentifier("integration-setup.refresh")
                Spacer()
                Button(action: onLater) {
                    Text(allConnected ? copy("完成", "Done") : copy("稍后再说", "Not now"))
                        .frame(minHeight: 32)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("integration-setup.later")
            }
        }
    }

    private func statusTitle(_ phase: IntegrationSetupPhase) -> String {
        switch phase {
        case .notInstalled: copy("未检测到", "Not detected")
        case .disabled: copy("已关闭", "Disabled")
        case .needsConfiguration: copy("待配置", "Needs configuration")
        case .needsAuthorization: copy("待授权", "Needs authorization")
        case .needsSetup: copy("待完成设置", "Needs setup")
        case .waitingForActivity: copy("等待活动", "Waiting for activity")
        case .connected: copy("已接入", "Connected")
        case .checkFailed: copy("检查失败", "Check failed")
        }
    }

    private func actionTitle(_ row: IntegrationSetupRow) -> String {
        switch row.phase {
        case .needsAuthorization: copy("前往授权", "Authorize in app")
        case .needsConfiguration, .disabled:
            row.canConfigure ? copy("准备接入", "Set up") : copy("查看步骤", "View steps")
        case .waitingForActivity, .checkFailed: copy("重新检查", "Check again")
        case .notInstalled, .needsSetup, .connected: copy("查看步骤", "View steps")
        }
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        L10n.effectiveLanguage == "zh" ? chinese : english
    }
}
