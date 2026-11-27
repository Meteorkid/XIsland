import Darwin
import Foundation
import DIShared

/// Minimal stdio MCP server for agent-authored approval graphs.
///
/// The process is intentionally stateless: every tool call becomes one local
/// socket request, so the running app remains the sole owner of graph state.
enum MCPApprovalGraphServer {
    private static let supportedVersions = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"
    ]

    static func run(arguments: [String]) -> Int32 {
        var agentType: String?
        var explicitSession: String?
        var observeAgent: String?
        var observeSession: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--agent" where index + 1 < arguments.count:
                agentType = arguments[index + 1]
                index += 2
            case "--session" where index + 1 < arguments.count:
                explicitSession = arguments[index + 1]
                index += 2
            case "--observe-agent" where index + 1 < arguments.count:
                observeAgent = arguments[index + 1]
                index += 2
            case "--observe-session" where index + 1 < arguments.count:
                observeSession = arguments[index + 1]
                index += 2
            default:
                fputs("[di-bridge mcp-server] Unknown argument: \(arguments[index])\n", stderr)
                return 64
            }
        }

        let environment = ProcessInfo.processInfo.environment
        let target = ApprovalGraphTarget(
            sessionID: explicitSession ?? environment["DI_SESSION_ID"] ?? environment["XISLAND_SESSION_ID"],
            agentType: agentType,
            workingDirectory: FileManager.default.currentDirectoryPath,
            terminalSessionID: environment["TERM_SESSION_ID"]
                ?? environment["ITERM_SESSION_ID"]
                ?? environment["WEZTERM_PANE"]
        )
        // 观察模式没有客户端会话 ID：一个连接器进程就是一个观察会话，结束时关闭它。
        var observation = observeAgent.map {
            ObservationContext(agentType: $0,
                               sessionID: observeSession ?? "doubao-\(UUID().uuidString.prefix(8).lowercased())")
        }

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            handleLine(line, target: target, observation: &observation)
        }
        if var context = observation, context.started {
            context.started = false
            let message = observationMessage(type: .sessionEnd, context: context, event: "connector_closed")
            ObservationSender.send(message, socketPath: DIBridge.socketPath())
        }
        return 0
    }

    private struct ObservationContext {
        let agentType: String
        let sessionID: String
        var started = false
    }

    private static func observationMessage(type: DIMessageType, context: ObservationContext,
                                           event: String) -> DIMessage {
        var message = DIMessage(type: type, sessionId: context.sessionID)
        message.agentType = context.agentType
        message.nativeEvent = event
        message.statusIsAssistantReply = false
        return message
    }

    private static func handleLine(_ line: String, target: ApprovalGraphTarget,
                                   observation: inout ObservationContext?) {
        guard line.utf8.count <= 128 * 1024 else { return }
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = request["method"] as? String else { return }
        let isNotification = request["id"] == nil
        do {
            let result = try dispatch(method: method, params: request["params"] as? [String: Any] ?? [:],
                                      target: target, observation: &observation)
            if !isNotification {
                writeResponse(id: request["id"], result: result)
            }
        } catch let error as MCPError {
            if !isNotification { writeError(id: request["id"], code: error.code, message: error.message) }
        } catch {
            if !isNotification { writeError(id: request["id"], code: -32603, message: "Internal error") }
        }
    }

    private static func dispatch(method: String, params: [String: Any], target: ApprovalGraphTarget,
                                 observation: inout ObservationContext?) throws -> Any {
        switch method {
        case "initialize":
            sendHandshake(target: target)
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? "2025-06-18"
            return [
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": observation == nil ? "xisland-approval-graph" : "xisland-activity", "version": "1.0.0"]
            ]
        case "notifications/initialized", "notifications/cancelled":
            return [:]
        case "ping":
            sendHandshake(target: target)
            return [:]
        case "tools/list":
            sendHandshake(target: target)
            return ["tools": toolDefinitions(observation: observation)]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPError(code: -32602, message: "tools/call requires a tool name")
            }
            if let rawArguments = params["arguments"], !(rawArguments is [String: Any]) {
                throw MCPError(code: -32602, message: "tools/call arguments must be an object when provided")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            if observation != nil {
                guard name == "xisland_activity" else {
                    throw MCPError(code: -32602, message: "Unknown tool: \(name)")
                }
                return try reportActivity(arguments: arguments, observation: &observation)
            }
            let request: ApprovalGraphRequest
            switch name {
            case "approval_graph_get":
                request = try getRequest(arguments: arguments, baseTarget: target)
            case "approval_graph_write":
                request = try writeRequest(arguments: arguments, baseTarget: target)
            default:
                throw MCPError(code: -32602, message: "Unknown tool: \(name)")
            }
            sendHandshake(target: target)
            let response = send(request)
            guard let response, response.ok, let document = response.document else {
                let message = response?.message ?? "X Island is not running or did not return a graph response."
                return [
                    "content": [["type": "text", "text": message]],
                    "isError": true
                ]
            }
            let encoded = try prettyJSON(document)
            return ["content": [["type": "text", "text": encoded]], "isError": false]
        default:
            throw MCPError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func toolDefinitions(observation: ObservationContext?) -> [[String: Any]] {
        // 观察模式只暴露活动上报：豆包工作没有可用的审批图会话，列出审批工具只会误导。
        if observation != nil {
            return [[
                "name": "xisland_activity",
                "description": "Report a short activity note to X Island while working. Call it when a task starts and whenever a notable step finishes. X Island only displays the note; it never grants approvals or permissions.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "summary": ["type": "string", "description": "One-line activity summary shown in the island (1-512 bytes)."],
                        "detail": ["type": "string", "description": "Optional longer detail, e.g. the command or file being worked on."]
                    ],
                    "required": ["summary"],
                    "additionalProperties": false
                ]
            ]]
        }
        let targetProperties: [String: Any] = [
            "session_id": ["type": "string", "description": "Optional exact X Island session ID. Omit to auto-bind by agent, terminal, or working directory."]
        ]
        return [
            [
                "name": "approval_graph_get",
                "description": "Read the explicit approval task graph for the current agent session, including accepted nodes, proposals and comments.",
                "inputSchema": [
                    "type": "object",
                    "properties": targetProperties,
                    "additionalProperties": false
                ]
            ],
            [
                "name": "approval_graph_write",
                "description": "Atomically propose task/step nodes for the current session. Proposals do not become accepted until the user keeps them in X Island.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": targetProperties["session_id"]!,
                        "base_revision": ["type": "integer", "minimum": 0],
                        "request_id": ["type": "string", "description": "Idempotency key for this write."],
                        "nodes": [
                            "type": "array",
                            "minItems": 1,
                            "maxItems": ApprovalGraphValidator.maxNodes,
                            "items": [
                                "type": "object",
                                "properties": [
                                    "id": ["type": "string"],
                                    "parent_id": ["type": ["string", "null"]],
                                    "kind": ["type": "string", "enum": ["task", "step"]],
                                    "title": ["type": "string"],
                                    "detail": ["type": "string"],
                                    "status": ["type": "string", "enum": ["pending", "active", "done", "blocked", "cancelled"]]
                                ],
                                "required": ["id", "kind", "title", "status"],
                                "additionalProperties": false
                            ]
                        ]
                    ],
                    "required": ["base_revision", "request_id", "nodes"],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    /// 豆包工作连接器上报的活动：开启或复用本次连接器会话，并记录一次工具级事件。
    /// 只做单向观察；不等待 UI，也不参与审批。
    private static func reportActivity(arguments: [String: Any],
                                       observation: inout ObservationContext?) throws -> Any {
        guard var context = observation else {
            throw MCPError(code: -32603, message: "Observation context unavailable")
        }
        guard let summary = (arguments["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty, summary.utf8.count <= 512, !summary.utf8.contains(0) else {
            throw MCPError(code: -32602, message: "summary is required (1...512 bytes)")
        }
        var detail = (arguments["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail?.isEmpty == true { detail = nil }
        if let detail, detail.utf8.count > 2048 || detail.utf8.contains(0) {
            throw MCPError(code: -32602, message: "detail must be at most 2048 bytes")
        }

        let socketPath = DIBridge.socketPath()
        if !context.started {
            var start = observationMessage(type: .sessionStart, context: context, event: "xisland_activity")
            start.prompt = summary
            ObservationSender.send(start, socketPath: socketPath)
            context.started = true
            observation = context
        }

        let callID = "activity-\(Int(Date().timeIntervalSince1970 * 1000))"
        var toolStart = observationMessage(type: .toolStart, context: context, event: "xisland_activity")
        toolStart.tool = "xisland_activity"
        toolStart.toolCallId = callID
        toolStart.toolInput = detail ?? summary
        ObservationSender.send(toolStart, socketPath: socketPath)

        var complete = observationMessage(type: .toolComplete, context: context, event: "xisland_activity")
        complete.tool = "xisland_activity"
        complete.toolCallId = callID
        complete.toolResult = summary
        ObservationSender.send(complete, socketPath: socketPath)

        return [
            "content": [["type": "text", "text": "已记录到 X Island；这只是活动上报，不代表审批或授权。"]],
            "isError": false
        ]
    }

    static func getRequest(arguments: [String: Any],
                           baseTarget: ApprovalGraphTarget) throws -> ApprovalGraphRequest {
        var target = baseTarget
        if let session = arguments["session_id"] as? String, !session.isEmpty { target.sessionID = session }
        return ApprovalGraphRequest(operation: .get, target: target)
    }

    static func writeRequest(arguments: [String: Any],
                             baseTarget: ApprovalGraphTarget) throws -> ApprovalGraphRequest {
        guard let revision = (arguments["base_revision"] as? NSNumber)?.intValue,
              let requestID = arguments["request_id"] as? String,
              let rawNodes = arguments["nodes"] as? [[String: Any]] else {
            throw MCPError(code: -32602, message: "base_revision, request_id and nodes are required")
        }
        var target = baseTarget
        if let session = arguments["session_id"] as? String, !session.isEmpty { target.sessionID = session }
        let nodes = try rawNodes.map { raw -> ApprovalGraphNode in
            guard let id = raw["id"] as? String,
                  let kindRaw = raw["kind"] as? String,
                  let kind = ApprovalGraphNodeKind(rawValue: kindRaw),
                  let title = raw["title"] as? String,
                  let statusRaw = raw["status"] as? String,
                  let status = ApprovalGraphNodeStatus(rawValue: statusRaw) else {
                throw MCPError(code: -32602, message: "Invalid task graph node")
            }
            return ApprovalGraphNode(
                id: id,
                parentID: raw["parent_id"] as? String,
                kind: kind,
                title: title,
                detail: raw["detail"] as? String,
                status: status
            )
        }
        do { try ApprovalGraphValidator.validate(nodes, allowExternalParents: true) }
        catch { throw MCPError(code: -32602, message: String(describing: error)) }
        return ApprovalGraphRequest(
            operation: .write,
            target: target,
            baseRevision: revision,
            requestID: requestID,
            nodes: nodes
        )
    }

    private static func send(_ request: ApprovalGraphRequest) -> ApprovalGraphResponsePayload? {
        let fd = DIBridge.connectSocket()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var message = DIMessage(type: .approvalGraphRequest, sessionId: request.target.sessionID ?? "")
        message.agentType = request.target.agentType
        if let agent = request.target.agentType, !agent.isEmpty {
            message.integrationFingerprint = handshakeFingerprint(agent: agent)
        }
        message.workingDir = request.target.workingDirectory
        message.termSessionId = request.target.terminalSessionID
        message.approvalGraphRequest = request
        guard let data = try? DIProtocol.encode(message), DIBridge.sendAll(fd: fd, data: data) else { return nil }
        shutdown(fd, SHUT_WR)
        guard let responseData = DIBridge.readFramedMessage(fd, timeoutSeconds: 8),
              let response = try? DIProtocol.decode(responseData),
              response.type == .approvalGraphResponse else { return nil }
        return response.approvalGraphResponse
    }

    /// MCP initialization is the first point at which a real client has loaded
    /// this server. Report that fact separately from hook activity and file writes.
    private static func sendHandshake(target: ApprovalGraphTarget) {
        guard let agent = target.agentType, !agent.isEmpty else { return }
        let fd = DIBridge.connectSocket()
        guard fd >= 0 else { return }
        defer { close(fd) }
        var message = DIMessage(type: .mcpHandshake, sessionId: "mcp-handshake:\(agent)")
        message.agentType = agent
        message.nativeEvent = "initialize"
        message.integrationFingerprint = handshakeFingerprint(agent: agent)
        guard let data = try? DIProtocol.encode(message),
              DIBridge.sendAll(fd: fd, data: data) else { return }
        shutdown(fd, SHUT_WR)
    }

    private static func handshakeFingerprint(agent: String) -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        return ApprovalGraphMCPIdentity.fingerprint(command: executable, agent: agent)
    }

    private static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func writeResponse(id: Any?, result: Any) {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { response["id"] = id }
        writeJSON(response)
    }

    private static func writeError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { response["id"] = id }
        writeJSON(response)
    }

    private static func writeJSON(_ value: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    struct MCPError: Error {
        let code: Int
        let message: String
    }
}
