import AppKit
import MeteorLicenseCore
import SwiftUI

struct SoftwareLicenseView: View {
    @Environment(\.softwareLicenseController) private var controller
    @State private var code = ""
    @State private var confirmsDeactivation = false

    private var isChinese: Bool { L10n.isChinese }
    private var locale: String { isChinese ? "zh" : "en" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isChinese ? "XIsland 软件授权" : "XIsland Software License")
                .font(.title2.bold())
            Text(isChinese
                 ? "完整试用 14 天。可选一个月、一年或永久激活，每份授权最多同时使用 3 台设备。"
                 : "Try all features for 14 days. Choose 1 month, 1 year, or Lifetime access for up to 3 devices.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let controller {
                VStack(alignment: .leading, spacing: 8) {
                    Label(statusTitle(controller.state), systemImage: controller.allowsAccess ? "checkmark.shield.fill" : "lock.shield")
                        .font(.headline)
                    if case .active(let payload) = controller.state {
                        if let expiry = payload.entitlementExpiresAt {
                            Text((isChinese ? "使用期限：" : "Valid until: ") + formattedDate(expiry))
                        }
                        Text((isChinese ? "可离线使用至：" : "Offline access until: ") + formattedDate(payload.expiresAt))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = controller.lastError {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    TextField(isChinese ? "输入此软件的激活码" : "Enter the activation code for this product", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("xisland.license.code")
                        .onSubmit { activate(controller) }
                    Button(isChinese ? "激活" : "Activate") { activate(controller) }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isBusy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(spacing: 12) {
                    Button(isChinese ? "联网核验" : "Verify online") { controller.revalidate() }
                        .disabled(controller.isBusy)
                    if case .needsConnection = controller.state {
                        Button(isChinese ? "开启 14 天试用" : "Start 14-day trial") {
                            Task { await controller.requestTrial() }
                        }.disabled(controller.isBusy)
                    }
                    if case .active(let payload) = controller.state, payload.kind != .trial {
                        Button(isChinese ? "解绑本机" : "Deactivate this device", role: .destructive) {
                            confirmsDeactivation = true
                        }.disabled(controller.isBusy)
                    }
                    if controller.isBusy { ProgressView().controlSize(.small) }
                }
            } else {
                Text(isChinese ? "此隔离测试窗口未连接授权服务。" : "Licensing is disconnected in this isolated test window.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Link(isChinese ? "购买 / 续费" : "Buy / Renew", destination: URL(string: "https://www.imagentx.top/\(locale)/products/xisland#pricing")!)
                Link(isChinese ? "管理设备与激活码" : "Manage devices and licenses", destination: URL(string: "https://www.imagentx.top/\(locale)/account#software-licenses")!)
            }
            Text(isChinese
                 ? "首次试用、激活和解绑需要联网。到期后保留购买、激活及历史导出，不删除已有数据。"
                 : "Starting a trial, activation, and deactivation require a connection. When access expires, purchase, activation, and history export remain available; your data is retained.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(isChinese ? "解绑本机后，XIsland 将停止运行主要功能。" : "Deactivating this device will stop XIsland's main features.", isPresented: $confirmsDeactivation) {
            Button(isChinese ? "解绑本机" : "Deactivate this device", role: .destructive) {
                if let controller { Task { await controller.deactivate() } }
            }
            Button(isChinese ? "取消" : "Cancel", role: .cancel) { }
        }
    }

    private func activate(_ controller: SoftwareLicenseController) {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await controller.activate(code: code) }
    }

    private func formattedDate(_ timestamp: TimeInterval) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(
            .dateTime.year().month(.abbreviated).day().hour().minute()
                .locale(Locale(identifier: isChinese ? "zh_CN" : "en_US"))
        )
    }

    private func statusTitle(_ state: SoftwareLicenseState) -> String {
        switch state {
        case .unconfigured: return isChinese ? "此版本尚未配置授权" : "This build is not configured for licensing"
        case .needsConnection: return isChinese ? "请联网开启试用或输入激活码" : "Connect to start a trial or enter your activation code"
        case .expired: return isChinese ? "使用期限已到，请联网核验或续费" : "Access expired. Verify online or renew"
        case .blocked: return isChinese ? "授权暂不可用，请重新激活" : "License unavailable. Please activate again"
        case .active(let payload):
            switch payload.kind {
            case .trial: return isChinese ? "14 天试用中" : "14-day trial active"
            case .monthly: return isChinese ? "一个月授权已激活" : "1 month license active"
            case .annual: return isChinese ? "一年授权已激活" : "1 year license active"
            case .lifetime: return isChinese ? "永久授权已激活" : "Lifetime license active"
            }
        }
    }
}
