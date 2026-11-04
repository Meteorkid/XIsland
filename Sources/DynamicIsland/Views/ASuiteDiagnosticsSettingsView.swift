import SwiftUI
import AppKit

/// A6：诊断包导出。使用 `NSSavePanel` 由用户选择位置，导出前文本已全部脱敏。
struct ASuiteDiagnosticsSettingsView: View {
    @State private var status = ""

    var body: some View {
        asuiteSection(ASuiteL10n.diagnosticsSection) {
            Text(ASuiteL10n.diagnosticsDesc)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(ASuiteL10n.diagnosticsExport) { export() }
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xisland-diagnostics-\(Int(Date().timeIntervalSince1970)).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let sessions = AppDelegate.shared?.sessionManager.sessions ?? []
            let artifact = try DiagnosticsExporter.export(
                summaries: IslandSummaryMapper.make(sessions),
                settings: DiagnosticsTextBuilder.snapshotSettings(),
                logFiles: DiagnosticsExporter.recentLogFiles(),
                destination: url)
            status = "\(ASuiteL10n.diagnosticsOK): \(artifact.url.lastPathComponent) (\(artifact.byteCount) B)"
        } catch {
            status = "\(ASuiteL10n.diagnosticsFailed): \(error.localizedDescription)"
        }
    }
}
