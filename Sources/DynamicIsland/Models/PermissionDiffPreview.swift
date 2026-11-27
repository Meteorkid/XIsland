import Foundation

/// 审批卡里的文件改动预览；只解析 Claude 文件工具的 `tool_input`，不读取目标文件。
/// 目标是让用户在批准前看到具体旧/新行，而不是只看一段 JSON；不参与 allow/deny 决策。
struct PermissionDiffPreview: Equatable {
    enum Kind: String {
        case edit = "Edit"
        case write = "Write"
        case multiEdit = "MultiEdit"
        case notebook = "NotebookEdit"
    }

    struct Hunk: Identifiable, Equatable {
        let id: Int
        let oldLines: [String]
        let newLines: [String]
        let oldLineCount: Int
        let newLineCount: Int
        let replaceAll: Bool

        var isTruncated: Bool {
            oldLines.count < oldLineCount || newLines.count < newLineCount
        }
    }

    let kind: Kind
    let filePath: String
    /// NotebookEdit 的 `edit_mode`；其他工具为 nil。
    let notebookMode: String?
    let hunks: [Hunk]
    let addedLineCount: Int
    let removedLineCount: Int
    let omittedHunkCount: Int
    let truncatedLineCount: Int

    var isTruncated: Bool {
        omittedHunkCount > 0 || truncatedLineCount > 0 || hunks.contains(where: \.isTruncated)
    }

    static let maxInputBytes = 200_000
    static let maxPathBytes = 1_024
    static let maxLineCharacters = 400
    static let maxHunks = 8
    static let maxLinesPerSide = 12

    /// 支持 Claude 的 Edit / Write / MultiEdit / NotebookEdit。
    /// 输入不完整、含 NUL、路径可疑或超过预算时返回 nil，UI 继续显示原始 tool_input。
    static func make(tool: String, filePath: String?, toolInput: String?) -> PermissionDiffPreview? {
        let kind: Kind
        switch tool.lowercased() {
        case "edit": kind = .edit
        case "write": kind = .write
        case "multiedit": kind = .multiEdit
        case "notebookedit": kind = .notebook
        default: return nil
        }

        guard let raw = toolInput, !raw.isEmpty, raw.utf8.count <= maxInputBytes,
              !raw.utf8.contains(0),
              let object = PermissionInputEditing.parsedObject(raw) else { return nil }

        guard let path = resolvedPath(filePath: filePath, object: object) else { return nil }

        var hunks: [Hunk] = []
        var added = 0
        var removed = 0
        var omittedHunks = 0
        var truncatedLines = 0
        var notebookMode: String?

        func appendHunk(_ oldText: String, _ newText: String, replaceAll: Bool) {
            let old = lines(oldText)
            let new = lines(newText)
            added += new.count
            removed += old.count
            truncatedLines += (old.filter { $0.count > maxLineCharacters }.count
                + new.filter { $0.count > maxLineCharacters }.count)
            guard hunks.count < maxHunks else {
                omittedHunks += 1
                return
            }
            hunks.append(Hunk(
                id: hunks.count,
                oldLines: old.prefix(maxLinesPerSide).map { displayLine($0) },
                newLines: new.prefix(maxLinesPerSide).map { displayLine($0) },
                oldLineCount: old.count,
                newLineCount: new.count,
                replaceAll: replaceAll
            ))
        }

        switch kind {
        case .edit:
            guard let oldText = text(object["old_string"]),
                  let newText = text(object["new_string"]),
                  !oldText.isEmpty || !newText.isEmpty else { return nil }
            appendHunk(oldText, newText,
                       replaceAll: (object["replace_all"] as? Bool) ?? false)

        case .write:
            guard let content = text(object["content"]) else { return nil }
            appendHunk("", content, replaceAll: false)

        case .multiEdit:
            guard let edits = object["edits"] as? [[String: Any]], !edits.isEmpty else { return nil }
            var parsed: [(String, String, Bool)] = []
            for edit in edits {
                guard let oldText = text(edit["old_string"]),
                      let newText = text(edit["new_string"]),
                      !oldText.isEmpty || !newText.isEmpty else { return nil }
                parsed.append((oldText, newText,
                               (edit["replace_all"] as? Bool) ?? false))
            }
            for item in parsed {
                appendHunk(item.0, item.1, replaceAll: item.2)
            }

        case .notebook:
            let mode = object["edit_mode"] as? String
            notebookMode = mode
            guard let source = text(object["new_source"]) ?? (mode == "delete" ? "" : nil)
            else { return nil }
            appendHunk("", source, replaceAll: false)
        }

        guard !hunks.isEmpty else { return nil }
        return PermissionDiffPreview(
            kind: kind,
            filePath: path,
            notebookMode: notebookMode,
            hunks: hunks,
            addedLineCount: added,
            removedLineCount: removed,
            omittedHunkCount: omittedHunks,
            truncatedLineCount: truncatedLines
        )
    }

    private static func resolvedPath(filePath: String?, object: [String: Any]) -> String? {
        for candidate in [filePath, object["file_path"] as? String,
                          object["notebook_path"] as? String,
                          object["path"] as? String,
                          object["filePath"] as? String] {
            if let path = normalizedPath(candidate) { return path }
        }
        return nil
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxPathBytes,
              !trimmed.utf8.contains(0),
              !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
        return trimmed
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.utf8.contains(0) else { return nil }
        return value
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n"), !result.isEmpty {
            result.removeLast()
        }
        return result
    }

    private static func displayLine(_ line: String) -> String {
        guard line.count > maxLineCharacters else { return line }
        return String(line.prefix(maxLineCharacters)) + "…"
    }
}
