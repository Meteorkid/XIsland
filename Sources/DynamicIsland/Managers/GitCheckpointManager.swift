import Foundation

/// 基于 git stash 的会话检查点管理。
///
/// 通过 `git stash` 保存工作区快照，并以 stash 对应的 commit hash 作为检查点标识，
/// 恢复时再按消息匹配并弹出对应的 stash。
enum GitCheckpointManager {

    /// 为指定会话创建一个检查点，返回可用于恢复的检查点信息；无法创建时返回 nil。
    static func createCheckpoint(for session: AgentSession, message: String? = nil) -> GitCheckpoint? {
        let directory = session.workingDirectory
        guard !directory.isEmpty else { return nil }

        let commitMessage = message ?? defaultMessage(for: session)

        // 只有 stash 真正成功，后续取到的 hash 才有意义
        guard stashChanges(commitMessage, in: directory) else { return nil }

        let fullHash = latestStashHash(in: directory)
        let shortHash = String((fullHash ?? "unknown").prefix(8))

        return GitCheckpoint(timestamp: Date(), hash: shortHash, message: commitMessage)
    }

    /// 在指定目录中恢复一个检查点，成功返回 true。
    static func restoreCheckpoint(_ checkpoint: GitCheckpoint, in directory: String) -> Bool {
        guard let listing = runGit(in: directory, arguments: ["stash", "list", "--format=%H %s"]) else {
            return false
        }

        let entries = listing.split(separator: "\n")
        for (index, entry) in entries.enumerated() where entry.contains(checkpoint.message) {
            return runGit(in: directory, arguments: ["stash", "pop", "stash@{\(index)}"]) != nil
        }

        return false
    }

    // MARK: - 私有实现

    private static func defaultMessage(for session: AgentSession) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return "checkpoint: \(session.agentType.shortName) @ \(timestamp)"
    }

    private static func stashChanges(_ message: String, in directory: String) -> Bool {
        runGit(in: directory, arguments: ["stash", "push", "-m", message, "--include-untracked"]) != nil
    }

    private static func latestStashHash(in directory: String) -> String? {
        runGit(in: directory, arguments: ["stash", "list", "--format=%H", "-1"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 在指定目录执行 git 命令；成功返回标准输出，失败返回 nil。
    private static func runGit(in directory: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
