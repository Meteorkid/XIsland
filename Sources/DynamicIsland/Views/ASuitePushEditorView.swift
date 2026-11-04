import SwiftUI
import AppKit

/// A3：推送渠道编辑。配置写入 `AppPreferences.defaults`；地址与附加标识不进入诊断导出。
struct ASuitePushEditorView: View {
    @AppStorage(ASuiteSettings.pushEnabledKey) private var pushEnabled = false
    @AppStorage(ASuiteSettings.pushOnlyWhenAwayKey) private var onlyWhenAway = true

    @State private var configurations: [PushConfiguration] = ASuiteSettings.pushConfigurations()
    @State private var testResults: [String: String] = [:]

    var body: some View {
        asuiteSection(ASuiteL10n.pushSection) {
            Text(ASuiteL10n.pushDesc)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            asuiteRow(ASuiteL10n.pushToggle, nil) {
                Toggle("", isOn: $pushEnabled).labelsHidden()
            }
            asuiteRow(ASuiteL10n.pushOnlyWhenAway, nil) {
                Toggle("", isOn: $onlyWhenAway).labelsHidden()
            }

            ForEach($configurations) { $config in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Picker("", selection: $config.kind) {
                            ForEach(PushChannelKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Toggle("", isOn: $config.isEnabled).labelsHidden()
                        Spacer()
                        Button(role: .destructive) {
                            configurations.removeAll { $0.id == config.id }
                            testResults.removeValue(forKey: config.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }

                    TextField(ASuiteL10n.pushEndpoint, text: $config.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                    if config.kind.requiresSecret {
                        SecureField(ASuiteL10n.pushIdentifier, text: $config.secret)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10))
                    }

                    HStack(spacing: 8) {
                        Menu(ASuiteL10n.pushEvents) {
                            ForEach(IslandEventKind.allCases, id: \.rawValue) { kind in
                                Button {
                                    var events = config.enabledEvents
                                    if events.contains(kind.rawValue) {
                                        events.remove(kind.rawValue)
                                    } else {
                                        events.insert(kind.rawValue)
                                    }
                                    $config.wrappedValue.enabledEvents = events
                                } label: {
                                    HStack {
                                        Text(kind.rawValue)
                                        if config.enabledEvents.contains(kind.rawValue) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        .font(.system(size: 10))
                        Spacer()
                        Button(ASuiteL10n.pushTest) { sendTest(config) }
                            .font(.system(size: 10))
                        if let result = testResults[config.id] {
                            Text(result)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                )
            }

            Button(ASuiteL10n.pushAdd) {
                configurations.append(PushConfiguration())
            }
            .font(.system(size: 11))
        }
        .onAppear { configurations = ASuiteSettings.pushConfigurations() }
        .onChange(of: configurations) { _, _ in
            ASuiteSettings.savePushConfigurations(configurations)
        }
    }

    private func sendTest(_ config: PushConfiguration) {
        PushNotifier.shared.sendTest(config: config) { result in
            switch result {
            case .success(let code):
                testResults[config.id] = "\(ASuiteL10n.pushTestOK) (\(code))"
            case .failure(let error):
                testResults[config.id] = "\(ASuiteL10n.pushTestFailed): \(error.localizedDescription)"
            }
        }
    }
}
