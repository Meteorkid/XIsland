import AppKit
import SwiftUI
import ServiceManagement

private enum PreferencesPane: String, CaseIterable, Identifiable {
    case general
    case agents
    case sound
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .sound: "Sound"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .agents: "terminal.fill"
        case .sound: "speaker.wave.2.fill"
        case .about: "info.circle.fill"
        }
    }
}

struct PreferencesView: View {
    @Environment(AudioEngine.self) private var audioEngine
    @Environment(SessionManager.self) private var sessionManager
    @Environment(UpdateManager.self) private var updateManager
    @State private var sshManager = SSHRemoteManager()
    @State private var selection: PreferencesPane = .general
    @State private var isShowingInstallConfirmation = false
    @State private var showAddServerSheet = false
    @State private var serverLabel = ""
    @State private var serverHost = ""
    @State private var serverPort = 22
    @State private var serverUser = ""
    @State private var serverIdentityFile = ""
    @State private var serverConnectionStatus: String?

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showOnAllSpaces") private var showOnAllSpaces = true
    @AppStorage("autoCollapseDelay") private var autoCollapseDelay = 3.0
    @AppStorage("hideInFullscreen") private var hideInFullscreen = false
    @AppStorage("autoHideWhenNoActiveSessions") private var autoHideWhenNoActiveSessions = false
    @AppStorage("smartSuppression") private var smartSuppression = true
    @AppStorage("compactBadgesInExpandedView") private var compactBadgesInExpandedView = true
    @AppStorage("displayTimestamp") private var displayTimestamp = true
    @AppStorage("reduceMotion") private var reduceMotion = false
    @AppStorage("completedLingerDuration") private var completedLingerDuration = 120.0
    @AppStorage("panelWidth") private var panelWidth = 420.0
    @AppStorage("panelMaxHeight") private var panelMaxHeight = 480.0
    @AppStorage("quietHoursEnabled") private var quietHoursEnabled = false
    @AppStorage("quietHoursStart") private var quietHoursStart = "22:00"
    @AppStorage("quietHoursEnd") private var quietHoursEnd = "07:00"
    @State private var newRulePattern = ""
    @State private var newRuleField: MatchField = .agentType
    @AppStorage(QuotaTracker.anthropicEnabledKey) private var anthropicEnabled = false
    @AppStorage(QuotaTracker.openAIEnabledKey) private var openAIEnabled = false
    @AppStorage(QuotaTracker.kimiEnabledKey) private var kimiEnabled = false
    @AppStorage(QuotaTracker.deepseekEnabledKey) private var deepseekEnabled = false
    @AppStorage(QuotaTracker.glmEnabledKey) private var glmEnabled = false
    @State private var anthropicAPIKey = ""
    @State private var openAIAPIKey = ""
    @State private var kimiAPIKey = ""
    @State private var deepseekAPIKey = ""
    @State private var glmAPIKey = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                paneContent
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 680, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier(TestAccessibility.preferencesRoot)
        .confirmationDialog(
            "Install update now?",
            isPresented: $isShowingInstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("Install Update") {
                Task { @MainActor in
                    await updateManager.installUpdate()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("X Island will close and relaunch to finish the update.")
        }
        .onAppear {
            applyPendingPaneSelectionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xislandShowAboutPane)) { _ in
            applyPendingPaneSelectionIfNeeded(fallbackToAbout: true)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(PreferencesPane.allCases) { pane in
                Button {
                    selection = pane
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: pane.icon)
                                .font(.system(size: 16, weight: .medium))

                            if pane == .about, hasUpdateAvailable {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 6, y: -4)
                            }
                        }
                        Text(pane.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .frame(width: 72, height: 44)
                    // Plain buttons only hit-test non-transparent subviews by default; include label + padding.
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(selection == pane ? .primary : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selection == pane ? Color.accentColor.opacity(0.12) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Pane content

    @ViewBuilder
    private var paneContent: some View {
        switch selection {
        case .general: generalPane
        case .agents: agentsPane
        case .sound: soundPane
        case .about: aboutPane
        }
    }

    // MARK: - General

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("System") {
                card {
                    row("Launch at Login") {
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { _, v in toggleLaunchAtLogin(v) }
                    }
                    dividerLine
                    row("Show on all Spaces") {
                        Toggle("", isOn: $showOnAllSpaces).labelsHidden()
                    }
                }
            }

            section("Behavior") {
                card {
                    row("Bypass mode", subtitle: "Auto-approve all permissions, questions, and plan reviews") {
                        Toggle("", isOn: Binding(
                            get: { sessionManager.bypassMode },
                            set: { sessionManager.bypassMode = $0 }
                        )).labelsHidden()
                    }
                    dividerLine
                    row("Auto-collapse delay", subtitle: "How long the panel stays open after a task completes") {
                        Picker("", selection: $autoCollapseDelay) {
                            Text("1.5s").tag(1.5)
                            Text("3s").tag(3.0)
                            Text("5s").tag(5.0)
                            Text("10s").tag(10.0)
                            Text("Never").tag(0.0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    dividerLine
                    row("Hide in fullscreen") {
                        Toggle("", isOn: $hideInFullscreen).labelsHidden()
                    }
                    dividerLine
                    row("Auto-hide when idle") {
                        Toggle("", isOn: $autoHideWhenNoActiveSessions).labelsHidden()
                    }
                    dividerLine
                    row("Smart suppression", subtitle: "Don't auto-expand when the agent terminal is focused") {
                        Toggle("", isOn: $smartSuppression).labelsHidden()
                    }
                    dividerLine
                    row("Completed session display", subtitle: "How long completed sessions remain visible") {
                        Picker("", selection: $completedLingerDuration) {
                            Text("10s").tag(10.0)
                            Text("30s").tag(30.0)
                            Text("1min").tag(60.0)
                            Text("2min").tag(120.0)
                            Text("5min").tag(300.0)
                            Text("Never").tag(-1.0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                }
            }

            section("Display") {
                card {
                    row("Panel width", subtitle: "\(Int(panelWidth))px") {
                        Slider(value: $panelWidth, in: 320...600, step: 20)
                            .frame(width: 140)
                    }
                    dividerLine
                    row("Panel max height", subtitle: "\(Int(panelMaxHeight))px") {
                        Slider(value: $panelMaxHeight, in: 320...700, step: 20)
                            .frame(width: 140)
                    }
                    dividerLine
                    row("Compact badges") {
                        Toggle("", isOn: $compactBadgesInExpandedView).labelsHidden()
                    }
                    dividerLine
                    row("Show timestamps") {
                        Toggle("", isOn: $displayTimestamp).labelsHidden()
                    }
                    dividerLine
                    row("Reduce motion") {
                        Toggle("", isOn: $reduceMotion).labelsHidden()
                    }
                }
            }

            section("Usage Tracking") {
                card {
                    providerRow("Anthropic", enabled: $anthropicEnabled, key: $anthropicAPIKey,
                                provider: "anthropic", placeholder: "sk-ant-...")
                    dividerLine
                    providerRow("OpenAI", enabled: $openAIEnabled, key: $openAIAPIKey,
                                provider: "openai", placeholder: "sk-...")
                    dividerLine
                    providerRow("Kimi (Moonshot)", enabled: $kimiEnabled, key: $kimiAPIKey,
                                provider: "kimi", placeholder: "sk-...")
                    dividerLine
                    providerRow("DeepSeek", enabled: $deepseekEnabled, key: $deepseekAPIKey,
                                provider: "deepseek", placeholder: "sk-...")
                    dividerLine
                    providerRow("GLM (Zhipu)", enabled: $glmEnabled, key: $glmAPIKey,
                                provider: "glm", placeholder: "...")
                }
            }

            section("Remote Servers") {
                card {
                    if sshManager.servers.isEmpty {
                        Text("No remote servers configured")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(sshManager.servers) { server in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(server.connected ? Color.green : Color.gray.opacity(0.4))
                                            .frame(width: 6, height: 6)
                                        Text(server.label)
                                            .font(.system(size: 13, weight: .medium))
                                        Text("\(server.user)@\(server.host):\(server.port)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    HStack(spacing: 8) {
                                        Button("Test") {
                                            Task {
                                                serverConnectionStatus = try? await sshManager.verifyConnection(for: server)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.blue)
                                        Button("Remove") {
                                            sshManager.removeServer(server)
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.red.opacity(0.7))
                                    }
                                }
                                if let status = serverConnectionStatus, !status.isEmpty {
                                    Text(status)
                                        .font(.system(size: 10))
                                        .foregroundStyle(status == "OK" ? .green : .red.opacity(0.7))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    dividerLine
                    Button("Add Remote Server...") {
                        showAddServerSheet = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                }
            }
        }
        .onAppear {
            anthropicAPIKey = QuotaTracker.loadAPIKey(for: "anthropic") ?? ""
            openAIAPIKey = QuotaTracker.loadAPIKey(for: "openai") ?? ""
            kimiAPIKey = QuotaTracker.loadAPIKey(for: "kimi") ?? ""
            deepseekAPIKey = QuotaTracker.loadAPIKey(for: "deepseek") ?? ""
            glmAPIKey = QuotaTracker.loadAPIKey(for: "glm") ?? ""
        }
        .sheet(isPresented: $showAddServerSheet) {
            addServerSheet
        }
    }

    private var addServerSheet: some View {
        VStack(spacing: 16) {
            Text("Add Remote Server")
                .font(.system(size: 16, weight: .semibold))

            VStack(spacing: 8) {
                HStack {
                    Text("Label:").frame(width: 80, alignment: .trailing)
                    TextField("e.g. dev-server", text: $serverLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
                HStack {
                    Text("Host:").frame(width: 80, alignment: .trailing)
                    TextField("e.g. 192.168.1.10", text: $serverHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
                HStack {
                    Text("Port:").frame(width: 80, alignment: .trailing)
                    TextField("22", value: $serverPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Spacer()
                }
                HStack {
                    Text("User:").frame(width: 80, alignment: .trailing)
                    TextField("e.g. root", text: $serverUser)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
                HStack {
                    Text("Identity File:").frame(width: 80, alignment: .trailing)
                    TextField("optional path to private key", text: $serverIdentityFile)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    showAddServerSheet = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

                Button("Add Server") {
                    sshManager.addServer(
                        label: serverLabel,
                        host: serverHost,
                        port: serverPort,
                        user: serverUser,
                        identityFile: serverIdentityFile.isEmpty ? nil : serverIdentityFile
                    )
                    serverLabel = ""
                    serverHost = ""
                    serverPort = 22
                    serverUser = ""
                    serverIdentityFile = ""
                    showAddServerSheet = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
                .disabled(serverLabel.isEmpty || serverHost.isEmpty || serverUser.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420, height: 300)
    }

    // MARK: - Agents

    private var agentsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("CLI Hooks") {
                card {
                    ForEach(Array(AgentType.allCases.enumerated()), id: \.element.id) { index, agent in
                        hookRow(agent)
                        if index < AgentType.allCases.count - 1 {
                            dividerLine
                        }
                    }
                }

                Button("Reconfigure All Hooks") {
                    ZeroConfigManager.configureAllAgents()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.blue)

                Text("Hooks auto-configure on launch. Use toggles to control per-agent setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            section("IDE Integration") {
                card {
                    ideRow(name: "VS Code", bundleId: "com.microsoft.VSCode")
                    dividerLine
                    ideRow(name: "Cursor", bundleId: "com.todesktop.230313mzl4w4u92")
                    dividerLine
                    ideRow(name: "Windsurf", bundleId: "com.codeium.windsurf")
                    dividerLine
                    ideRow(name: "Trae", bundleId: "com.trae.app")
                    dividerLine
                    ideRow(name: "Trae CN", bundleId: "cn.trae.app")
                }

                Text("Extensions enable direct terminal-tab jumping from the island.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Sound

    private var soundPane: some View {
        @Bindable var engine = audioEngine
        return VStack(alignment: .leading, spacing: 20) {
            section("Playback") {
                card {
                    row("Sound enabled") {
                        Toggle("", isOn: Binding(
                            get: { !engine.isMuted },
                            set: { engine.isMuted = !$0 }
                        )).labelsHidden()
                    }
                    dividerLine
                    row("Volume") {
                        Slider(value: Binding(
                            get: { Double(engine.volume) },
                            set: { engine.volume = Float($0) }
                        ), in: 0...1)
                        .frame(width: 140)
                    }
                }
            }

            section("Quiet Hours") {
                card {
                    row("Enable quiet hours") {
                        Toggle("", isOn: $quietHoursEnabled).labelsHidden()
                    }
                    if quietHoursEnabled {
                        dividerLine
                        row("From") {
                            timePicker(selection: $quietHoursStart)
                        }
                        dividerLine
                        row("To") {
                            timePicker(selection: $quietHoursEnd)
                        }
                        row("Status", subtitle: quietHoursStatusText) {
                            Circle()
                                .fill(engine.isQuietHoursActive ? Color.orange : Color.green.opacity(0.5))
                                .frame(width: 8, height: 8)
                        }
                    }
                }
            }

            section("Mute Rules") {
                card {
                    let rules = audioEngine.muteRules
                    if rules.isEmpty {
                        Text("No rules configured")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(rules) { rule in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("/\(rule.pattern)/")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(rule.matchField.displayName)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { rule.isEnabled },
                                    set: { newValue in
                                        var updated = audioEngine.muteRules
                                        if let idx = updated.firstIndex(where: { $0.id == rule.id }) {
                                            updated[idx].isEnabled = newValue
                                            audioEngine.muteRules = updated
                                        }
                                    }
                                )).labelsHidden()
                                Button {
                                    var updated = audioEngine.muteRules
                                    updated.removeAll { $0.id == rule.id }
                                    audioEngine.muteRules = updated
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.red.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    dividerLine
                    HStack(spacing: 8) {
                        TextField("Regex pattern", text: $newRulePattern)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 140)
                        Picker("", selection: $newRuleField) {
                            ForEach(MatchField.allCases, id: \.rawValue) { field in
                                Text(field.displayName).tag(field)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                        Spacer()
                        Button("Add") {
                            guard !newRulePattern.isEmpty else { return }
                            var updated = audioEngine.muteRules
                            updated.append(MuteRule(pattern: newRulePattern, matchField: newRuleField))
                            audioEngine.muteRules = updated
                            newRulePattern = ""
                        }
                        .controlSize(.small)
                        .disabled(newRulePattern.isEmpty)
                    }
                }
            }

            section("Events") {
                card {
                    ForEach(Array(SoundEvent.allCases.enumerated()), id: \.element.id) { index, event in
                        soundEventRow(event)
                        if index < SoundEvent.allCases.count - 1 {
                            dividerLine
                        }
                    }
                }
            }

            section("Sound Pack") {
                card {
                    if let packName = audioEngine.soundPackName {
                        row("Current") {
                            HStack(spacing: 8) {
                                Text(packName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Button("Remove") { audioEngine.clearSoundPack() }
                                    .controlSize(.small)
                            }
                        }
                        dividerLine
                    }

                    row(audioEngine.hasCustomSoundPack ? "Change Pack" : "Load Pack") {
                        Button(audioEngine.hasCustomSoundPack ? "Choose..." : "Load...") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.message = "Select a folder with sound files (session_start.wav, error.aiff, etc.)"
                            if panel.runModal() == .OK, let url = panel.url {
                                audioEngine.loadSoundPack(from: url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - About

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Application") {
                card {
                    row("Version") {
                        Text(appVersionText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    dividerLine
                    row("Socket") {
                        Text("~/.xisland/di.sock")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    dividerLine
                    row("Bridge") {
                        Text("~/.xisland/bin/di-bridge")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            section("Updates") {
                card {
                    row("Current Version") {
                        Text(updateManager.currentVersion)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    dividerLine
                    row("Latest Release") {
                        Text(updateLatestReleaseText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    dividerLine
                    row("Last Checked") {
                        Text(updateLastCheckedText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    dividerLine
                    row("Status", subtitle: updateStatusDetailText) {
                        Text(updateStatusText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(updateStatusColor)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier(TestAccessibility.updateStatusLabel)
                    }
                    dividerLine
                    row("Actions") {
                        HStack(spacing: 8) {
                            Button(updateCheckButtonTitle) {
                                Task { @MainActor in
                                    await updateManager.checkForUpdates()
                                }
                            }
                            .controlSize(.small)
                            .disabled(isCheckingForUpdates || isInstallingUpdate)
                            .accessibilityIdentifier(TestAccessibility.updateCheckButton)

                            if canInstallUpdate {
                                Button(updateInstallButtonTitle) {
                                    isShowingInstallConfirmation = true
                                }
                                .controlSize(.small)
                                .disabled(isInstallingUpdate)
                                .accessibilityIdentifier(TestAccessibility.updateInstallButton)
                            }
                        }
                    }
                }
            }

            section("Maintenance") {
                card {
                    row("Reconfigure Hooks") {
                        Button("Run Now") { ZeroConfigManager.configureAllAgents() }
                            .controlSize(.small)
                    }
                    dividerLine
                    row("Repair Hooks") {
                        Button("Check & Fix") { ZeroConfigManager.repairHooksIfNeeded() }
                            .controlSize(.small)
                    }
                }
            }

            section("Sessions") {
                card {
                    row("Active") {
                        Text("\(sessionManager.activeSessions.count)")
                            .foregroundStyle(.secondary)
                    }
                    dividerLine
                    row("Total tracked") {
                        Text("\(sessionManager.sessions.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Agent rows

    private func hookRow(_ agent: AgentType) -> some View {
        let status = ZeroConfigManager.hookStatus(for: agent)
        return row(agent.displayName) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(status == .active ? .green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(status == .active ? "Active" : "Off")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "",
                    isOn: Binding(
                        get: { ZeroConfigManager.isAutoConfigEnabled(for: agent) },
                        set: { ZeroConfigManager.setAutoConfigEnabled($0, for: agent) }
                    )
                )
                .labelsHidden()
            }
        }
    }

    private func ideRow(name: String, bundleId: String) -> some View {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
        return row(name) {
            HStack(spacing: 6) {
                Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(installed ? .green : .secondary)
                Text(installed ? "Installed" : "Not Found")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sound event row

    private func soundEventRow(_ event: SoundEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: event.iconSymbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(event.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if audioEngine.hasCustomSound(for: event) {
                        Image(systemName: "waveform")
                            .font(.system(size: 8))
                            .foregroundStyle(.blue)
                    }
                }
                Text(event.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                previewSound(event)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.3), in: Circle())

            Toggle(
                "",
                isOn: Binding(
                    get: { audioEngine.isEnabled(event) },
                    set: { audioEngine.setEnabled(event, $0) }
                )
            )
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func previewSound(_ event: SoundEvent) {
        let wasMuted = audioEngine.isMuted
        audioEngine.isMuted = false
        let wasEnabled = audioEngine.isEnabled(event)
        audioEngine.setEnabled(event, true)
        audioEngine.play(event)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            audioEngine.isMuted = wasMuted
            audioEngine.setEnabled(event, wasEnabled)
        }
    }

    // MARK: - Reusable layout helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func row<Trailing: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.vertical, 8)
    }

    private var dividerLine: some View {
        Divider().overlay(.quaternary.opacity(0.4))
    }

    private func providerRow(_ name: String, enabled: Binding<Bool>, key: Binding<String>,
                             provider: String, placeholder: String) -> some View {
        Group {
            row(name) {
                Toggle("", isOn: enabled).labelsHidden()
            }
            if enabled.wrappedValue {
                dividerLine
                row("\(name) API Key", subtitle: "Stored in Keychain") {
                    SecureField(placeholder, text: key)
                        .frame(width: 200)
                        .onChange(of: key.wrappedValue) { _, newValue in
                            _ = QuotaTracker.saveAPIKey(newValue, for: provider)
                        }
                }
            }
        }
    }

    // MARK: - Helpers

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var isCheckingForUpdates: Bool {
        if case .checking = updateManager.state {
            return true
        }
        return false
    }

    private var isInstallingUpdate: Bool {
        if case .installing = updateManager.state {
            return true
        }
        return false
    }

    private var canInstallUpdate: Bool {
        Self.shouldShowInstallButton(state: updateManager.state, latestRelease: updateManager.latestRelease)
    }

    private var updateLatestReleaseText: String {
        updateManager.latestRelease?.normalizedVersion ?? "Not checked yet"
    }

    private var updateLastCheckedText: String {
        guard let lastCheckedAt = updateManager.lastCheckedAt else {
            return "Never"
        }

        return lastCheckedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var updateCheckButtonTitle: String {
        isCheckingForUpdates ? "Checking..." : "Check for Updates"
    }

    private var updateInstallButtonTitle: String {
        if let version = updateManager.latestRelease?.normalizedVersion {
            return "Install \(version)"
        }
        return "Install Update"
    }

    private var updateStatusText: String {
        switch updateManager.state {
        case .idle:
            return canInstallUpdate ? "Update ready" : "Idle"
        case .checking:
            return "Checking"
        case .upToDate:
            return "Up to date"
        case .updateAvailable(let version):
            return "Version \(version) available"
        case .installing(let stage):
            return stage.capitalized
        case .failed:
            return "Failed"
        }
    }

    private var updateStatusDetailText: String? {
        switch updateManager.state {
        case .failed(let message):
            return message
        case .installing:
            return "X Island will close and relaunch when installation is ready."
        default:
            return nil
        }
    }

    private var updateStatusColor: Color {
        switch updateManager.state {
        case .failed:
            return .red
        case .updateAvailable:
            return .orange
        case .installing:
            return .blue
        default:
            return .secondary
        }
    }

    private var hasUpdateAvailable: Bool {
        switch updateManager.state {
        case .updateAvailable:
            return true
        case .idle:
            if let version = updateManager.latestRelease?.normalizedVersion {
                return UpdateManager.isRemoteVersionNewer(version, than: updateManager.currentVersion)
            }
            return false
        default:
            return false
        }
    }

    static func shouldShowInstallButton(
        state: UpdateManager.State,
        latestRelease: UpdateManager.ReleaseInfo?
    ) -> Bool {
        guard latestRelease?.dmgURL != nil else {
            return false
        }

        if case .updateAvailable = state {
            return true
        }

        return false
    }

    private func timePicker(selection: Binding<String>) -> some View {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        let date = Binding<Date>(
            get: { fmt.date(from: selection.wrappedValue) ?? Date() },
            set: { selection.wrappedValue = fmt.string(from: $0) }
        )
        return DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .frame(width: 120)
    }

    private var quietHoursStatusText: String {
        guard quietHoursEnabled else { return "Disabled" }
        return audioEngine.isQuietHoursActive ? "Active — sounds muted" : "Outside quiet hours"
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[Preferences] Launch at login error: \(error)")
        }
    }
    private func applyPendingPaneSelectionIfNeeded(fallbackToAbout: Bool = false) {
        let defaults = UserDefaults.standard
        let pending = defaults.string(forKey: PreferencesRouting.pendingPaneSelectionKey)
        if pending == PreferencesRouting.aboutPaneValue {
            selection = .about
            defaults.removeObject(forKey: PreferencesRouting.pendingPaneSelectionKey)
            return
        }

        if fallbackToAbout {
            selection = .about
        }
    }
}
