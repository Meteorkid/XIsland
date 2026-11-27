import AppKit
import SwiftUI

/// 全局审批账本视图：最近决定、SHA-256 前序链校验、原始 JSONL 导出。
/// 只展示账本已有的事实；链校验失败时明确报断裂，不把“能读取”当成“未被篡改”。
struct ApprovalHistoryPane: View {
    @Environment(SessionManager.self) private var sessionManager
    @State private var records: [ApprovalAuditRecord] = []
    @State private var verification = ApprovalAuditVerification.unavailable
    @State private var filter = ""
    @State private var search = ""
    @State private var message: String?
    @State private var messageIsError = false

    private var store: ApprovalAuditStore? { sessionManager.approvalAuditStore }

    private var filteredRecords: [ApprovalAuditRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { record in
            if !filter.isEmpty, record.decision.rawValue != filter { return false }
            guard !query.isEmpty else { return true }
            let haystack = [
                record.tool,
                record.sessionID,
                record.agentType,
                record.originAgentID ?? ""
            ].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.approvalHistoryDesc)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Label(chainText, systemImage: chainIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(chainColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(L10n.approvalRefresh) { reload() }
                Button(L10n.approvalExport) { export() }
                    .disabled(store == nil || records.isEmpty)
                Button(L10n.approvalReveal) { revealInFinder() }
                    .disabled(store == nil)
            }

            HStack(spacing: 8) {
                Picker("", selection: $filter) {
                    Text(L10n.approvalFilterAll).tag("")
                    ForEach(ApprovalAuditDecision.allCases, id: \.self) { decision in
                        Text(L10n.approvalDecision(decision)).tag(decision.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .accessibilityLabel(L10n.approvalFilterAll)
                TextField(L10n.approvalSearchPlaceholder, text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    .accessibilityIdentifier("preferences.approvalHistory.search")
                Text("\(filteredRecords.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let store {
                    Text(store.url.lastPathComponent)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            if records.isEmpty {
                Text(L10n.approvalEmpty)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else if filteredRecords.isEmpty {
                Text(L10n.approvalEmpty)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredRecords.prefix(80))) { record in
                        recordRow(record)
                        Divider()
                    }
                }
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(messageIsError ? .orange : .secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("preferences.approvalHistory.root")
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .xislandApprovalAuditDidChange)) { _ in
            reload()
        }
    }

    private var chainText: String {
        switch verification.state {
        case .valid:
            return "\(L10n.approvalChainValid) · \(verification.recordCount)"
        case .broken:
            let line = verification.brokenLine.map { " · L\($0)" } ?? ""
            return "\(L10n.approvalChainBroken)\(line) · \(verification.reason ?? "")"
        case .unavailable:
            return L10n.approvalLedgerUnavailable
        }
    }

    private var chainIcon: String {
        switch verification.state {
        case .valid: "checkmark.seal.fill"
        case .broken: "exclamationmark.triangle.fill"
        case .unavailable: "questionmark.circle"
        }
    }

    private var chainColor: Color {
        switch verification.state {
        case .valid: .green
        case .broken: .orange
        case .unavailable: .secondary
        }
    }

    private func recordRow(_ record: ApprovalAuditRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(decisionColor(record.decision))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(record.tool)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Text(L10n.approvalDecision(record.decision))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(decisionColor(record.decision))
                }
                HStack(spacing: 8) {
                    Text(AgentType.from(record.agentType)?.shortName ?? record.agentType)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let origin = record.originAgentID {
                        Text(L10n.subagentPermission(origin))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let nativeID = record.nativeRequestID {
                        Text(nativeID)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(record.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let latency = record.latencyMilliseconds {
                    Text("\(latency) ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 7)
    }

    private func decisionColor(_ decision: ApprovalAuditDecision) -> Color {
        switch decision {
        case .approved: .green
        case .denied: .red
        case .deferred: .orange
        case .expired, .cancelled, .nativeResolved, .nativeTurnEnded: .secondary
        }
    }

    private func reload() {
        records = sessionManager.approvalAuditRecords(limit: 500)
        verification = sessionManager.approvalAuditVerification()
        message = nil
    }

    private func export() {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xisland-approval-audit-\(Int(Date().timeIntervalSince1970)).jsonl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(to: url)
            message = "\(L10n.approvalExportOK): \(url.lastPathComponent)"
            messageIsError = false
        } catch {
            message = "\(L10n.approvalExportFailed): \(error.localizedDescription)"
            messageIsError = true
        }
    }

    private func revealInFinder() {
        guard let store else { return }
        if FileManager.default.fileExists(atPath: store.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([store.url])
        } else {
            let directory = store.url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: directory.path) {
                NSWorkspace.shared.open(directory)
            } else {
                message = "\(L10n.approvalLedgerUnavailable): \(directory.path)"
                messageIsError = true
            }
        }
    }
}
