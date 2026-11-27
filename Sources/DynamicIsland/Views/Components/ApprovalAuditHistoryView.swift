import SwiftUI

/// 审批卡底部的最近决定摘要，数据来自本地 append-only 账本。
/// 只显示已记录的决定，不把“已发送”或“已取消”伪装成批准/拒绝。
struct ApprovalAuditHistoryView: View {
    let records: [ApprovalAuditRecord]
    var maxRows: Int = 3
    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.approvalHistory)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IslandStyle.secondaryText)
                ForEach(records.prefix(maxRows)) { record in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: record.decision))
                            .frame(width: 5, height: 5)
                        Text(record.tool)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(IslandStyle.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(L10n.approvalDecision(record.decision))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(color(for: record.decision))
                        Text(record.timestamp, format: .dateTime.hour().minute())
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(IslandStyle.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 2)
        }
    }

    private func color(for decision: ApprovalAuditDecision) -> Color {
        switch decision {
        case .approved: return .green
        case .denied: return .red
        case .deferred: return .orange
        case .expired, .cancelled, .nativeResolved, .nativeTurnEnded: return IslandStyle.secondaryText
        }
    }
}
