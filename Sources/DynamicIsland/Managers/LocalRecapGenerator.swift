import Foundation

/// 从会话事件生成可读摘要：做了什么、进行到哪、结果如何。
///
/// 只有部分客户端（Devin、CodeBuddy）会上报 `recapText`；
/// 其余客户端（Trae、Claude Code、Cursor 等）没有原生摘要，这里按工具事件兜底。
enum LocalRecapGenerator {
    struct Recap {
        var headline: String
        var bullets: [String]
        var progress: String
    }

    /// 按「事件数 + 状态」缓存，避免卡片每次重绘都重新拼接字符串。
    private static var cache: [String: (signature: String, recap: Recap)] = [:]

    static func make(for session: AgentSession) -> Recap? {
        let signature = "\(session.events.count)|\(session.status.rawValue)"
        if let hit = cache[session.id], hit.signature == signature { return hit.recap }

        guard let recap = build(for: session) else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[session.id] = (signature, recap)
        return recap
    }

    private static func build(for session: AgentSession) -> Recap? {
        let events = session.events
        guard !events.isEmpty else {
            guard let tool = session.currentTool, !tool.isEmpty else { return nil }
            return Recap(headline: "正在执行 \(tool)", bullets: [], progress: session.formattedDuration)
        }

        let actions = dedupe(events.compactMap { describe($0) })

        let headline: String
        switch session.status {
        case .completed, .completionUnconfirmed:
            headline = actions.last.map { "已完成：\($0)" } ?? "任务已完成"
        default:
            headline = actions.last.map { "正在：\($0)" } ?? "准备中"
        }

        return Recap(headline: headline,
                     bullets: Array(actions.suffix(3)),
                     progress: "\(events.count) 步 · \(session.formattedDuration)")
    }

    /// 把工具名与输入压成一句人话，避免把原始参数塞进摘要。
    private static func describe(_ event: ToolEvent) -> String? {
        let target = event.input?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first
            .map { String($0.prefix(40)) }
        let tool = event.tool.lowercased()

        if tool.contains("read") || tool.contains("open") {
            return target.map { "查看 \($0)" } ?? "查看文件"
        }
        if tool.contains("grep") || tool.contains("search") {
            return target.map { "搜索 \($0)" } ?? "搜索代码"
        }
        if tool.contains("glob") || tool.contains("list") {
            return target.map { "浏览 \($0)" } ?? "浏览目录"
        }
        if tool.contains("edit") || tool.contains("write") || tool.contains("patch") || tool.contains("apply") {
            let delta = [event.linesAdded.map { "+\($0)" }, event.linesRemoved.map { "-\($0)" }]
                .compactMap { $0 }
                .joined(separator: " ")
            let suffix = delta.isEmpty ? "" : " \(delta)"
            return target.map { "修改 \($0)\(suffix)" } ?? "修改文件"
        }
        if tool.contains("bash") || tool.contains("run") || tool.contains("shell") || tool.contains("command") {
            return target.map { "运行 \($0)" } ?? "运行命令"
        }
        if tool.contains("web") || tool.contains("fetch") || tool.contains("http") {
            return "查询资料"
        }
        guard !event.tool.isEmpty else { return nil }
        return target.map { "\(event.tool) \($0)" } ?? event.tool
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
