import Foundation
import DIShared

enum AmazonQLauncher {
    static let leaseKey = "X_ISLAND_AMAZONQ_LEASE"

    static func run(arguments: [String], bridgePath: String,
                    environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        guard environment[leaseKey] == nil, arguments.first == "--", arguments.count >= 2,
              let executable = AiderLauncher.executablePath(arguments[1], environment: environment),
              executable != AiderLauncher.executablePath(bridgePath, environment: environment) else {
            fputs("[XIsland] 用法：di-bridge amazonq-1-19-7 -- Q命令 [参数]；仅适用于已核实的旧 Q CLI。\n", stderr)
            return 126
        }
        guard AmazonQVersionProbe.verify(executable: executable, environment: environment) else {
            fputs("[XIsland] 未验证为 qchat 1.19.7；未启动聊天或写入配置。\n", stderr)
            return 126
        }
        do {
            let socket = DIBridge.socketPath(environment: environment)
            let lease = try AmazonQSessionLease(socketPath: socket)
            var childEnvironment = environment
            childEnvironment[leaseKey] = lease.path
            var identity: String?
            let code = try TerminalProcessSupervisor.run(executable: executable, arguments: Array(arguments.dropFirst(2)), environment: childEnvironment) { _ in
                do {
                    try lease.activate()
                    try AmazonQSessionLease.withActiveState(at: lease.path) { state in
                        identity = state.id
                        var message = lifecycle(state.id, event: "amazonq_wrapper_start", type: .statusUpdate)
                        message.status = "Amazon Q 包装进程已连接；原生会话身份不可用"
                        ObservationSender.send(message, socketPath: socket)
                    }
                } catch {
                    fputs("[XIsland] Amazon Q 观察身份未能激活；原进程继续运行。\n", stderr)
                }
            }
            do { try lease.end() }
            catch { fputs("[XIsland] Amazon Q 观察身份已撤销。\n", stderr) }
            if let identity {
                var message = lifecycle(identity, event: "amazonq_wrapper_end", type: .sessionEnd)
                message.status = "Amazon Q 包装进程已退出（退出码 \(code)）；不代表原生历史会话被删除"
                ObservationSender.send(message, socketPath: socket)
            }
            return code
        } catch {
            fputs("[XIsland] Amazon Q 包装进程启动失败。\n", stderr)
            return 126
        }
    }

    /// 观察失败不返回 Q 的阻断码 2，也不向模型上下文输出占位文本。
    static func hook(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard arguments.count == 1, let path = environment[leaseKey] else { return }
        let payload = DIBridge.readStdin()
        do {
            try AmazonQSessionLease.withActiveState(at: path) { state in
                let message = try AmazonQHookAdapter.normalize(hookType: arguments[0], stdinData: payload, wrapperSessionID: state.id)
                ObservationSender.send(message, socketPath: state.socketPath)
            }
        } catch {
            fputs("[XIsland] 忽略已结束或无效的 Amazon Q 观察事件。\n", stderr)
        }
    }

    private static func lifecycle(_ identity: String, event: String, type: DIMessageType) -> DIMessage {
        var message = DIMessage(type: type, sessionId: "amazonq-wrapper-" + identity.lowercased())
        message.agentType = "amazon_q"
        message.nativeEvent = event
        message.statusIsAssistantReply = false
        message.workingDir = FileManager.default.currentDirectoryPath
        return message
    }
}
