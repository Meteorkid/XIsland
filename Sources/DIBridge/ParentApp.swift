import Foundation

/// 通过父进程链定位发起 hook 的桌面应用。
///
/// Trae 等 IDE 经 shell 执行 hook 命令，父进程是 `/bin/sh`，
/// 需要向上若干层找到 `.app/Contents/MacOS/...`，再读出应用名。
/// 用于区分同名但不同发行版的客户端（例如 Trae 与 Trae CN）。
enum ParentApp {
    static func name() -> String? {
        var pid = getppid()
        for _ in 0..<5 {
            guard pid > 1 else { return nil }
            guard let command = ps(pid, "comm=") else { return nil }
            if let appPath = appBundlePath(in: command) {
                return displayName(atAppPath: appPath)
            }
            guard let ppidText = ps(pid, "ppid="), let ppid = pid_t(ppidText) else { return nil }
            pid = ppid
        }
        return nil
    }

    private static func ps(_ pid: pid_t, _ field: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", field, "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func appBundlePath(in path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func displayName(atAppPath path: String) -> String? {
        guard let bundle = Bundle(path: path) else { return nil }
        return (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}
