import Foundation

struct ToolEvent: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    var tool: String
    /// 会话内关联调用或子代理的 ID；子代理适配器可包含来源命名空间。
    let toolCallId: String?
    var input: String?
    var result: String?
    var linesAdded: Int?
    var linesRemoved: Int?
    var isComplete: Bool
    /// 已收到停止提示或观察已结束，但尚无该调用的最终结果。
    var completionUnconfirmed: Bool
    /// 已核实来源给出的原生终态；完成事件不一定代表成功，旧记录保持 nil。
    var nativeCompletionStatus: String?
    var isRunning: Bool { !isComplete && !completionUnconfirmed }
    var hasFailedOutcome: Bool { nativeCompletionStatus == "failed" }
    var wasCancelled: Bool { ["cancelled", "interrupted"].contains(nativeCompletionStatus ?? "") }
    var hasUnknownOutcome: Bool {
        nativeCompletionStatus != nil && nativeCompletionStatus != "completed" && !hasFailedOutcome && !wasCancelled
    }
    /// Number of lines read (for read operations).
    var linesRead: Int?
    /// Test results summary if this was a test runner.
    var testResults: TestResults?

    struct TestResults: Sendable {
        let passed: Int
        let failed: Int
        let skipped: Int
        let total: Int

        var summary: String {
            if total == 0 { return "" }
            var parts: [String] = []
            if passed > 0 { parts.append("\(passed) passed") }
            if failed > 0 { parts.append("\(failed) failed") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            if parts.isEmpty { parts.append("\(total) total") }
            return parts.joined(separator: ", ")
        }
    }

    var displayName: String {
        switch tool.lowercased() {
        case "read", "readfile": return "Read"
        case "write", "writefile": return "Write"
        case "edit", "editfile", "str_replace": return "Edit"
        case "bash", "shell", "terminal": return "Bash"
        case "search", "grep", "ripgrep": return "Search"
        case "glob", "find": return "Find"
        case "ls", "list": return "List"
        default: return tool.prefix(1).uppercased() + tool.dropFirst()
        }
    }

    var summary: String {
        if completionUnconfirmed { return L10n.completionUnconfirmed }
        if let status = nativeCompletionStatus {
            let preview = result?.split(separator: "\n").first.map { String($0.prefix(80)) } ?? ""
            return preview.isEmpty ? status : "\(status): \(preview)"
        }
        if let path = input, path.contains("/") {
            let file = (path as NSString).lastPathComponent
            if isComplete {
                var parts: [String] = [file]
                if let added = linesAdded, let removed = linesRemoved {
                    parts.append("(+\(added) -\(removed))")
                } else if let lines = linesRead, lines > 0 {
                    parts.append("(\(lines) lines)")
                } else if let result, !result.isEmpty {
                    let bytes = result.utf8.count
                    if bytes > 0 {
                        parts.append("(\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))")
                    }
                }
                if let tr = testResults, tr.total > 0 {
                    parts.append("[\(tr.summary)]")
                }
                return parts.joined(separator: " ")
            }
            return file
        }
        if isComplete {
            if let tr = testResults, tr.total > 0 {
                return tr.summary
            }
            if let result, let firstLine = result.split(separator: "\n").first {
                let trimmed = String(firstLine).trimmingCharacters(in: .whitespaces)
                if trimmed.count < 80 { return trimmed }
            }
            return "Done"
        }
        return "Running..."
    }

    init(tool: String, input: String? = nil, result: String? = nil,
         linesAdded: Int? = nil, linesRemoved: Int? = nil, isComplete: Bool = false,
         linesRead: Int? = nil, testResults: TestResults? = nil, toolCallId: String? = nil,
         completionUnconfirmed: Bool = false, nativeCompletionStatus: String? = nil,
         id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.timestamp = timestamp
        self.tool = tool
        self.toolCallId = toolCallId
        self.input = input
        self.result = result
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.isComplete = isComplete
        self.completionUnconfirmed = completionUnconfirmed
        self.nativeCompletionStatus = nativeCompletionStatus
        self.linesRead = linesRead
        self.testResults = testResults
    }

    /// Parse test result patterns from tool output (e.g. pytest / jest / go test summary lines).
    static func parseTestResults(from output: String?) -> TestResults? {
        guard let output = output else { return nil }

        // Python / pytest: allow missing "failed" when zero failures
        if let passed = firstInt(matching: #"(\d+)\s*passed"#, in: output) {
            let failed = firstInt(matching: #"(\d+)\s*failed"#, in: output) ?? 0
            let skipped = firstInt(matching: #"(\d+)\s*skipped"#, in: output) ?? 0
            let total = passed + failed + skipped
            if total > 0 { return TestResults(passed: passed, failed: failed, skipped: skipped, total: total) }
        }

        // jest / vitest: prefer explicit failed + skipped when present
        if output.localizedCaseInsensitiveContains("tests:"),
           let passed = firstInt(matching: #"(\d+)\s+passed"#, in: output),
           let total = firstInt(matching: #"(\d+)\s+total"#, in: output) {
            let failed = firstInt(matching: #"(\d+)\s+failed"#, in: output)
                ?? max(0, total - passed - (firstInt(matching: #"(\d+)\s+skipped"#, in: output) ?? 0))
            let skipped = firstInt(matching: #"(\d+)\s+skipped"#, in: output) ?? 0
            return TestResults(passed: passed, failed: failed, skipped: skipped, total: total)
        }

        // go test package summary: `ok   pkg 0.1s` or `FAIL\tpkg`
        if let match = firstMatch(
            pattern: #"^(ok|FAIL)\s+(\S+)"#,
            options: [.anchorsMatchLines],
            in: output
        ), !match.isEmpty {
            let statusToken = match[0].uppercased()
            let passed = statusToken == "OK" ? 1 : 0
            let failed = statusToken == "FAIL" ? 1 : 0
            return TestResults(passed: passed, failed: failed, skipped: 0, total: 1)
        }

        // Legacy: "--- PASS:" / "--- FAIL:" line counts
        let passCount = countOccurrences(of: "--- PASS:", in: output)
        let failCount = countOccurrences(of: "--- FAIL:", in: output)
        if passCount > 0 || failCount > 0 {
            return TestResults(passed: passCount, failed: failCount, skipped: 0, total: passCount + failCount)
        }

        return nil
    }

    /// Estimate lines read from output content.
    static func estimateLinesRead(from output: String?) -> Int? {
        guard let output = output, !output.isEmpty else { return nil }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).count
        let bounded = min(max(lines, 1), 50_000)
        return bounded
    }

    // MARK: - Regex helpers

    private static func firstMatch(pattern: String, options: NSRegularExpression.Options, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var caps: [String] = []
        for i in 1..<match.numberOfRanges {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            caps.append(String(text[r]))
        }
        return caps
    }

    private static func firstInt(matching pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[captureRange])
    }

    private static func countOccurrences(of substring: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let foundRange = text.range(of: substring, range: searchRange) {
            count += 1
            searchRange = foundRange.upperBound..<text.endIndex
        }
        return count
    }
}
