import AppKit
import SwiftUI
import UserNotifications

/// 设置页「权限」面板：集中展示每项系统权限的当前状态与授权入口，
/// 避免用户到功能触发时才发现没授权。
struct PermissionsSection: View {
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var notificationsGranted = false
    @State private var notificationsKnown = false
    @State private var resetNotice: String?
    @AppStorage("accessibilityNeedsReauth") private var needsReauth = false

    private var runningPath: String { Bundle.main.bundlePath }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(
                title: L10n.permissionAccessibility,
                detail: needsReauth && !accessibilityGranted
                    ? L10n.permissionReauthAfterUpdate
                    : String(format: L10n.permissionAccessibilityDetailPath, runningPath),
                state: accessibilityGranted ? .granted : .missing,
                open: { AccessibilityDragHelper.shared.present() },
                reveal: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
                openTitle: L10n.permissionOpenAndFloat
            )
            divider
            row(
                title: L10n.permissionAutomation,
                detail: L10n.permissionAutomationDetail,
                state: .onDemand,
                open: { SystemPrivacySettings.openAutomation() },
                reveal: nil
            )
            divider
            row(
                title: L10n.permissionNotifications,
                detail: L10n.permissionNotificationsDetail,
                state: notificationsKnown ? (notificationsGranted ? .granted : .missing) : .onDemand,
                open: { SystemPrivacySettings.openNotifications() },
                reveal: nil
            )
            divider
            HStack {
                Text(resetNotice ?? L10n.permissionHint)
                    .font(.system(size: 10))
                    .foregroundStyle(resetNotice == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L10n.permissionRelaunch) { AppRelauncher.relaunch() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button(L10n.permissionResetAccessibility) { resetAccessibility() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button(L10n.permissionRefresh) { refresh() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.cyan)
            }
            .padding(.top, 8)
        }
        .task { refresh() }
        // 从系统设置切回来时立即重新检测：授权生效不需要重启应用。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        // 停在权限页时低频轮询，授权列表里勾选后一两秒内即可看到状态变化。
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private enum State {
        case granted, missing, onDemand
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.vertical, 8)
    }

    private func row(title: String, detail: String, state: State,
                     open: @escaping () -> Void, reveal: (() -> Void)?,
                     openTitle: String = L10n.permissionOpenSettings) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text(label(for: state))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(color(for: state))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(color(for: state).opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Button(openTitle, action: open)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.cyan)
                if let reveal {
                    Button(L10n.permissionRevealApp, action: reveal)
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(for state: State) -> String {
        switch state {
        case .granted: return L10n.permissionGranted
        case .missing: return L10n.permissionMissing
        case .onDemand: return L10n.permissionOnDemand
        }
    }

    private func color(for state: State) -> Color {
        switch state {
        case .granted: return .green
        case .missing: return .orange
        case .onDemand: return .secondary
        }
    }

    private func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted, needsReauth {
            // 授权成功后清除「版本更新需重新授权」标记。
            needsReauth = false
        }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                notificationsKnown = settings.authorizationStatus != .notDetermined
                notificationsGranted = settings.authorizationStatus == .authorized
            }
        }
    }

    /// 清掉本 bundle id 的旧授权记录（列表里可能残留之前版本的条目），随后重新拖入。
    private func resetAccessibility() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility",
                             Bundle.main.bundleIdentifier ?? "dev.xisland.app"]
        do {
            try process.run()
            process.waitUntilExit()
            resetNotice = L10n.permissionResetDone
        } catch {
            resetNotice = error.localizedDescription
        }
        accessibilityGranted = AXIsProcessTrusted()
    }
}
