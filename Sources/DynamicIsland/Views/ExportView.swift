import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export Format

enum ExportFormat: String, CaseIterable {
    case json
    case markdown
    case csv

    var displayName: String {
        switch self {
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .csv: return "CSV"
        }
    }

    var fileExtension: String {
        switch self {
        case .json: return "json"
        case .markdown: return "md"
        case .csv: return "csv"
        }
    }

    var contentType: UTType {
        switch self {
        case .json: return .json
        case .markdown: return .plainText
        case .csv: return .commaSeparatedText
        }
    }
}

// MARK: - Export Data Model

struct SessionExportData: Codable {
    let sessionId: String
    let agentType: String
    let startTime: String
    let completedAt: String?
    let prompt: String
    let workspaceName: String
    let terminal: String
    let status: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let estimatedCostUSD: Double
    let model: String
    let recapText: String?
    let chatHistory: [ExportChatMessage]
    let toolEvents: [ExportToolEvent]

    struct ExportChatMessage: Codable {
        let timestamp: String
        let role: String
        let content: String
    }

    struct ExportToolEvent: Codable {
        let timestamp: String
        let tool: String
        let input: String?
        let result: String?
        let linesAdded: Int?
        let linesRemoved: Int?
        let linesRead: Int?
        let testPassed: Int?
        let testFailed: Int?
        let isComplete: Bool
    }
}

// MARK: - File Document

struct SessionExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText, .commaSeparatedText] }
    static var writableContentTypes: [UTType] { [.json, .plainText, .commaSeparatedText] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - ExportView

struct ExportView: View {
    let session: AgentSession
    @State private var selectedFormat: ExportFormat = .json
    @State private var showExporter = false
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager

    private var scheme: ColorScheme { themeManager.resolvedScheme }

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.exportSession)
                .font(.system(size: 15, weight: .semibold))

            Text(session.displayTitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.exportFormat)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(ExportFormat.allCases, id: \.rawValue) { format in
                        Button {
                            selectedFormat = format
                        } label: {
                            Text(format.displayName)
                                .font(.system(size: 12, weight: selectedFormat == format ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selectedFormat == format ? Color.accentColor.opacity(0.2) : IslandStyle.insetFill(for: scheme))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(selectedFormat == format ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Button(L10n.exportSession) {
                    showExporter = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 340, height: 200)
        .background(Color(nsColor: .windowBackgroundColor))
        .fileExporter(
            isPresented: $showExporter,
            document: SessionExportDocument(data: exportData),
            contentType: selectedFormat.contentType,
            defaultFilename: "\(session.displayTitle)_\(session.id.prefix(8))"
        ) { result in
            if case .success = result {
                dismiss()
            }
        }
    }

    private var exportData: Data {
        switch selectedFormat {
        case .json: return Self.exportJSON(session: session)
        case .markdown: return Self.exportMarkdown(session: session)
        case .csv: return Self.exportCSV(session: session)
        }
    }

    // MARK: - Export Logic

    static func exportJSON(session: AgentSession) -> Data {
        let exportData = SessionExportData(
            sessionId: session.id,
            agentType: session.agentType.rawValue,
            startTime: ISO8601DateFormatter().string(from: session.startTime),
            completedAt: session.completedAt.map { ISO8601DateFormatter().string(from: $0) },
            prompt: session.prompt,
            workspaceName: session.workspaceName,
            terminal: session.terminal,
            status: session.status.rawValue,
            inputTokens: session.tokenUsage.inputTokens,
            outputTokens: session.tokenUsage.outputTokens,
            totalTokens: session.tokenUsage.totalTokens,
            estimatedCostUSD: session.tokenUsage.estimatedCostUSD,
            model: session.tokenUsage.model,
            recapText: session.recapText,
            chatHistory: session.chatHistory.map { msg in
                SessionExportData.ExportChatMessage(
                    timestamp: ISO8601DateFormatter().string(from: msg.timestamp),
                    role: msg.role.rawValue,
                    content: msg.content
                )
            },
            toolEvents: session.events.map { event in
                SessionExportData.ExportToolEvent(
                    timestamp: ISO8601DateFormatter().string(from: event.timestamp),
                    tool: event.tool,
                    input: event.input,
                    result: event.result,
                    linesAdded: event.linesAdded,
                    linesRemoved: event.linesRemoved,
                    linesRead: event.linesRead,
                    testPassed: event.testResults?.passed,
                    testFailed: event.testResults?.failed,
                    isComplete: event.isComplete
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(exportData)) ?? Data()
    }

    static func exportMarkdown(session: AgentSession) -> Data {
        var md = ""
        md += "# Session: \(session.displayTitle)\n"
        md += "Agent: \(session.agentType.shortName) | Workspace: \(session.workspaceName)\n"
        md += "Started: \(session.startTime.formatted(date: .abbreviated, time: .shortened))"
        if let completed = session.completedAt {
            md += " | Completed: \(completed.formatted(date: .abbreviated, time: .shortened))"
        }
        md += " | Duration: \(session.formattedDuration)\n"

        let tokens = session.tokenUsage.formattedTokens
        let cost = session.tokenUsage.formattedCost
        if !tokens.isEmpty || !cost.isEmpty {
            md += "Tokens: \(tokens)"
            if !cost.isEmpty { md += " | Cost: \(cost)" }
            md += "\n"
        }

        if !session.prompt.isEmpty {
            md += "\n## Prompt\n\(session.prompt)\n"
        }

        if !session.chatHistory.isEmpty {
            md += "\n## Chat History\n"
            for msg in session.chatHistory {
                let role = msg.role.rawValue.capitalized
                md += "**\(role)**: \(msg.content)\n"
            }
        }

        if !session.events.isEmpty {
            md += "\n## Tool Events\n"
            for event in session.events {
                md += "- \(event.displayName): \(event.summary)\n"
            }
        }

        if let recap = session.recapText, !recap.isEmpty {
            md += "\n## Recap\n\(recap)\n"
        }

        return md.data(using: .utf8) ?? Data()
    }

    static func exportCSV(session: AgentSession) -> Data {
        var csv = "timestamp,tool,input,result_summary,lines_added,lines_removed,test_passed,test_failed\n"
        for event in session.events {
            let input = event.input?.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ") ?? ""
            let result = event.summary.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
            let ts = ISO8601DateFormatter().string(from: event.timestamp)
            let added = event.linesAdded.map { String($0) } ?? ""
            let removed = event.linesRemoved.map { String($0) } ?? ""
            let passed = event.testResults.map { String($0.passed) } ?? ""
            let failed = event.testResults.map { String($0.failed) } ?? ""
            csv += "\(ts),\(event.tool),\"\(input)\",\"\(result)\",\(added),\(removed),\(passed),\(failed)\n"
        }
        return csv.data(using: .utf8) ?? Data()
    }
}
