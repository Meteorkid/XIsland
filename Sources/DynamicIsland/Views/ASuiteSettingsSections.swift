import SwiftUI

// MARK: - A4 不打扰策略

struct ASuiteQuietSettingsView: View {
    @AppStorage(ASuiteSettings.dndSceneMuteEnabledKey) private var sceneMute = true
    @AppStorage(ASuiteSettings.dndSilencedDirectoriesKey) private var directories = ""
    @AppStorage(ASuiteSettings.dndSuppressSubagentsKey) private var suppressSubagents = true
    @AppStorage(ASuiteSettings.dndFollowUpEnabledKey) private var followUp = false
    @AppStorage(ASuiteSettings.dndFollowUpDelayKey) private var followUpDelay = 600.0

    var body: some View {
        asuiteSection(ASuiteL10n.dndSection) {
            Text(ASuiteL10n.dndDesc)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            asuiteRow(ASuiteL10n.dndSuppressWhenActive, nil) {
                Toggle("", isOn: $sceneMute).labelsHidden()
            }
            asuiteRow(ASuiteL10n.dndSuppressSubagents, nil) {
                Toggle("", isOn: $suppressSubagents).labelsHidden()
            }
            asuiteRow(ASuiteL10n.dndSilenced, nil) {
                TextField(ASuiteL10n.dndSilencedPlaceholder, text: $directories)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            asuiteRow(ASuiteL10n.dndFollowUp, nil) {
                Toggle("", isOn: $followUp).labelsHidden()
            }
            if followUp {
                asuiteRow(ASuiteL10n.dndFollowUpDelay, nil) {
                    Stepper(value: $followUpDelay, in: 60...3600, step: 60) {
                        Text("\(Int(followUpDelay / 60)) \(ASuiteL10n.minutes)")
                            .font(.system(size: 11))
                    }
                }
            }
        }
    }
}

// MARK: - A5 会话生命周期

struct ASuiteLifecycleSettingsView: View {
    @AppStorage(ASuiteSettings.lifecycleAutoHideEnabledKey) private var autoHide = false
    @AppStorage(ASuiteSettings.lifecycleReapEnabledKey) private var reap = false

    var body: some View {
        asuiteSection(ASuiteL10n.lifecycleSection) {
            Text(ASuiteL10n.lifecycleDesc)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            asuiteRow(ASuiteL10n.lifecycleAutoHide, nil) {
                Toggle("", isOn: $autoHide).labelsHidden()
            }
            asuiteRow(ASuiteL10n.lifecycleReap, nil) {
                Toggle("", isOn: $reap).labelsHidden()
            }
        }
    }
}

// MARK: - A7 防休眠

struct ASuiteKeepAwakeSettingsView: View {
    @AppStorage(ASuiteSettings.keepAwakeModeKey) private var mode = KeepAwakeMode.off.rawValue

    var body: some View {
        asuiteSection(ASuiteL10n.keepAwakeSection) {
            asuiteRow(ASuiteL10n.keepAwakeMode, ASuiteL10n.keepAwakeDesc) {
                Picker("", selection: $mode) {
                    Text(ASuiteL10n.keepAwakeOff).tag(KeepAwakeMode.off.rawValue)
                    Text(ASuiteL10n.keepAwakeAuto).tag(KeepAwakeMode.auto.rawValue)
                    Text(ASuiteL10n.keepAwakeAlways).tag(KeepAwakeMode.always.rawValue)
                }
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }
}
