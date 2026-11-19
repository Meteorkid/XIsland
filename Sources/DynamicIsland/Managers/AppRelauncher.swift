import AppKit

/// 一键重启：辅助功能授权由 macOS 在进程启动时读取，adhoc 签名下常需重启一次才生效。
/// 这里先拉起一个延迟重启的 shell，再退出当前实例，避免与「重复实例检测」冲突。
enum AppRelauncher {
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1.2; /usr/bin/open -n \"\(bundlePath)\""]
        do {
            try process.run()
        } catch {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }
}
