import Darwin
import Foundation

/// One process in the ancestry walk from a hook bridge to the terminal that owns it.
struct ProcessTreeEntry: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let tty: String?
    let command: String
}

/// Resolves a controlling TTY without assuming that the hook inherited `TTY`,
/// `TERM_SESSION_ID` or a terminal-specific variable. Hooks are often spawned
/// through a shell, an IDE extension host or a multiplexer, so walking the
/// process ancestry is the only identity that remains available in those cases.
enum ProcessTreeResolver {
    static func controllingTTY(
        startingAt pid: Int32,
        lookup: (Int32) -> ProcessTreeEntry? = lookupProcess
    ) -> String? {
        var current = pid
        var visited = Set<Int32>()
        // Bound the walk: launchd/WindowServer cycles and unexpected reparenting
        // must not turn a click into an unbounded subprocess loop.
        for _ in 0..<32 {
            guard current > 1, visited.insert(current).inserted,
                  let entry = lookup(current) else { return nil }
            if let tty = entry.tty.flatMap(normalizeTTY), isValidTTY(tty) { return tty }
            guard entry.parentPID > 1, entry.parentPID != current else { return nil }
            current = entry.parentPID
        }
        return nil
    }

    static func lookupProcess(_ pid: Int32) -> ProcessTreeEntry? {
        guard pid > 1 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=", "-o", "tty=", "-o", "comm=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            usleep(50_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let line = String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let parent = Int32(fields[0]) else { return nil }
        let rawTTY = String(fields[1])
        let command = fields.dropFirst(2).joined(separator: " ")
        return ProcessTreeEntry(
            pid: pid,
            parentPID: parent,
            tty: normalizeTTY(rawTTY),
            command: command
        )
    }

    static func normalizeTTY(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "??", value != "-", value != "none" else { return nil }
        if value.hasPrefix("/dev/") { return isValidTTY(value) ? value : nil }
        guard value.hasPrefix("tty") else { return nil }
        let path = "/dev/" + value
        return isValidTTY(path) ? path : nil
    }

    static func isValidTTY(_ path: String) -> Bool {
        guard path.hasPrefix("/dev/tty"), path.utf8.count <= 128 else { return false }
        let suffix = path.dropFirst(8)
        return !suffix.isEmpty && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }
}
