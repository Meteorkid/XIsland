import Foundation
import DIShared

@main
struct DIBridge {
    static let maxMessageBytes = 16 * 1024 * 1024

    static func main() {
        let args = parseArgs()
        let agentType = args["agent"] ?? "unknown"
        let hookType = args["hook"] ?? "notification"

        let explicitTool = args["tool"]
        let stdinData = readStdin()

        let sessionId: String
        if let explicit = args["session"] {
            sessionId = explicit
        } else if let envId = ProcessInfo.processInfo.environment["DI_SESSION_ID"] {
            sessionId = envId
        } else if let nativeId = stdinData?["conversation_id"] as? String ?? stdinData?["session_id"] as? String,
                  !nativeId.isEmpty {
            sessionId = "\(agentType)-\(nativeId)"
        } else {
            sessionId = stableSessionId(agent: agentType)
        }

        dumpStdin(hook: hookType, data: stdinData)
        var message = buildMessage(
            agentType: agentType,
            hookType: hookType,
            sessionId: sessionId,
            stdinData: stdinData,
            explicitTool: explicitTool
        )
        message.agentType = agentType

        /// Hooks spawn `di-bridge` as a one-shot child; we must exit so the parent script continues
        /// and can read stdout / exit status (e.g. allow=0, deny≠0 for permission tools).
        let isInteractive = message.type == .permissionRequest
            || message.type == .question
            || message.type == .planReview

        guard let encoded = try? DIProtocol.encode(message) else {
            fputs("[di-bridge] Failed to encode message\n", stderr)
            exit(1)
        }

        let fd = connectSocket()
        guard fd >= 0 else {
            if needsJsonOutput(hookType) {
                print("{}")
            }
            exit(0)
        }

        guard sendAll(fd: fd, data: encoded) else {
            close(fd)
            if needsJsonOutput(hookType) {
                print("{}")
            }
            exit(1)
        }
        shutdown(fd, SHUT_WR)

        if isInteractive {
            dumpStdin(hook: "AWAIT_RESPONSE", data: ["type": message.type.rawValue, "fd": "\(fd)"])
            let response = receiveResponse(fd)
            dumpStdin(hook: "RECV_DONE", data: ["got": response != nil ? response!.type.rawValue : "nil"])
            close(fd)

            if let response {
                switch response.type {
                case .permissionResponse:
                    let approved = response.approved ?? false
                    // Claude Code reads the PermissionRequest outcome from stdout JSON (hookSpecificOutput),
                    // not from exit status alone. See hooks.md § PermissionRequest decision control.
                    if agentType == "claude_code" {
                        print(Self.buildClaudeCodePermissionResponse(approved: approved))
                    }
                    dumpStdin(hook: "PERM_EXIT", data: ["approved": "\(approved)"])
                    exit(approved ? 0 : 1)

                case .questionResponse:
                    let answer = response.answer ?? ""
                    if agentType == "cursor" {
                        let jsonObj: [String: Any] = [
                            "permission": "deny",
                            "agent_message": "The user already answered this question via X Island. User selected: \(answer). Do NOT ask the same question again. Continue with the conversation using this answer."
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: jsonObj),
                           let str = String(data: data, encoding: .utf8) {
                            print(str)
                        }
                    } else if isClaudeCodeQuestion(hookType: hookType, stdinData: stdinData) {
                        let json = buildClaudeCodeQuestionResponse(
                            answer: answer,
                            stdinData: stdinData,
                            hookType: hookType
                        )
                        print(json)
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
                fputs("[di-bridge] No response received\n", stderr)
                exit(1)
            }
        } else {
            close(fd)
            if needsJsonOutput(hookType) {
                print("{}")
            }
            exit(0)
        }
    }

    // MARK: - Socket Communication

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
            return "\(home)/\(path.dropFirst(2))"
        }
        return path.replacingOccurrences(of: "$HOME", with: home)
    }

    static func connectSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath()
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { src in
                UnsafeMutableRawPointer(sunPath)
                    .copyMemory(from: src.baseAddress!, byteCount: min(src.count, 104))
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }

        if result != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    @discardableResult
    static func sendAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return true }
            var sent = 0
            while sent < ptr.count {
                let n = send(fd, base.advanced(by: sent), ptr.count - sent, 0)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    static func receiveResponse(_ fd: Int32) -> DIMessage? {
        guard let data = readFramedMessage(fd) else { return nil }
        return try? DIProtocol.decode(data)
    }

    static func readFramedMessage(_ fd: Int32) -> Data? {
        var data = Data()
        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        let timeout = timeval(tv_sec: 300, tv_usec: 0)
        var tv = timeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        while true {
            let n = recv(fd, buf, bufSize, 0)
            if n > 0 {
                data.append(buf, count: n)
                if data.count > maxMessageBytes { return nil }
                if let newline = data.firstIndex(of: 0x0A) {
                    return Data(data.prefix(through: newline))
                }
            } else {
                break
            }
        }

        return data.isEmpty ? nil : data
    }

    static func needsJsonOutput(_ hookType: String) -> Bool {
        let h = hookType.lowercased()
        return h == "stop" || h == "sessionstart" || h == "session_start" || h == "userpromptsubmit"
    }

    // MARK: - Session ID

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
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return "\(agent)-\(String(hash, radix: 16))"
    }

    // MARK: - Argument Parsing

    static func parseArgs() -> [String: String] {
        var result: [String: String] = [:]
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--"), i + 1 < args.count {
                let key = String(arg.dropFirst(2))
                result[key] = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    // MARK: - Stdin

    static func readStdin() -> [String: Any]? {
        if isatty(STDIN_FILENO) != 0 { return nil }
        var input = ""
        while let line = readLine(strippingNewline: false) {
            input += line
        }
        guard !input.isEmpty,
              let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - Token Extraction

    static func extractTokens(_ data: [String: Any]?, into msg: inout DIMessage) {
        guard let data else { return }

        // Try multiple key conventions used by different agents
        msg.tokensIn = data["tokens_in"] as? Int
            ?? data["input_tokens"] as? Int
            ?? (data["usage"] as? [String: Any])?["input_tokens"] as? Int
        msg.tokensOut = data["tokens_out"] as? Int
            ?? data["output_tokens"] as? Int
            ?? (data["usage"] as? [String: Any])?["output_tokens"] as? Int
        msg.totalTokens = data["total_tokens"] as? Int
            ?? (data["usage"] as? [String: Any])?["total_tokens"] as? Int

        if let cost = data["cost_usd"] as? Double {
            msg.costUSD = cost
        } else if let cost = data["cost"] as? Double {
            msg.costUSD = cost
        }

        msg.model = data["model"] as? String
    }

    // MARK: - Message Building

    static func buildMessage(agentType: String, hookType: String, sessionId: String, stdinData: [String: Any]?, explicitTool: String? = nil) -> DIMessage {
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
        // 空字符串也要走 fallback，否则 ?? 链被截断，TERM_PROGRAM 不会被使用
        let termFromData = data?["terminal"] as? String
        msg.terminal = (termFromData?.isEmpty == false ? termFromData : nil)
            ?? ProcessInfo.processInfo.environment["TERM_PROGRAM"]
            ?? "Terminal"
        let tsid = currentTermSessionId
        if !tsid.isEmpty { msg.termSessionId = tsid }
        let cwdFromData = data?["working_dir"] as? String
            ?? data?["cwd"] as? String
            ?? data?["projectPath"] as? String
            ?? data?["workspace"] as? String
            ?? data?["workspaceFolder"] as? String
            ?? (data?["workspace_roots"] as? [String])?.first
        // 不 fallback 到 FileManager.default.currentDirectoryPath——那是 DIBridge 自身的 cwd，不是用户项目
        msg.workingDir = (cwdFromData?.isEmpty == false ? cwdFromData : nil)
            ?? ProcessInfo.processInfo.environment["PROJECT_DIR"]
        msg.prompt = extractUserPrompt(data)
        extractTokens(data, into: &msg)
        return msg
    }

    static func extractUserPrompt(_ data: [String: Any]?) -> String {
        guard let raw = data?["prompt"] as? String, !raw.isEmpty else { return "" }
        // Codex UserPromptSubmit may include system instructions before the user message.
        // If it looks like a system prompt, extract just the last user turn or truncate.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("You are a") || trimmed.hasPrefix("You will be") || trimmed.hasPrefix("System:") {
            // Try to find the actual user message after system instructions
            for separator in ["\n\nUser:", "\nUser:", "\n\n> ", "\n---\n"] {
                if let range = trimmed.range(of: separator, options: .backwards) {
                    let userPart = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !userPart.isEmpty { return String(userPart) }
                }
            }
            // Last resort: take the last line if it's short enough to be a user message
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
        // Codex sends tool_input as {"command": "..."}, others send it as a string
        if let input = data?["tool_input"] as? String {
            msg.toolInput = input
        } else if let inputObj = data?["tool_input"] as? [String: Any] {
            msg.toolInput = inputObj["command"] as? String ?? inputObj.values.first as? String
        } else {
            msg.toolInput = data?["input"] as? String
        }
        return msg
    }

    static func buildToolComplete(sessionId: String, data: [String: Any]?, explicitTool: String? = nil) -> DIMessage {
        var msg = DIMessage(type: .toolComplete, sessionId: sessionId)
        msg.tool = explicitTool ?? data?["tool_name"] as? String ?? data?["tool"] as? String ?? "unknown"
        // Codex uses "tool_response", Claude Code uses "tool_result"
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
            if let val = input[key] as? String, !val.isEmpty {
                return val
            }
        }
        if input.count <= 3 {
            let parts = input.compactMap { k, v -> String? in
                guard let s = v as? String, !s.isEmpty else { return nil }
                return "\(k): \(s)"
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
        let questionObj = (inputDict?["questions"] as? [[String: Any]])?.first
        let sources: [[String: Any]?] = [questionObj, inputDict, data]

        var header = ""
        if let h = questionObj?["header"] as? String, !h.isEmpty { header = h + ": " }
        let qText = findString(in: sources, keys: ["question", "text", "message", "description", "prompt"])
        msg.questionText = qText.map { header + $0 } ?? toolName

        for src in sources {
            guard let src else { continue }
            if let opts = src["options"] as? [String] {
                msg.options = opts; break
            }
            if let opts = src["options"] as? [[String: Any]] {
                msg.options = extractLabels(from: opts); break
            }
            if let opts = src["choices"] as? [String] {
                msg.options = opts; break
            }
            if let opts = src["choices"] as? [[String: Any]] {
                msg.options = extractLabels(from: opts); break
            }
        }

        if let defaultAnswer = findString(in: sources, keys: ["default_answer", "default"]),
           msg.options == nil || msg.options!.isEmpty {
            msg.options = [defaultAnswer]
        }

        return msg
    }

    private static func findString(in sources: [[String: Any]?], keys: [String]) -> String? {
        for src in sources {
            guard let src else { continue }
            for key in keys {
                if let val = src[key] as? String, !val.isEmpty { return val }
            }
        }
        return nil
    }

    private static func extractLabels(from dicts: [[String: Any]]) -> [String] {
        dicts.compactMap { $0["label"] as? String ?? $0["value"] as? String ?? $0["text"] as? String ?? $0["description"] as? String }
    }

    static func extractToolInput(_ data: [String: Any]?) -> [String: Any]? {
        for key in ["tool_input", "input", "parameters", "params", "args"] {
            if let input = data?[key] as? [String: Any] {
                return input
            }
            if let inputStr = data?[key] as? String,
               let inputData = inputStr.data(using: .utf8),
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

    static func isClaudeCodeQuestion(hookType: String, stdinData: [String: Any]?) -> Bool {
        let hook = hookType.lowercased()
        guard hook.contains("pretooluse") || hook.contains("tool_use")
                || hook == "tooluse" || hook.contains("permission") else { return false }
        let toolName = stdinData?["tool_name"] as? String ?? stdinData?["tool"] as? String ?? ""
        return isQuestionTool(toolName)
    }

    /// Stdout JSON for `PermissionRequest` hooks (Claude Code). Exit code alone is not sufficient.
    static func buildClaudeCodePermissionResponse(approved: Bool) -> String {
        let jsonObj: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": approved ? "allow" : "deny"
                ] as [String: Any]
            ] as [String: Any]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObj),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
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

        let jsonObj: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": hookEventName,
                "permissionDecision": "allow",
                "updatedInput": updatedInput
            ] as [String: Any]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObj),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    static func dumpStdin(hook: String, data: [String: Any]?) {
        guard shouldWriteDebugLog() else { return }
        let logPath = DISocketConfig.socketDir + "/bridge-stdin.log"
        try? FileManager.default.createDirectory(
            atPath: DISocketConfig.socketDir,
            withIntermediateDirectories: true
        )
        let line = logLine(hook: hook, data: data)
        if let handle = FileHandle(forWritingAtPath: logPath),
           let data = line.data(using: .utf8) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

    static func shouldWriteDebugLog(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment["DI_BRIDGE_DEBUG_LOG"]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static func logLine(hook: String, data: [String: Any]?) -> String {
        var line = "[\(ISO8601DateFormatter().string(from: Date()))] hook=\(hook)"
        if let data {
            let redacted = redactedForLog(data) as? [String: Any] ?? [:]
            if let json = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted]),
               let str = String(data: json, encoding: .utf8) {
                line += "\n\(str)"
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
        if let dict = value as? [String: Any] {
            return dict.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = isSensitiveLogKey(pair.key) ? "[redacted]" : redactedForLog(pair.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(redactedForLog)
        }
        if let string = value as? String, string.count > 500 {
            return "\(string.prefix(500))...[truncated \(string.count - 500) chars]"
        }
        return value
    }

    private static func isSensitiveLogKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("token")
            || lower.contains("secret")
            || lower.contains("password")
            || lower.contains("api_key")
            || lower.contains("apikey")
            || lower.contains("authorization")
            || lower.contains("cookie")
            || lower.contains("private_key")
    }
}
