import SwiftUI
import AppKit

/// A 类功能的设置入口。所有开关默认关闭，改动通过 `UserDefaults.didChangeNotification`
/// 触发 `ASuiteSettings.apply()` 重新注册系统资源。
struct ASuiteSettingsView: View {
    @Environment(\.softwareLicenseController) private var softwareLicense
    @AppStorage(ASuiteSettings.notificationsEnabledKey) private var notificationsEnabled = false
    @AppStorage(ASuiteSettings.notificationsAllowDecisionsKey) private var allowDecisions = false

    /// 未授权时页面可达但只读：用户可以查看有哪些能力、也可以关闭，
    /// 但不能开启，避免把系统级功能变成授权绕过入口。
    private var licensed: Bool {
        softwareLicense?.allowsAccess ?? AppPreferences.allowsLicenseFixture
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !licensed {
                    Label(ASuiteL10n.licenseRequired, systemImage: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(ASuiteL10n.paneIntro)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                section(ASuiteL10n.notificationsSection) {
                    settingRow(ASuiteL10n.notificationsToggle, ASuiteL10n.notificationsDesc) {
                        Toggle("", isOn: $notificationsEnabled).labelsHidden()
                    }
                    settingRow(ASuiteL10n.allowDecisions, ASuiteL10n.allowDecisionsDesc) {
                        Toggle("", isOn: $allowDecisions).labelsHidden()
                    }
                    .disabled(!notificationsEnabled)
                    Text(ASuiteL10n.notificationPermissionHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                ASuitePushEditorView()
                ASuiteQuietSettingsView()
                ASuiteLifecycleSettingsView()
                ASuiteKeepAwakeSettingsView()
                ASuiteDiagnosticsSettingsView()
            }
            .padding(20)
            .disabled(!licensed)
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ASuiteSettingsLayout.section(title, content: content)
    }

    private func settingRow<Trailing: View>(
        _ title: String,
        _ description: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        ASuiteSettingsLayout.row(title, description, trailing: trailing)
    }
}

/// A 类各设置段共用的轻量布局，避免复用 `PreferencesView` 的私有 helper。
enum ASuiteSettingsLayout {
    static func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }

    static func row<Trailing: View>(
        _ title: String,
        _ description: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11))
                if let description {
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension View {
    /// 供其他 A 类设置段复用同一套版式。
    func asuiteSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ASuiteSettingsLayout.section(title, content: content)
    }

    func asuiteRow<Trailing: View>(
        _ title: String,
        _ description: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        ASuiteSettingsLayout.row(title, description, trailing: trailing)
    }
}
