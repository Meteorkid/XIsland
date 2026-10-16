# Cody Agent 接入

当前实现基于 `@sourcegraph/cody@5.5.26` 发行包中的 Agent 协议，真实客户端尚未验收。仅用于调用方能显式选择 Agent 启动命令的场景；不能接管已经打开的 VS Code 会话，也不把普通 `cody chat` 输出当作此协议。

在 XIsland 设置中开启“Cody Agent 观察”。将原有 Agent 启动命令显式包装为：

```sh
"/Applications/X Island.app/Contents/MacOS/di-bridge" cody-agent --source my-cody-client -- /absolute/path/to/cody jsonrpc-stdio
```

本命令应由原来的 JSON-RPC 客户端驱动，单独在终端运行不会产生聊天。路径替换为已安装且版本核实的程序；同一客户端注册使用稳定 source，不同注册使用不同 source。此工具不会安装 Cody、写 IDE 配置、登录或替用户初始化会话。认证和交互仍通过原始协议由原客户端完成。

可观察：原生 chatID 对应的处理中/空闲状态、transcript 错误标记与回复预览。暂不提供审批、工具调用、累计用量或稳定聊天消息历史。面板 ID 不等于会话 ID；会话恢复与分叉仍需真实客户端验收。

字节原样转发，stderr 和退出码保留。观察头部超过 8 KiB、正文超过 2 MiB、队列超过 2 MiB、会话超过 64 个或解析异常会停止观察并提示旧状态可能过期，转发继续；观察结束不代表原生会话完成。关闭接收开关不会终止原客户端或代理进程。

离线模拟子进程、字节透传与协议边界可通过 `Scripts/test-cody-proxy.py` 验证，不能替代 Cody 与目标 IDE 的实际验收。公开状态见[适配矩阵](agent-matrix.json)与[验证摘要](release-verification-2.0.0.json)。
