import Foundation
import DIShared

/// `di-bridge` 命令行工具：被各 AI 工具的 hook 以一次性子进程方式拉起。
///
/// 职责：
/// 1. 从命令行参数与 stdin 读取 hook 事件；
/// 2. 组装成 `DIMessage` 并编码为带帧边界的 JSON；
/// 3. 通过 Unix domain socket 发送给常驻的 `DynamicIsland`；
/// 4. 对权限 / 问答 / 计划评审这类需要用户裁决的事件，等待服务端写回结果，
///    再按对应工具期望的 stdout 约定打印，并以退出码表达通过 / 拒绝。
@main
struct DIBridge {
    /// 单条消息（含帧边界）的最大字节数，用于防御异常输入撑爆内存。
    static let maxMessageBytes = 16 * 1024 * 1024

    // MARK: - 入口

    static func main() {
        let args = parseArgs()
        let agentType = args["agent"] ?? "unknown"
        let hookType = args["hook"] ?? "notification"
        let explicitTool = args["tool"]
        let stdinData = readStdin()

        let sessionId = resolveSessionId(
            agentType: agentType,
            explicitSession: args["session"],
            stdinData: stdinData
        )

        dumpStdin(hook: hookType, data: stdinData)

        var message = buildMessage(
            agentType: agentType,
            hookType: hookType,
            sessionId: sessionId,
            stdinData: stdinData,
            explicitTool: explicitTool
        )
        message.agentType = agentType

        // hook 以一次性子进程方式拉起 `di-bridge`，必须及时退出，好让父脚本
        // 继续读取 stdout 与退出码（例如权限类 hook 用 0 表示允许、非 0 表示拒绝）。
        let isInteractive = message.type == .permissionRequest
            || message.type == .question
            || message.type == .planReview

        guard let encoded = try? DIProtocol.encode(message) else {
            fputs("[di-bridge] Failed to encode message\n", stderr)
            exit(1)
        }

        let fd = connectSocket()
        guard fd >= 0 else {
            printJsonPlaceholderIfNeeded(hookType)
            exit(0)
        }

        guard sendAll(fd: fd, data: encoded) else {
            close(fd)
            printJsonPlaceholderIfNeeded(hookType)
            exit(1)
        }
        shutdown(fd, SHUT_WR)

        if isInteractive {
            dumpStdin(hook: "AWAIT_RESPONSE", data: ["type": message.type.rawValue, "fd": "\(fd)"])
            let response = receiveResponse(fd)
            dumpStdin(hook: "RECV_DONE", data: ["got": response.map { $0.type.rawValue } ?? "nil"])
            close(fd)

            guard let response else {
                fputs("[di-bridge] No response received\n", stderr)
                exit(1)
            }

            switch response.type {
            case .permissionResponse:
                let approved = response.approved ?? false
                // Claude Code 通过 stdout 的 JSON（hookSpecificOutput）读取权限结果，
                // 仅靠退出码不够，见 hooks.md 关于 PermissionRequest 决策控制的说明。
                if usesClaudeCodePermissionStdout(agentType: agentType) {
                    print(Self.buildClaudeCodePermissionResponse(approved: approved))
                }
                dumpStdin(hook: "PERM_EXIT", data: ["approved": "\(approved)"])
                exit(approved ? 0 : 1)

            case .questionResponse:
                let answer = response.answer ?? ""
                if agentType == "cursor" {
                    let payload: [String: Any] = [
                        "permission": "deny",
                        "agent_message": "The user already answered this question via X Island. User selected: \(answer). Do NOT ask the same question again. Continue with the conversation using this answer."
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else if isClaudeCodeQuestion(hookType: hookType, stdinData: stdinData) {
                    print(buildClaudeCodeQuestionResponse(
                        answer: answer,
                        stdinData: stdinData,
                        hookType: hookType
                    ))
                } else {
                    print(answer)
                }
                exit(0)

            case .planResponse:
                let approved = response.planApproved ?? false
                if let feedback = response.feedback {
                    print(feedback)
                }
                exit(approved ? 0 : 1)

            default:
                exit(0)
            }
        } else {
            close(fd)
            printJsonPlaceholderIfNeeded(hookType)
            exit(0)
        }
    }

    /// 解析会话标识：命令行参数 > 环境变量 > stdin 里的原生会话 ID > 稳定哈希。
    private static func resolveSessionId(
        agentType: String,
        explicitSession: String?,
        stdinData: [String: Any]?
    ) -> String {
        if let explicit = explicitSession {
            return explicit
        }
        if let envId = ProcessInfo.processInfo.environment["DI_SESSION_ID"] {
            return envId
        }
        if let nativeId = stdinData?["conversation_id"] as? String ?? stdinData?["session_id"] as? String,
           !nativeId.isEmpty {
            return "\(agentType)-\(nativeId)"
        }
        return stableSessionId(agent: agentType)
    }

    /// 某些 hook（如 stop / sessionstart / userpromptsubmit）期望一个 JSON 输出，
    /// 即便桥接未连接上服务端也要回一个 `{}`，避免父脚本解析失败。
    private static func printJsonPlaceholderIfNeeded(_ hookType: String) {
        if needsJsonOutput(hookType) {
            print("{}")
        }
    }

    // MARK: - Socket 通信

    static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["DI_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return expandHome(in: override)
        }
        return DISocketConfig.socketPath
    }

    private static func expandHome(in path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home + "/" + path.dropFirst(2)
        }
        return path.replacingOccurrences(of: "$HOME", with: home)
    }

    static func connectSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath().utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { source in
                UnsafeMutableRawPointer(sunPath)
                    .copyMemory(from: source.baseAddress!, byteCount: min(source.count, 104))
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                connect(fd, sockPointer, length)
            }
        }

        guard connected == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    @discardableResult
    static func sendAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let written = send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    static func receiveResponse(_ fd: Int32) -> DIMessage? {
        guard let data = readFramedMessage(fd) else { return nil }
        return try? DIProtocol.decode(data)
    }

    static func readFramedMessage(_ fd: Int32) -> Data? {
        let chunkSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var timeout = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var accumulated = Data()
        while true {
            let received = recv(fd, buffer, chunkSize, 0)
            guard received > 0 else { break }
            accumulated.append(buffer, count: received)
            if accumulated.count > maxMessageBytes { return nil }
            if let newline = accumulated.firstIndex(of: 0x0A) {
                return Data(accumulated.prefix(through: newline))
            }
        }

        return accumulated.isEmpty ? nil : accumulated
    }

    static func needsJsonOutput(_ hookType: String) -> Bool {
        let hook = hookType.lowercased()
        return hook == "stop" || hook == "sessionstart" || hook == "session_start" || hook == "userpromptsubmit"
    }

    // MARK: - 会话标识

    static var currentTermSessionId: String {
        if let id = ProcessInfo.processInfo.environment["ITERM_SESSION_ID"], !id.isEmpty { return "iterm:\(id)" }
        if let id = ProcessInfo.processInfo.environment["TERM_SESSION_ID"], !id.isEmpty { return "ts:\(id)" }
        for fd: Int32 in [2, 1, 0] {
            if isatty(fd) != 0, let tty = ttyname(fd) { return "tty:\(String(cString: tty))" }
        }
        return ""
    }

    static func stableSessionId(agent: String) -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "unknown"
        let termSession = currentTermSessionId
        let seed = "\(agent)-\(cwd)-\(termProgram)-\(termSession)"

        // djb2：一个稳定、跨进程一致的哈希，用于把「无原生会话 ID」的事件归到同一会话。
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return "\(agent)-\(String(hash, radix: 16))"
    }

    // MARK: - 参数解析

    static func parseArgs() -> [String: String] {
        var parsed: [String: String] = [:]
        let tokens = CommandLine.arguments
        var cursor = 1
        while cursor < tokens.count {
            let token = tokens[cursor]
            if token.hasPrefix("--"), cursor + 1 < tokens.count {
                parsed[String(token.dropFirst(2))] = tokens[cursor + 1]
                cursor += 2
            } else {
                cursor += 1
            }
        }
        return parsed
    }

    // MARK: - 标准输入

    static func readStdin() -> [String: Any]? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }

        var text = ""
        while let line = readLine(strippingNewline: false) {
            text += line
        }

        guard !text.isEmpty,
              let payload = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return object
    }

    // MARK: - Token 提取

    static func extractTokens(_ data: [String: Any]?, into msg: inout DIMessage) {
        guard let data else { return }

        // 各 AI 工具使用不同的字段约定，逐一尝试兼容。
        let usage = data["usage"] as? [String: Any]
        msg.tokensIn = data["tokens_in"] as? Int
            ?? data["input_tokens"] as? Int
            ?? usage?["input_tokens"] as? Int
        msg.tokensOut = data["tokens_out"] as? Int
            ?? data["output_tokens"] as? Int
            ?? usage?["output_tokens"] as? Int
        msg.totalTokens = data["total_tokens"] as? Int
            ?? usage?["total_tokens"] as? Int

        if let cost = data["cost_usd"] as? Double {
            msg.costUSD = cost
        } else if let cost = data["cost"] as? Double {
            msg.costUSD = cost
        }

        msg.model = data["model"] as? String
    }

    // MARK: - 消息构建

    static func buildMessage(
        agentType: String,
        hookType: String,
        sessionId: String,
        stdinData: [String: Any]?,
        explicitTool: String? = nil
    ) -> DIMessage {
        let hook = hookType.lowercased()

        if hook.contains("pretooluse") || hook.contains("tool_use") || hook == "tooluse" {
            let toolName = explicitTool ?? stdinData?["tool_name"] as? String ?? stdinData?["tool"] as? String ?? ""
            if isQuestionTool(toolName) {
                return buildQuestionFromPermission(sessionId: sessionId, toolName: toolName, data: stdinData)
            }
            return buildToolStart(sessionId: sessionId, data: stdinData, explicitTool: explicitTool)
        }
        if hook.contains("posttooluse") || hook == "patchapply" {
            return buildToolComplete(sessionId: sessionId, data: stdinData, explicitTool: explicitTool)
        }
        if hook.contains("permission") {
            return buildPermissionRequest(sessionId: sessionId, data: stdinData)
        }
        if hook.contains("question") || hook.contains("ask") {
            return buildQuestion(sessionId: sessionId, data: stdinData)
        }
        if hook.contains("plan") {
            return buildPlanReview(sessionId: sessionId, data: stdinData)
        }
        if hook == "subagentstart" || hook == "subagent_start" {
            return buildSubagentStart(sessionId: sessionId, agentType: agentType, data: stdinData)
        }
        if hook == "subagentstop" || hook == "subagentend" || hook == "subagent_stop" || hook == "subagent_end" {
            return buildSubagentEnd(sessionId: sessionId, agentType: agentType, data: stdinData)
        }
        if hook == "precompact" || hook.contains("compact") {
            return buildContextCompact(sessionId: sessionId, data: stdinData)
        }
        if hook == "sessionstart" || hook.contains("session_start") || hook == "userpromptsubmit" {
            return buildSessionStart(sessionId: sessionId, agentType: agentType, data: stdinData)
        }
        if hook == "sessionend" || hook.contains("session_end") || hook == "stop" {
            var msg = DIMessage(type: .sessionEnd, sessionId: sessionId)
            msg.agentType = agentType
            msg.status = stdinData?["last_assistant_message"] as? String
                ?? stdinData?["message"] as? String
                ?? stdinData?["response"] as? String
                ?? stdinData?["result"] as? String
            extractTokens(stdinData, into: &msg)
            return msg
        }

        var msg = buildNotification(sessionId: sessionId, data: stdinData)
        msg.agentType = agentType
        return msg
    }

    static func buildSessionStart(sessionId: String, agentType: String, data: [String: Any]?) -> DIMessage {
        var msg = DIMessage(type: .sessionStart, sessionId: sessionId)
        msg.agentType = agentType

        // 空字符串视同缺失：否则 ?? 链会被空串截断，TERM_PROGRAM 永远用不上。
        let terminalFromData = data?["terminal"] as? String
        msg.terminal = (terminalFromData?.isEmpty == false ? terminalFromData : nil)
            ?? ProcessInfo.processInfo.environment["TERM_PROGRAM"]
            ?? "Terminal"

        let termSession = currentTermSessionId
        if !termSession.isEmpty { msg.termSessionId = termSession }

        let cwdFromData = data?["working_dir"] as? String
            ?? data?["cwd"] as? String
            ?? data?["projectPath"] as? String
            ?? data?["workspace"] as? String
            ?? data?["workspaceFolder"] as? String
            ?? (data?["workspace_roots"] as? [String])?.first
        // 不回退到 FileManager.default.currentDirectoryPath——那是 di-bridge 自身的
        // 工作目录，而非用户项目根目录。
        msg.workingDir = (cwdFromData?.isEmpty == false ? cwdFromData : nil)
            ?? ProcessInfo.processInfo.environment["PROJECT_DIR"]

        msg.prompt = extractUserPrompt(data)
        extractTokens(data, into: &msg)
        return msg
    }

    static func extractUserPrompt(_ data: [String: Any]?) -> String {
        guard let raw = data?["prompt"] as? String, !raw.isEmpty else { return "" }

        // Codex 的 UserPromptSubmit 可能在用户消息前塞入系统指令。
        // 若形如系统提示，则只摘出最后一轮用户消息，必要时截断。
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("You are a") || trimmed.hasPrefix("You will be") || trimmed.hasPrefix("System:") {
            for separator in ["\n\nUser:", "\nUser:", "\n\n> ", "\n---\n"] {
                if let range = trimmed.range(of: separator, options: .backwards) {
                    let userPart = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !userPart.isEmpty { return String(userPart) }
                }
            }
            // 兜底：若最后一行足够短，则把它当作用户消息。
            if let lastLine = trimmed.split(separator: "\n").last, lastLine.count < 500 {
                return String(lastLine)
            }
            return ""
        }
        return raw
    }

    static func buildToolStart(sessionId: String, data: [String: Any]?, explicitTool: String? = nil) -> DIMessage {
        var msg = DIMessage(type: .toolStart, sessionId: sessionId)
        msg.tool = explicitTool ?? data?["tool_name"] as? String ?? data?["tool"] as? String ?? "unknown"

        // Codex 的 tool_input 形如 {"command": "..."}，其他工具则直接给字符串。
        if let input = data?["tool_input"] as? String {
            msg.toolInput = input
        } else if let inputObject = data?["tool_input"] as? [String: Any] {
            msg.toolInput = inputObject["command"] as? String ?? inputObject.values.first as? String
        } else {
            msg.toolInput = data?["input"] as? String
        }
        return msg
    }

    static func buildToolComplete(sessionId: String, data: [String: Any]?, explicitTool: String? = nil) -> DIMessage {
        var msg = DIMessage(type: .toolComplete, sessionId: sessionId)
        msg.tool = explicitTool ?? data?["tool_name"] as? String ?? data?["tool"] as? String ?? "unknown"

        // Codex 用 "tool_response"，Claude Code 用 "tool_result"。
        msg.toolResult = data?["tool_result"] as? String
            ?? data?["tool_response"] as? String
            ?? data?["result"] as? String
        msg.linesAdded = data?["lines_added"] as? Int
        msg.linesRemoved = data?["lines_removed"] as? Int
        extractTokens(data, into: &msg)
        return msg
    }

    static func buildPermissionRequest(sessionId: String, data: [String: Any]?) -> DIMessage {
        let toolName = data?["tool_name"] as? String ?? data?["tool"] as? String ?? "unknown"

        if isQuestionTool(toolName) {
            return buildQuestionFromPermission(sessionId: sessionId, toolName: toolName, data: data)
        }

        var msg = DIMessage(type: .permissionRequest, sessionId: sessionId)
        msg.tool = toolName

        let inputDict = extractToolInput(data)
        let sources: [[String: Any]?] = [inputDict, data]
        var desc = findString(in: sources, keys: ["description", "command", "path", "file_path", "pattern", "query", "content", "text"]) ?? ""
        if desc.isEmpty {
            desc = descriptionFromToolInput(inputDict) ?? descriptionFromToolInput(data) ?? ""
        }
        msg.permDescription = desc
        msg.diff = data?["diff"] as? String
        msg.filePath = findString(in: sources, keys: ["file_path", "path", "filePath"])
        return msg
    }

    static func descriptionFromToolInput(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }

        let interestingKeys = ["command", "query", "content", "code", "url", "pattern", "text"]
        for key in interestingKeys {
            if let value = input[key] as? String, !value.isEmpty {
                return value
            }
        }

        if input.count <= 3 {
            let parts = input.compactMap { key, value -> String? in
                guard let text = value as? String, !text.isEmpty else { return nil }
                return "\(key): \(text)"
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        return nil
    }

    static func isQuestionTool(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("askuser") || lower.contains("ask_user")
            || lower.contains("askquestion") || lower.contains("ask_question")
            || lower == "question" || lower == "userinput" || lower == "user_input"
    }

    static func buildQuestionFromPermission(sessionId: String, toolName: String, data: [String: Any]?) -> DIMessage {
        var msg = DIMessage(type: .question, sessionId: sessionId)

        let inputDict = extractToolInput(data)
        let questionObject = (inputDict?["questions"] as? [[String: Any]])?.first
        let sources: [[String: Any]?] = [questionObject, inputDict, data]

        var header = ""
        if let h = questionObject?["header"] as? String, !h.isEmpty { header = h + ": " }
        let questionText = findString(in: sources, keys: ["question", "text", "message", "description", "prompt"])
        msg.questionText = questionText.map { header + $0 } ?? toolName

        for source in sources {
            guard let source else { continue }
            if let options = source["options"] as? [String] {
                msg.options = options; break
            }
            if let options = source["options"] as? [[String: Any]] {
                msg.options = extractLabels(from: options); break
            }
            if let choices = source["choices"] as? [String] {
                msg.options = choices; break
            }
            if let choices = source["choices"] as? [[String: Any]] {
                msg.options = extractLabels(from: choices); break
            }
        }

        if let defaultAnswer = findString(in: sources, keys: ["default_answer", "default"]),
           msg.options == nil || msg.options!.isEmpty {
            msg.options = [defaultAnswer]
        }

        return msg
    }

    private static func findString(in sources: [[String: Any]?], keys: [String]) -> String? {
        for source in sources {
            guard let source else { continue }
            for key in keys {
                if let value = source[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func extractLabels(from dicts: [[String: Any]]) -> [String] {
        dicts.compactMap {
            $0["label"] as? String ?? $0["value"] as? String ?? $0["text"] as? String ?? $0["description"] as? String
        }
    }

    static func extractToolInput(_ data: [String: Any]?) -> [String: Any]? {
        for key in ["tool_input", "input", "parameters", "params", "args"] {
            if let input = data?[key] as? [String: Any] {
                return input
            }
            if let inputText = data?[key] as? String,
               let inputData = inputText.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] {
                return parsed
            }
        }
        if let tool = data?["tool"] as? [String: Any], let input = tool["input"] as? [String: Any] {
            return input
        }
        return nil
    }

    static func buildQuestion(sessionId: String, data: [String: Any]?) -> DIMessage {
        var msg = DIMessage(type: .question, sessionId: sessionId)
        msg.questionText = data?["question"] as? String ?? data?["text"] as? String ?? ""
        msg.options = data?["options"] as? [String] ?? []
        return msg
    }

    static func buildPlanReview(sessionId: String, data: [String: Any]?) -> DIMessage {
        var msg = DIMessage(type: .planReview, sessionId: sessionId)
        msg.planMarkdown = data?["plan"] as? String ?? data?["markdown"] as? String ?? ""
        return msg
    }

    static func buildSubagentStart(sessionId: String, agentType: String, data: [String: Any]?) -> DIMessage {
        var msg = DIMessage(type: .subagentStart, sessionId: sessionId)
        msg.agentType = agentType
        msg.parentSessionId = data?["parent_session_id"] as? String ?? sessionId
        msg.subagentId = data?["subagent_id"] as? String ?? UUID().uuidString
        msg.prompt = data?["prompt"] as? String ?? data?["task"] as? String ?? ""
        return msg
    }

    static func buildSubagentEnd(sessionId: String, agentType: String, data: [String: Any]?) -> DIMessage {
        var msg = DIMessage(type: .subagentEnd, sessionId: sessionId)
        msg.agentType = agentType
        msg.parentSessionId = data?["parent_session_id"] as? String ?? sessionId
        msg.subagentId = data?["subagent_id"] as? String
        extractTokens(data, into: &msg)
        return msg
    }

    static func buildContextCompact(sessionId: String, data: [String: Any]?) -> DIMessage {
        var msg = DIMessage(type: .contextCompact, sessionId: sessionId)
        msg.status = data?["message"] as? String ?? "Context window compacting..."
        extractTokens(data, into: &msg)
        return msg
    }

    static func buildNotification(sessionId: String, data: [String: Any]?) -> DIMessage {
        var msg = DIMessage(type: .statusUpdate, sessionId: sessionId)
        msg.status = data?["message"] as? String
            ?? data?["status"] as? String
            ?? data?["text"] as? String
            ?? data?["last-assistant-message"] as? String
            ?? data?["last_assistant_message"] as? String
            ?? ""
        extractTokens(data, into: &msg)
        return msg
    }

    // MARK: - Claude Code 兼容

    static func isClaudeCodeQuestion(hookType: String, stdinData: [String: Any]?) -> Bool {
        let hook = hookType.lowercased()
        guard hook.contains("pretooluse") || hook.contains("tool_use")
                || hook == "tooluse" || hook.contains("permission") else { return false }
        let toolName = stdinData?["tool_name"] as? String ?? stdinData?["tool"] as? String ?? ""
        return isQuestionTool(toolName)
    }

    /// 是否为需要走 Claude Code 风格 stdout 的 `PermissionRequest` hook（退出码本身不够）。
    static func usesClaudeCodePermissionStdout(agentType: String) -> Bool {
        let agent = agentType.lowercased()
        return agent == "claude_code" || agent == "trae"
    }

    static func buildClaudeCodePermissionResponse(approved: Bool) -> String {
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": approved ? "allow" : "deny"
                ] as [String: Any]
            ] as [String: Any]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func buildClaudeCodeQuestionResponse(
        answer: String,
        stdinData: [String: Any]?,
        hookType: String = "PreToolUse"
    ) -> String {
        let toolInput = extractToolInput(stdinData) ?? [:]
        var updatedInput = toolInput

        let questions = toolInput["questions"] as? [[String: Any]] ?? []
        if !questions.isEmpty {
            var updatedQuestions = questions
            var answerMap: [String: String] = [:]
            if !updatedQuestions.isEmpty {
                let questionText = (updatedQuestions[0]["question"] as? String)
                    ?? (updatedQuestions[0]["header"] as? String)
                    ?? ""
                if !questionText.isEmpty {
                    answerMap[questionText] = answer
                }
                updatedQuestions[0]["answer"] = answer
                updatedQuestions[0]["answers"] = [answer]
            }
            updatedInput["questions"] = updatedQuestions
            if !answerMap.isEmpty {
                updatedInput["answers"] = answerMap
            }
            updatedInput["answer"] = answer
        } else {
            let questionText = toolInput["question"] as? String
                ?? stdinData?["question"] as? String ?? ""
            if !questionText.isEmpty {
                updatedInput["answers"] = [questionText: answer]
            }
            updatedInput["answer"] = answer
        }

        let lowerHook = hookType.lowercased()
        let hookEventName = lowerHook.contains("permission") ? "PermissionRequest" : "PreToolUse"

        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": hookEventName,
                "permissionDecision": "allow",
                "updatedInput": updatedInput
            ] as [String: Any]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: - 调试日志

    static func dumpStdin(hook: String, data: [String: Any]?) {
        guard shouldWriteDebugLog() else { return }
        let logPath = DISocketConfig.socketDir + "/bridge-stdin.log"
        try? FileManager.default.createDirectory(
            atPath: DISocketConfig.socketDir,
            withIntermediateDirectories: true
        )
        let line = logLine(hook: hook, data: data)
        if let handle = FileHandle(forWritingAtPath: logPath),
           let bytes = line.data(using: .utf8) {
            handle.seekToEndOfFile()
            handle.write(bytes)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

    static func shouldWriteDebugLog(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let flag = environment["DI_BRIDGE_DEBUG_LOG"]?.lowercased() else { return false }
        return flag == "1" || flag == "true" || flag == "yes"
    }

    static func logLine(hook: String, data: [String: Any]?) -> String {
        var line = "[\(ISO8601DateFormatter().string(from: Date()))] hook=\(hook)"
        if let data {
            let sanitized = redactedForLog(data) as? [String: Any] ?? [:]
            if let json = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted]),
               let text = String(data: json, encoding: .utf8) {
                line += "\n\(text)"
            } else {
                line += " keys=\(data.keys.sorted())"
            }
        } else {
            line += " stdin=(nil)"
        }
        line += "\n---\n"
        return line
    }

    static func redactedForLog(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, child) in dictionary {
                output[key] = isSensitiveLogKey(key) ? "[redacted]" : redactedForLog(child)
            }
            return output
        }
        if let array = value as? [Any] {
            return array.map(redactedForLog)
        }
        if let text = value as? String, text.count > 500 {
            return "\(text.prefix(500))...[truncated \(text.count - 500) chars]"
        }
        return value
    }

    private static func isSensitiveLogKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("password")
            || normalized.contains("api_key")
            || normalized.contains("apikey")
            || normalized.contains("authorization")
            || normalized.contains("cookie")
            || normalized.contains("private_key")
    }
}
