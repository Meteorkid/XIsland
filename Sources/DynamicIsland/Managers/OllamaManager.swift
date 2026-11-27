import AppKit
import Foundation

/// 检测本地 Ollama 状态，并提供一键下载模型的入口。
///
/// 其他用户不会自动获得模型：本类只负责把「未安装 / 无模型 / 就绪」提示出来，
/// 下载动作由用户点击触发，避免在用户不知情时占用带宽与磁盘。
@MainActor
final class OllamaManager: ObservableObject {
    enum Status: Equatable {
        case missing
        case noModel
        case ready(String)
        case pulling
    }

    @Published private(set) var status: Status = .missing
    @Published private(set) var progress: String = ""
    @Published private(set) var installedModels: [String] = []

    nonisolated static let suggestedModel = "qwen2.5:3b"

    struct Recommendation: Identifiable {
        let id: String
        let size: String
        let note: String
    }

    /// 摘要任务只需要短文本，优先列小模型；体积为 Ollama 上的量化版本。
    static let recommended: [Recommendation] = [
        Recommendation(id: "qwen2.5:3b", size: "1.9GB",
                       note: L10n.isChinese ? "中文摘要稳定，推荐" : "Stable Chinese summaries; recommended"),
        Recommendation(id: "qwen2.5:1.5b", size: "1.0GB",
                       note: L10n.isChinese ? "更快、体积更小" : "Faster and smaller"),
        Recommendation(id: "qwen3:1.7b", size: "1.4GB",
                       note: L10n.isChinese ? "新架构，指令跟随更好" : "Newer architecture; better instruction following"),
        Recommendation(id: "llama3.2:3b", size: "2.0GB",
                       note: L10n.isChinese ? "英文强，中文一般" : "Strong English, average Chinese"),
        Recommendation(id: "gemma3:1b", size: "0.8GB",
                       note: L10n.isChinese ? "最轻量，质量有限" : "Lightest; limited quality"),
    ]

    private var pullProcess: Process?
    private var pullPipe: Pipe?
    private var pullTimeoutTask: Task<Void, Never>?

    var executablePath: String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/usr/bin/ollama"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isInstalled: Bool {
        executablePath != nil || FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
    }

    func refresh() async {
        guard isInstalled else { status = .missing; return }
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            status = .noModel
            return
        }
        if let name = models.first?["name"] as? String, !name.isEmpty {
            installedModels = models.compactMap { $0["name"] as? String }
            status = .ready(name)
        } else {
            installedModels = []
            status = .noModel
        }
    }

    func pull(model: String = OllamaManager.suggestedModel) {
        guard status != .pulling, isInstalled, let path = executablePath else { return }
        status = .pulling
        progress = L10n.isChinese ? "准备下载…" : "Preparing download…"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["pull", model]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let line = text
                .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
                .last
                .map(String.init) ?? ""
            Task { @MainActor in
                guard let self, !line.isEmpty else { return }
                self.progress = line
            }
        }

        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                if self.pullProcess === process {
                    self.pullProcess = nil
                    self.pullPipe = nil
                    self.pullTimeoutTask?.cancel()
                    self.pullTimeoutTask = nil
                }
                self.progress = ""
                await self.refresh()
            }
        }

        do {
            try process.run()
            pullProcess = process
            pullPipe = pipe
            // 防止网络卡住时永远停留在“下载中”；超时后终止子进程并由 terminationHandler 收尾。
            pullTimeoutTask = Task { @MainActor [weak self, weak process] in
                try? await Task.sleep(for: .seconds(900))
                guard !Task.isCancelled, let self, self.pullProcess === process else { return }
                process?.terminate()
            }
        } catch {
            progress = ""
            status = .noModel
            pullProcess = nil
            pullPipe = nil
        }
    }

    /// 用户取消下载。
    func cancelPull() {
        guard let process = pullProcess else { return }
        pullTimeoutTask?.cancel()
        pullTimeoutTask = nil
        process.terminate()
    }

    func openDownloadPage() {
        if let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
        }
    }
}
