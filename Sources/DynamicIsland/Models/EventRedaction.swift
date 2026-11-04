import Foundation

/// 出本机前的文本脱敏。
///
/// 适用范围：系统通知正文、推送渠道、Webhook、诊断导出。
/// 原则：宁可多遮，不要漏遮；脱敏后的文本仍要能判断「这是什么事件」。
/// 所有规则都是纯函数，测试可以逐条锁定，不依赖真实用户目录。
enum EventRedaction {
    static let placeholder = "[REDACTED]"

    /// 推送/通知正文的最大字符数。超过后截断，避免把长命令整段送出去。
    static let maxLength = 240

    static func redact(_ input: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var text = input
        // 顺序固定：先处理 Bearer（否则 key-value 规则会先吃掉 "Bearer" 一词，
        // 导致真正的 token 失去可匹配的前缀而漏遮），再逐层处理其他形式。
        text = maskBearerTokens(text)
        text = maskKeyValuePairs(text)
        text = maskProviderKeys(text)
        text = maskLongOpaqueStrings(text)
        text = maskEmails(text)
        text = maskURLCredentials(text)
        text = maskHomeDirectory(text, home: homeDirectory)
        text = collapseWhitespace(text)
        return truncate(text)
    }

    /// 单独处理路径：替换家目录后，超过 4 段的路径只保留末两级。
    /// 目的：诊断包需要能定位「哪个项目」，但不需要完整目录结构。
    static func redact(path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var text = path
        if !homeDirectory.isEmpty, text.hasPrefix(homeDirectory) {
            text = "~" + text.dropFirst(homeDirectory.count)
        }
        let components = text.split(separator: "/", omittingEmptySubsequences: true)
        if components.count > 4 {
            let tail = components.suffix(2).joined(separator: "/")
            text = (text.hasPrefix("~") ? "~/" : "…/") + tail
        }
        return truncate(collapseWhitespace(text))
    }

    // MARK: - 规则

    /// `api_key=xxx` / `"token": "xxx"` / `Authorization: Bearer xxx`
    private static func maskKeyValuePairs(_ text: String) -> String {
        let pattern = #"(?i)(api[_-]?key|access[_-]?token|token|secret|password|passwd|authorization|credential)(\"?\s*[:=]\s*\"?)([^\s,;"'}]+)"#
        return replacing(text, pattern: pattern, template: "$1$2" + placeholder)
    }

    private static func maskBearerTokens(_ text: String) -> String {
        let pattern = #"(?i)\bBearer\s+[A-Za-z0-9._\-]{8,}"#
        return replacing(text, pattern: pattern, template: "Bearer " + placeholder)
    }

    /// 常见厂商密钥前缀。
    private static func maskProviderKeys(_ text: String) -> String {
        let pattern = #"\b(sk-[A-Za-z0-9_\-]{12,}|gh[pousr]_[A-Za-z0-9]{12,}|xox[baprs]-[A-Za-z0-9\-]{12,}|AKIA[A-Z0-9]{12,}|AIza[A-Za-z0-9_\-]{20,})\b"#
        return replacing(text, pattern: pattern, template: placeholder)
    }

    /// 长十六进制 / base64 串，几乎只可能是凭据或哈希。
    private static func maskLongOpaqueStrings(_ text: String) -> String {
        let pattern = #"\b[A-Za-z0-9+/=_\-]{40,}\b"#
        return replacing(text, pattern: pattern, template: placeholder)
    }

    private static func maskEmails(_ text: String) -> String {
        let pattern = #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#
        return replacing(text, pattern: pattern, template: "[EMAIL]")
    }

    /// URL 的 userinfo 与查询串里的敏感参数。
    private static func maskURLCredentials(_ text: String) -> String {
        var result = text
        let userinfo = #"(https?://)[^/\s:@]+:[^/\s@]+@"#
        result = replacing(result, pattern: userinfo, template: "$1" + placeholder + "@")
        let query = #"(?i)([?&](?:token|key|secret|password|sig|signature|access_token)=)[^&\s]+"#
        result = replacing(result, pattern: query, template: "$1" + placeholder)
        return result
    }

    private static func maskHomeDirectory(_ text: String, home: String) -> String {
        guard !home.isEmpty else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    private static func collapseWhitespace(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }

    private static func replacing(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
