import Foundation

/// 豆包工作的接入文件。
///
/// 豆包工作（Doubao Work）没有公开的原生 hooks；它提供的可编程入口是
/// 「插件 → 新建自定义连接器」，支持 HTTP 与本地 STDIO 的 MCP。
/// 因此这里只准备一份可审阅的连接器定义与操作说明，由用户在本机客户端中手动添加。
/// 生成文件不等于客户端已加载，也不代表能接管任务、审批或问答。
enum DoubaoWorkConnectorConfiguration {
    static let connectorFileName = "connector.json"
    static let readmeFileName = "README.txt"

    enum ConfigurationError: Error, Equatable {
        case invalidBridgePath
    }

    static func files(bridgePath: String) throws -> [String: Data] {
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0),
              !bridgePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ConfigurationError.invalidBridgePath
        }
        let connector: [String: Any] = [
            "name": "X Island",
            "transport": "stdio",
            "command": bridgePath,
            "args": ["doubao-work-mcp"],
            "env": [String: String](),
            "notes": [
                "仅在豆包工作客户端、本地电脑模式下可用。",
                "X Island 只接收你显式调用 xisland_activity 时上报的活动；完整任务、审批和问答仍在豆包工作内完成。",
                "连接器断开（客户端退出或删除连接器）时，对应活动会结束。",
            ],
        ]
        var data = try JSONSerialization.data(withJSONObject: connector, options: [.prettyPrinted, .sortedKeys])
        data.append(10)

        let readme = """
        豆包工作 · X Island 连接器
        ============================

        1. 打开豆包工作客户端，切到「本地电脑」模式。
        2. 左侧进入「插件·技能·伙伴」→「插件」→ 右上角「+ 添加」→「新建自定义连接器」。
        3. 服务器名称填：X Island
        4. 传输类型选：STDIO
        5. 命令填：\(bridgePath)
        6. 参数填：doubao-work-mcp
        7. 保存后，在任务中让豆包工作调用 xisland_activity，X Island 会显示这次活动。

        限制
        ----
        - 豆包工作未公开原生 hooks，本接入不是任务级 hook。
        - 只有显式调用 xisland_activity 的动作会被观察；不会自动接管审批、问答或取消。
        - 连接器断开即视为活动结束；不推断任务完成。
        - 连接器只在本地电脑模式可用，云电脑模式无法访问本机命令。

        安全
        ----
        本接入不需要密码、API Key 或任何凭据；命令只指向本机 X Island 桥接程序。
        """
        return [connectorFileName: data, readmeFileName: Data(readme.utf8)]
    }
}
