import Foundation

/// A6：把脱敏后的文本打包成 zip。文本生成在 `DiagnosticsTextBuilder`。
enum DiagnosticsExporter {
    enum ExportError: LocalizedError, Equatable {
        case stagingFailed
        case zipFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .stagingFailed: return "Could not create staging directory"
            case .zipFailed(let code): return "zip exited with status \(code)"
            }
        }
    }

    struct Artifact: Equatable, Sendable {
        let url: URL
        let byteCount: Int
    }

    static func export(summaries: [IslandSessionSummary],
                       settings: [String: String],
                       logFiles: [(name: String, text: String)],
                       appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                       osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                       generatedAt: Date = Date(),
                       destination: URL) throws -> Artifact {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("xisland-diagnostics-\(UUID().uuidString)", isDirectory: true)
        do { try fileManager.createDirectory(at: staging, withIntermediateDirectories: true) }
        catch { throw ExportError.stagingFailed }
        defer { try? fileManager.removeItem(at: staging) }

        let manifest = DiagnosticsTextBuilder.manifestText(
            appVersion: appVersion, osVersion: osVersion,
            generatedAt: generatedAt, settings: settings)
        try manifest.write(to: staging.appendingPathComponent("manifest.txt"),
                           atomically: true, encoding: .utf8)
        try DiagnosticsTextBuilder.sessionsText(summaries)
            .write(to: staging.appendingPathComponent("sessions.json"),
                   atomically: true, encoding: .utf8)

        let logs = staging.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        for entry in logFiles {
            let safeName = entry.name
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "..", with: "_")
            try EventRedaction.redact(entry.text)
                .write(to: logs.appendingPathComponent(safeName), atomically: true, encoding: .utf8)
        }

        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        process.arguments = ["-q", "-r", destination.path, "."]
        do { try process.run() } catch { throw ExportError.stagingFailed }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExportError.zipFailed(process.terminationStatus) }

        let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return Artifact(url: destination, byteCount: size)
    }

    /// 收集本机日志尾部（best effort），读不到就返回空。
    static func recentLogFiles(limit: Int = 3, tailBytes: Int = 64 * 1024) -> [(name: String, text: String)] {
        let fileManager = FileManager.default
        guard let logsURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Logs") else { return [] }
        let names = (try? fileManager.contentsOfDirectory(atPath: logsURL.path)) ?? []
        let matched = names.filter { $0.lowercased().contains("xisland") }.sorted().suffix(limit)
        return matched.compactMap { name in
            let url = logsURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return (name, String(decoding: data.suffix(tailBytes), as: UTF8.self))
        }
    }
}
