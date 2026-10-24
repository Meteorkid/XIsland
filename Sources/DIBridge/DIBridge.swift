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
        let command = CommandLine.arguments.dropFirst().first
        if command == "vscode-observation" {
            guard CommandLine.arguments.count == 2 else { exit(64) }
            exit(VSCodeObservationCommand.run())
        }
        if command == "kiro-config-v3" {
            exit(KiroConfigurationCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2)), bridgePath: CommandLine.arguments[0]))
        }
        if command == "workbuddy-plugin" {
            exit(WorkBuddyPluginExport.run(arguments: Array(CommandLine.arguments.dropFirst(2)), bridgePath: CommandLine.arguments[0]))
        }
        if command == "amazonq-config-1-19-7" {
            exit(AmazonQAgentConfiguration.run(arguments: Array(CommandLine.arguments.dropFirst(2)), bridgePath: CommandLine.arguments[0]))
        }
        if command == "amazonq-1-19-7" {
            exit(AmazonQLauncher.run(arguments: Array(CommandLine.arguments.dropFirst(2)), bridgePath: CommandLine.arguments[0]))
        }
        if command == "amazonq-hook-1-19-7" {
            AmazonQLauncher.hook(arguments: Array(CommandLine.arguments.dropFirst(2)))
            exit(0)
        }
        if command == "continue-state" {
            exit(ContinueStateWatcher.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
        }
        if command == "acp-config" {
            exit(ACPConfigurationCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2)), bridgePath: CommandLine.arguments[0]))
        }
        if command == "cody-agent" {
            exit(ACPRunner.run(arguments: Array(CommandLine.arguments.dropFirst(2)), bridgePath: CommandLine.arguments[0], cody: true))
        }
        if command == "acp" {
            exit(ACPRunner.run(arguments: Array(CommandLine.arguments.dropFirst(2)), bridgePath: CommandLine.arguments[0]))
        }
        if command == "aider" {
            exit(AiderLauncher.run(arguments: Array(CommandLine.arguments.dropFirst(2)), bridgePath: CommandLine.arguments[0]))
        }
        if command == "aider-notify" {
            guard CommandLine.arguments.count == 3 else { exit(64) }
            AiderLauncher.notify(statePath: CommandLine.arguments[2])
            exit(0)
        }
        let args = parseArgs()
        let agentType = args["agent"] ?? "unknown"
        let hookType = args["hook"] ?? "notification"
        let explicitTool = args["tool"]
        let stdinData = readStdin()
        let hookOutputEvent = outputEvent(hookType: hookType, stdinData: stdinData)
        if shouldSkipImportedClaudeHook(agentType: agentType, stdinData: stdinData,
                                       environment: ProcessInfo.processInfo.environment) {
            // Devin 继承 Claude hooks 时只保留其专用入口，避免重复会话和错误审批协议。
            print("{}")
            exit(0)
        }

        let sessionId = resolveSessionId(
            agentType: agentType,
            explicitSession: args["session"],
            stdinData: stdinData
        )

        dumpStdin(hook: hookType, data: stdinData)

        var message: DIMessage
        do {
            message = try makeMessage(agentType: agentType, hookType: hookType, sessionId: sessionId,
                                      stdinData: stdinData, explicitTool: explicitTool, adapter: args["adapter"])
        } catch {
            fputs("[di-bridge] Invalid native hook payload\n", stderr)
            if agentType == "devin", hookType == "PermissionRequest" { emitDevinUnavailablePermission() }
            exit(agentType == "workbuddy" ? 0 : 1)
        }
        message.agentType = agentType

        // 不同工具的决定由 JSON、退出码或两者共同表达，不能统一把 exit 0 当作批准。
        let isInteractive = message.type == .permissionRequest
            || message.type == .question
            || message.type == .planReview

        guard let encoded = try? DIProtocol.encode(message) else {
            fputs("[di-bridge] Failed to encode message\n", stderr)
            exit(1)
        }

        let fd = connectSocket()
        guard fd >= 0 else {
            if agentType == "devin", message.type == .permissionRequest { emitDevinUnavailablePermission() }
            printJsonPlaceholderIfNeeded(hookOutputEvent, agentType: agentType, adapter: args["adapter"])
            exit(0)
        }

        guard sendAll(fd: fd, data: encoded) else {
            close(fd)
            if agentType == "devin", message.type == .permissionRequest { emitDevinUnavailablePermission() }
            printJsonPlaceholderIfNeeded(hookOutputEvent, agentType: agentType, adapter: args["adapter"])
            exit(agentType == "workbuddy" ? 0 : 1)
        }
        shutdown(fd, SHUT_WR)

        if isInteractive {
            dumpStdin(hook: "AWAIT_RESPONSE", data: ["type": message.type.rawValue, "fd": "\(fd)"])
            let response = receiveResponse(fd)
            dumpStdin(hook: "RECV_DONE", data: ["got": response.map { $0.type.rawValue } ?? "nil"])
            close(fd)

            guard let response else {
                fputs("[di-bridge] No response received\n", stderr)
                if agentType == "devin", message.type == .permissionRequest { emitDevinUnavailablePermission() }
                exit(1)
            }

            switch response.type {
            case .permissionResponse:
                let approved = response.approved ?? false
                if args["adapter"] == "opencode_plugin", response.approved == nil { exit(1) }
                let output = permissionHookResponse(agentType: agentType, approved: approved, adapter: args["adapter"])
                if let stdout = output.stdout { print(stdout) }
                dumpStdin(hook: "PERM_EXIT", data: ["approved": "\(approved)"])
                exit(output.exitCode)

            case .questionResponse:
                let answer = response.answer ?? ""
                if args["adapter"] == "opencode_plugin" {
                    let output: String
                    do {
                        if let selected = response.selectedAnswers {
                            guard message.allowsMultipleAnswers == true, response.answer == nil else { exit(1) }
                            output = try OpenCodeHookAdapter.questionResponse(answers: selected)
                        } else {
                            guard message.allowsMultipleAnswers != true else { exit(1) }
                            output = try OpenCodeHookAdapter.questionResponse(answer: answer)
                        }
                    } catch { exit(1) }
                    print(output)
                } else if agentType == "cursor" {
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
            printJsonPlaceholderIfNeeded(hookOutputEvent, agentType: agentType, adapter: args["adapter"])
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
    private static func printJsonPlaceholderIfNeeded(_ hookType: String, agentType: String, adapter: String? = nil) {
        if needsJsonOutput(hookType, agentType: agentType, adapter: adapter) {
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

    static func readFramedMessage(_ fd: Int32, timeoutSeconds: TimeInterval = 290) -> Data? {
        let chunkSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        // 在宿主 300 秒 hook 超时之前返回，留出拒绝/取消响应的写回时间。
        // 使用总截止时间，避免分片持续到达使每次 recv 都重新获得完整等待时长。
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        var accumulated = Data()
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32(max(1, (remaining - floor(remaining)) * 1_000_000)))
            guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { return nil }
            let received = recv(fd, buffer, chunkSize, 0)
            if received < 0, errno == EINTR { continue }
            if received < 0 { return nil }
            guard received > 0 else { break }
            accumulated.append(buffer, count: received)
            if accumulated.count > maxMessageBytes { return nil }
            if let newline = accumulated.firstIndex(of: 0x0A) {
                return Data(accumulated.prefix(through: newline))
            }
        }

        return accumulated.isEmpty ? nil : accumulated
    }

    static func needsJsonOutput(_ hookType: String, agentType: String? = nil, adapter: String? = nil) -> Bool {
        // Kiro 会把上下文 hook 的 stdout 加入模型输入；观察器不注入占位 JSON。
        if agentType == "kiro" || agentType == "workbuddy" { return false }
        // 新版 Kimi 会把 stdout 当作上下文；纯观察入口不能注入占位 JSON。
        if agentType == "kimi", adapter == "kimi_code" { return false }
        if let agentType, ["claude_code", "codex", "qwen", "qoder", "droid", "gemini_cli", "tabnine", "devin", "copilot_cli", "trae", "kimi"].contains(agentType) {
            return true
        }
        let hook = hookType.lowercased()
        return hook == "stop" || hook == "sessionstart" || hook == "session_start" || hook == "userpromptsubmit"
    }

    /// 旧配置把 Codex Stop 映射成 notification；输出仍必须遵守原生事件的 JSON 契约。
    static func outputEvent(hookType: String, stdinData: [String: Any]?) -> String {
        guard let event = (stdinData?["hook_event_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !event.isEmpty else { return hookType }
        return event
    }

    // MARK: - 会话标识

    static var currentTermSessionId: String {
        var currentTTY: String?
        for fd: Int32 in [2, 1, 0] {
            if isatty(fd) != 0, let tty = ttyname(fd) {
                currentTTY = String(cString: tty)
                break
            }
        }
        return resolveTermSessionId(environment: ProcessInfo.processInfo.environment, tty: currentTTY)
    }

    static func resolveTermSessionId(environment: [String: String], tty: String?) -> String {
        func isPaneNumber(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) && Int(value) != nil
        }
        func isToken(_ value: String) -> Bool {
            // 为最长的 iterm: 前缀预留 6 字节，对齐导航层的 512 字节上限。
            !value.isEmpty && value.utf8.count <= 506 && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }
        }
        func isTTY(_ value: String) -> Bool {
            guard value.hasPrefix("/dev/tty"), value.utf8.count <= 128 else { return false }
            let suffix = value.dropFirst(8)
            return !suffix.isEmpty && suffix.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }
        }

        // 内层 pane 身份不能退回外层终端；即便格式错误，也不能因此聚焦错误标签页。
        if let id = environment["TMUX_PANE"], !id.isEmpty {
            guard id.hasPrefix("%"), isPaneNumber(String(id.dropFirst())) else { return "" }
            return "tmux:\(id)"
        }
        for (key, prefix) in [("WEZTERM_PANE", "wezterm"), ("KITTY_WINDOW_ID", "kitty")] {
            if let id = environment[key], !id.isEmpty {
                guard isPaneNumber(id) else { return "" }
                return "\(prefix):\(id)"
            }
        }
        if let id = environment["ITERM_SESSION_ID"], !id.isEmpty {
            guard isToken(id) else { return "" }
            return "iterm:\(id)"
        }
        for value in [environment["TTY"], tty].compactMap({ $0 }) {
            if isTTY(value) { return "tty:\(value)" }
        }
        if let id = environment["TERM_SESSION_ID"], isToken(id) {
            return "ts:\(id)"
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

    enum NativePayloadError: Error {
        case invalidField(String)
    }

    static func makeMessage(
        agentType: String, hookType: String, sessionId: String,
        stdinData: [String: Any]?, explicitTool: String? = nil, adapter: String? = nil
    ) throws -> DIMessage {
        if let adapter {
            switch (agentType, adapter) {
            case ("kimi", "kimi_code"): return try KimiCodeHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
            case ("workbuddy", "workbuddy_5_7_6"): return try WorkBuddyHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
            case ("kiro", "kiro_cli"): return try KiroHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
            case ("trae", "trae_cn"): return try TraeHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
            case ("opencode", "opencode_plugin"): return try OpenCodeHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
            case ("copilot", "vscode_local"): return try VSCodeHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
            default: throw NativePayloadError.invalidField("adapter")
            }
        }
        // 旧通用 Kiro 模板没有可证明的协议身份，禁止回退为 Claude 风格事件。
        if agentType == "kiro" { throw NativePayloadError.invalidField("adapter") }
        if agentType == "workbuddy" { throw NativePayloadError.invalidField("adapter") }
        if agentType == "amazon_q" { throw NativePayloadError.invalidField("requires scoped wrapper") }
        // GLM 是模型来源；尚未核实独立 CLI，事件必须走实际客户端协议。
        if agentType == "glm" { throw NativePayloadError.invalidField("unverified GLM client") }
        // 尚无 Cody 本地事件契约；旧 hooks.json 模板不能成为兼容性证据。
        if agentType == "cody" { throw NativePayloadError.invalidField("unverified Cody protocol") }
        if agentType == "windsurf" {
            return try WindsurfHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
        }
        if agentType == "amp" {
            return try AmpHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
        }
        if agentType == "pi" {
            return try PiHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
        }
        if agentType == "copilot_cli" {
            return try CopilotCliHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
        }
        if agentType == "cursor" {
            return try CursorHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
        }
        if agentType == "kimi" {
            return try KimiHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
        }
        if agentType == "code_buddy" {
            return try CodeBuddyHookAdapter.normalize(hookType: hookType, sessionId: sessionId, stdinData: stdinData)
        }
        if agentType == "cline" {
            return try ClineHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
        }
        if agentType == "deepseek" {
            return try DeepSeekHookAdapter.normalize(hookType: hookType, stdinData: stdinData)
        }
        let event = outputEvent(hookType: hookType, stdinData: stdinData)
        var data = stdinData
        var codexTurnID: String?
        if agentType == "codex" {
            func identity(_ field: String) throws -> String {
                guard let value = data?[field] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.utf8.count <= 4096, !value.utf8.contains(0) else {
                    throw NativePayloadError.invalidField(field)
                }
                return value
            }
            let isTurnObservation = ["Interrupt", "PreCompact", "PostCompact"].contains(event)
            if data?["turn_id"] != nil || isTurnObservation { codexTurnID = try identity("turn_id") }
            if isTurnObservation {
                _ = try identity("session_id")
                if event != "Interrupt" {
                    guard let trigger = data?["trigger"] as? String, ["manual", "auto"].contains(trigger) else {
                        throw NativePayloadError.invalidField("trigger")
                    }
                }
                var message = DIMessage(type: event == "PreCompact" ? .contextCompact : .statusUpdate, sessionId: sessionId)
                message.agentType = agentType
                message.nativeEvent = event
                message.nativeTurnId = codexTurnID
                message.workingDir = data?["cwd"] as? String
                message.statusIsAssistantReply = false
                // 压缩后的 hooks 仍可阻止后续运行；中断也不等于会话或子代理结束。
                if event != "PreCompact" { message.observedState = "completionUnconfirmed" }
                return message
            }
        }
        let nativeAgents = ["claude_code", "codex", "qwen", "qoder", "droid", "gemini_cli", "tabnine", "devin"]
        if nativeAgents.contains(agentType), data?["hook_event_name"] != nil {
            guard let nativeSession = data?["session_id"] as? String,
                  !nativeSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativePayloadError.invalidField("session_id")
            }
        }
        if agentType == "droid", event == "SubagentStop" {
            // 官方尚未定义子 ID 或父子 session_id 关系，不让旧模板猜测结束对象。
            var message = DIMessage(type: .subagentEnd, sessionId: sessionId)
            message.agentType = agentType
            message.nativeEvent = event
            message.subagentEndIsProvisional = true
            message.statusIsAssistantReply = false
            return message
        }
        if ["codex", "claude_code", "qwen", "qoder"].contains(agentType), event == "SubagentStart" || event == "SubagentStop" {
            func nativeText(_ key: String, allowEmpty: Bool = false) throws -> String {
                guard let value = data?[key] as? String,
                      allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.utf8.count <= 4096, !value.utf8.contains(0) else {
                    throw NativePayloadError.invalidField(key)
                }
                return value
            }
            _ = try nativeText("session_id")
            let child = try nativeText("agent_id")
            var message = DIMessage(type: event == "SubagentStart" ? .subagentStart : .subagentEnd, sessionId: sessionId)
            message.agentType = agentType
            message.nativeEvent = event
            message.nativeTurnId = codexTurnID
            // Qwen/Qoder 按上报会话与子 ID 配对；共同会话上下文不等于直接父代理 ID。
            message.parentSessionId = ["qwen", "qoder"].contains(agentType) ? nil : sessionId
            message.subagentId = "\(agentType)-\(child)"
            if agentType == "qoder" {
                // 类型仅作展示；Qoder 未声明该字段必须存在，不能把它作为身份的门槛。
                if data?["agent_type"] != nil { message.prompt = try nativeText("agent_type", allowEmpty: true) }
            } else {
                // Qwen 的类型是字符串；Claude 内部 Stop 允许空类型，Codex 校验保持独立。
                message.prompt = try nativeText("agent_type", allowEmpty:
                    agentType == "qwen" || (agentType == "claude_code" && event == "SubagentStop"))
            }
            message.workingDir = data?["cwd"] as? String
            message.statusIsAssistantReply = false
            if event == "SubagentStop" { message.subagentEndIsProvisional = true }
            return message
        }
        if ["gemini_cli", "tabnine"].contains(agentType), event == "AfterAgent", let reply = data?["prompt_response"] as? String {
            data?["message"] = reply
        }
        var message: DIMessage
        if agentType == "devin" {
            message = try DevinHookAdapter.normalize(hookType: hookType, sessionId: sessionId, stdinData: stdinData)
        } else {
            message = buildMessage(agentType: agentType, hookType: hookType, sessionId: sessionId,
                                   stdinData: data, explicitTool: explicitTool)
        }
        if agentType == "codex" {
            message.nativeEvent = event
            message.nativeTurnId = codexTurnID
        }
        if let id = data?["tool_use_id"] as? String, !id.isEmpty { message.toolCallId = id }
        guard nativeAgents.contains(agentType) else { return message }
        if message.type == .toolStart || message.type == .toolComplete {
            message.toolInput = outputText(data?["tool_input"]) ?? message.toolInput
        }
        if agentType == "tabnine", event == "AfterTool",
           let response = data?["tool_response"] as? [String: Any], let error = response["error"], !(error is NSNull) {
            message.observedState = "error"
        }
        if message.workingDir == nil { message.workingDir = data?["cwd"] as? String }
        switch event {
        case "Stop":
            message.type = .statusUpdate
            // 已核实这些 Stop hooks 仍可要求续跑，不能作为最终空闲回执。
            message.observedState = ["codex", "claude_code", "droid", "qwen", "qoder"].contains(agentType) ? "completionUnconfirmed" : "idle"
            message.statusIsAssistantReply = true
        case "AfterAgent":
            message.type = .statusUpdate
            // Gemini/Tabnine 均可拒绝本次回复并重试，回复只是此时观察到的内容。
            message.observedState = "completionUnconfirmed"
            message.statusIsAssistantReply = true
        case "SessionEnd":
            message.observedState = "completed"
        case "PostToolUseFailure":
            message.observedState = "error"
        case "Notification":
            message.statusIsAssistantReply = false
            let notification = data?["notification_type"] as? String
            if notification == "ToolPermission" || notification == "permission_prompt" {
                message.observedState = "waitingPermission"
            } else if notification == "idle_prompt", !["gemini_cli", "tabnine"].contains(agentType) {
                message.observedState = "idle"
            }
        default: break
        }
        return message
    }

    static func buildMessage(
        agentType: String,
        hookType: String,
        sessionId: String,
        stdinData: [String: Any]?,
        explicitTool: String? = nil
    ) -> DIMessage {
        let hook = hookType.lowercased()

        if hook == "toolstart" || hook == "tool_start" {
            // 观察型前置事件不能因为工具名像问答，就变成未经支持的输入接管。
            return buildToolStart(sessionId: sessionId, data: stdinData, explicitTool: explicitTool)
        }
        if hook == "toolcomplete" || hook == "tool_complete" {
            return buildToolComplete(sessionId: sessionId, data: stdinData, explicitTool: explicitTool)
        }
        if agentType.lowercased() == "codex", hook == "stop" {
            var message = buildNotification(sessionId: sessionId, data: stdinData)
            message.agentType = agentType
            return message
        }

        if hook.contains("pretooluse") || hook.contains("tool_use") || hook == "tooluse" {
            let toolName = explicitTool ?? stdinData?["tool_name"] as? String ?? stdinData?["tool"] as? String ?? ""
            if agentType == "claude_code", isQuestionTool(toolName) {
                return buildQuestionFromPermission(sessionId: sessionId, toolName: toolName, data: stdinData)
            }
            return buildToolStart(sessionId: sessionId, data: stdinData, explicitTool: explicitTool)
        }
        if hook.contains("posttooluse") || hook == "patchapply" {
            return buildToolComplete(sessionId: sessionId, data: stdinData, explicitTool: explicitTool)
        }
        if hook.contains("permission") {
            return buildPermissionRequest(sessionId: sessionId, data: stdinData,
                                          allowsQuestionRedirect: agentType == "claude_code")
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

        let prompt = extractUserPrompt(data)
        msg.prompt = agentType == "codex" ? CodexPromptText.normalized(prompt) : prompt
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

        // 原生工具结果既可能是文本，也可能是 JSON 对象；不能把对象结果静默丢掉。
        msg.toolResult = outputText(data?["tool_result"])
            ?? outputText(data?["tool_response"])
            ?? outputText(data?["result"])
            ?? outputText(data?["error"])
        msg.linesAdded = data?["lines_added"] as? Int
        msg.linesRemoved = data?["lines_removed"] as? Int
        extractTokens(data, into: &msg)
        return msg
    }

    static func outputText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func buildPermissionRequest(sessionId: String, data: [String: Any]?, allowsQuestionRedirect: Bool = true) -> DIMessage {
        let toolName = data?["tool_name"] as? String ?? data?["tool"] as? String ?? "unknown"

        if allowsQuestionRedirect, isQuestionTool(toolName) {
            return buildQuestionFromPermission(sessionId: sessionId, toolName: toolName, data: data)
        }

        var msg = DIMessage(type: .permissionRequest, sessionId: sessionId)
        msg.tool = toolName

        let rawInput = permissionInputText(data)
        let inputDict = rawInput.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let sources: [[String: Any]?] = [inputDict, data]
        var desc = findString(in: sources, keys: ["command"])
            ?? (inputDict == nil ? rawInput : nil)
            ?? findString(in: sources, keys: ["description", "path", "file_path", "pattern", "query", "content", "text"]) ?? ""
        if desc.isEmpty {
            desc = descriptionFromToolInput(inputDict) ?? descriptionFromToolInput(data) ?? ""
        }
        msg.permDescription = desc
        msg.toolInput = rawInput
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
        // MCP/第三方工具的显示名不能决定它是否获得问答回传的许可语义。
        name == "AskUserQuestion"
    }

    private static func claudeQuestionInput(_ data: [String: Any]?) -> [String: Any]? {
        let name = data?["tool_name"] as? String ?? data?["tool"] as? String ?? ""
        guard isQuestionTool(name), data?["mcp_server"] == nil, let input = extractToolInput(data) else { return nil }
        let question: [String: Any]
        let questionKeys: Set<String> = ["question", "header", "options", "multiSelect", "multiple", "answer", "answers"]
        if let rawQuestions = input["questions"] {
            guard Set(input.keys).isSubset(of: ["questions", "answer", "answers"]),
                  let questions = rawQuestions as? [[String: Any]], questions.count == 1 else { return nil }
            question = questions[0]
        } else {
            question = input
        }
        guard Set(question.keys).isSubset(of: questionKeys),
              let text = question["question"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("\0"),
              let options = question["options"] as? [Any] else { return nil }
        for key in ["multiSelect", "multiple"] {
            if let value = question[key] {
                guard let flag = value as? Bool, !flag else { return nil }
            }
        }
        guard options.allSatisfy({ option in
            let label = option as? String ?? (option as? [String: Any])?["label"] as? String
            return label.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.contains("\0") && $0.utf8.count <= 8192 } ?? false
        }) else { return nil }
        return input
    }

    static func buildQuestionFromPermission(sessionId: String, toolName: String, data: [String: Any]?) -> DIMessage {
        guard isQuestionTool(toolName), let inputDict = claudeQuestionInput(data) else {
            var message = DIMessage(type: .statusUpdate, sessionId: sessionId)
            message.status = "Please answer this question in Claude Code."
            message.observedState = "waitingAnswer"
            return message
        }
        var msg = DIMessage(type: .question, sessionId: sessionId)
        msg.allowsCustomAnswer = true
        let questionObject = (inputDict["questions"] as? [[String: Any]])?.first
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

    /// 原始参数按别名优先级保留，不能被后续字段中的用途说明覆盖。
    static func permissionInputText(_ data: [String: Any]?) -> String? {
        var selected: String?
        for key in ["tool_input", "input", "parameters", "params", "args"] {
            if let value = outputText(data?[key]) { selected = value; break }
        }
        if selected == nil, let tool = data?["tool"] as? [String: Any] { selected = outputText(tool["input"]) }
        if let selected {
            // 少数客户端把命令放在顶层；保留完整包，避免只显示嵌套的说明。
            if let command = data?["command"] as? String, !command.isEmpty {
                let input = selected.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if (input?["command"] as? String)?.isEmpty != false { return outputText(data) }
            }
            return selected
        }
        return outputText(data)
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

    static func shouldSkipImportedClaudeHook(agentType: String, stdinData: [String: Any]?, environment: [String: String]) -> Bool {
        guard agentType == "claude_code", environment["DEVIN_PROJECT_DIR"]?.isEmpty == false,
              stdinData?["hook_event_name"] is String, stdinData?["session_id"] is String else { return false }
        // Claude 原生事件必带 cwd；嵌套启动 Claude 时即使继承 Devin 环境，也必须正常接收。
        return stdinData?["cwd"] == nil
    }

    static func isClaudeCodeQuestion(hookType: String, stdinData: [String: Any]?) -> Bool {
        let hook = hookType.lowercased()
        guard hook.contains("pretooluse") || hook.contains("tool_use")
                || hook == "tooluse" || hook.contains("permission") else { return false }
        return claudeQuestionInput(stdinData) != nil
    }

    /// 是否为需要走 Claude Code 风格 stdout 的 `PermissionRequest` hook（退出码本身不够）。
    static func usesClaudeCodePermissionStdout(agentType: String) -> Bool {
        let agent = agentType.lowercased()
        return ["claude_code", "trae", "codex", "qwen", "qoder"].contains(agent)
    }

    struct PermissionHookResponse {
        let stdout: String?
        let exitCode: Int32
    }

    static func permissionHookResponse(agentType: String, approved: Bool, adapter: String? = nil) -> PermissionHookResponse {
        if agentType == "opencode", adapter == "opencode_plugin" { return OpenCodeHookAdapter.permissionResponse(approved: approved) }
        if agentType.lowercased() == "devin" { return DevinHookAdapter.permissionResponse(approved: approved) }
        if usesClaudeCodePermissionStdout(agentType: agentType) {
            // 成功执行 hook 与批准命令是两回事；拒绝也用 exit 0 交付结构化 decision。
            return PermissionHookResponse(stdout: buildClaudeCodePermissionResponse(approved: approved), exitCode: 0)
        }
        return PermissionHookResponse(stdout: nil, exitCode: approved ? 0 : 1)
    }

    private static func emitDevinUnavailablePermission() -> Never {
        let output = DevinHookAdapter.unavailablePermissionResponse()
        if let stdout = output.stdout { print(stdout) }
        exit(output.exitCode)
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
        guard isClaudeCodeQuestion(hookType: hookType, stdinData: stdinData),
              let toolInput = claudeQuestionInput(stdinData),
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !answer.contains("\0"), answer.utf8.count <= 8192 else { return "{}" }
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

        let output: [String: Any]
        if hookEventName == "PermissionRequest" {
            output = ["hookEventName": hookEventName,
                      "decision": ["behavior": "allow", "updatedInput": updatedInput] as [String: Any]]
        } else {
            output = ["hookEventName": hookEventName, "permissionDecision": "allow", "updatedInput": updatedInput]
        }
        let payload: [String: Any] = ["hookSpecificOutput": output]
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
