import Foundation

struct ToolEvent: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let tool: String
    let input: String?
    var result: String?
    var linesAdded: Int?
    var linesRemoved: Int?
    var isComplete: Bool
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
         linesRead: Int? = nil, testResults: TestResults? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.tool = tool
        self.input = input
        self.result = result
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.isComplete = isComplete
        self.linesRead = linesRead
        self.testResults = testResults
    }

    /// Parse test result patterns from tool output (e.g. "3 passed, 1 failed, 0 skipped").
    static func parseTestResults(from output: String?) -> TestResults? {
        guard let output = output else { return nil }

        // Python/unittest style: "3 passed, 1 failed, 0 skipped"
        if let passed = firstInt(matching: #"(\d+)\s*passed"#, in: output),
           let failed = firstInt(matching: #"(\d+)\s*failed"#, in: output) {
            let skipped = firstInt(matching: #"(\d+)\s*skipped"#, in: output) ?? 0
            let total = passed + failed + skipped
            if total > 0 { return TestResults(passed: passed, failed: failed, skipped: skipped, total: total) }
        }

        // jest/vitest style: "Tests: 5 passed, 6 total"
        if let passed = firstInt(matching: #"(\d+)\s+passed"#, in: output),
           let total = firstInt(matching: #"(\d+)\s+total"#, in: output) {
            let failed = total - passed
            return TestResults(passed: passed, failed: failed, skipped: 0, total: total)
        }

        // go test style: "--- PASS:" / "--- FAIL:"
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
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > 0 ? lines.count : nil
    }

    // MARK: - Regex helpers

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
