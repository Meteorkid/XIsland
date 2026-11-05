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
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--agent" where index + 1 < arguments.count:
                agentType = arguments[index + 1]
                index += 2
            case "--session" where index + 1 < arguments.count:
                explicitSession = arguments[index + 1]
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

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            handleLine(line, target: target)
        }
        return 0
    }

    private static func handleLine(_ line: String, target: ApprovalGraphTarget) {
        guard line.utf8.count <= 128 * 1024 else { return }
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = request["method"] as? String else { return }
        let isNotification = request["id"] == nil
        do {
            let result = try dispatch(method: method, params: request["params"] as? [String: Any] ?? [:], target: target)
            if !isNotification {
                writeResponse(id: request["id"], result: result)
            }
        } catch let error as MCPError {
            if !isNotification { writeError(id: request["id"], code: error.code, message: error.message) }
        } catch {
            if !isNotification { writeError(id: request["id"], code: -32603, message: "Internal error") }
        }
    }

    private static func dispatch(method: String, params: [String: Any],
                                 target: ApprovalGraphTarget) throws -> Any {
        switch method {
        case "initialize":
            sendHandshake(target: target)
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? "2025-06-18"
            return [
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "xisland-approval-graph", "version": "1.0.0"]
            ]
        case "notifications/initialized", "notifications/cancelled":
            return [:]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": toolDefinitions]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPError(code: -32602, message: "tools/call requires a tool name")
            }
            if let rawArguments = params["arguments"], !(rawArguments is [String: Any]) {
                throw MCPError(code: -32602, message: "tools/call arguments must be an object when provided")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let request: ApprovalGraphRequest
            switch name {
            case "approval_graph_get":
                request = try getRequest(arguments: arguments, baseTarget: target)
            case "approval_graph_write":
                request = try writeRequest(arguments: arguments, baseTarget: target)
            default:
                throw MCPError(code: -32602, message: "Unknown tool: \(name)")
            }
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

    private static var toolDefinitions: [[String: Any]] {
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
        guard let data = try? DIProtocol.encode(message),
              DIBridge.sendAll(fd: fd, data: data) else { return }
        shutdown(fd, SHUT_WR)
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
