# Aider 与 Codewhale 接入说明

这两条接入已有指定版本的基础实现和离线契约验证，真实客户端联调尚未完成。状态记录见[兼容矩阵](agent-matrix.json)，发行构建测试见[公开摘要](release-verification-2.0.0.json)。

## Aider

安装包含本次改动的 XIsland 并启用 Aider 配置后，通过以下入口启动：

```sh
~/.xisland/bin/xisland-aider [原有 Aider 参数]
~/.xisland/bin/xisland-aider --xisland-help
```

入口要求 `aider` 已在调用终端的 PATH 中。它为本次进程分配 `aider-wrapper-<UUID>`，显示进程连接、原生通知和进程退出。标识属于 XIsland 包装器；历史恢复后的新进程也会有新标识。模型、工具、问题内容与原生审批仍在 Aider 中处理。

通知只表示“收到 Aider 通知，请查看终端”。Aider 在中途确认、自动确认前也可能触发通知，不能据此判定任务成功或必须由用户回答。已核实的源码版本是 Aider 0.86.2，真实版本验收仍待完成。

XIsland 的通知参数只作用于这次启动，原有 YAML、`.env`、凭据不变；用户显式传入的 `--notifications-command` 或 `--no-notifications` 按 Aider 自身规则覆盖，届时可能只能看到进程生命周期。包装器不会读取有效配置里的旧通知命令并拼接执行。

新入口使用 `xisland-aider`，保留既有 `aider-bridge` 文件，避免把旧通知辅助命令悄悄改成启动新 AI 进程。配置关闭或卸载只移除完整匹配的自有新入口；修改过的用户文件和符号链接不覆盖。安装文件存在只表示入口已配置。

## Codewhale / DeepSeek-TUI

此处是维护者 Hmbown 的第三方 TUI，不能解释为 DeepSeek 官方聊天产品。当前自动安装只匹配 Codewhale 0.10.0 的已核实版本输出；其他版本不会被通用模板改写。

安装器按真实路径优先级处理 `CODEWHALE_CONFIG_PATH`、`DEEPSEEK_CONFIG_PATH`、`CODEWHALE_HOME`，再选择已有 `.codewhale/config.toml` 或已有 `.deepseek/config.toml`。已有旧路径不会被新建高优先级文件遮蔽。若启动时另传 `--config`，需以那一次启动的显式路径为准，自动安装器不能推测另一个终端的参数。

14 个事件均为观察用途。原生会话、工具、子代理标识保持，累计 token/费用以快照处理。审批和问答的等待状态只作提示，用户继续在 TUI 中处理；没有对应请求 ID 和可靠应答通道时不出现代答按钮。

全局 hooks 显式禁用时不会被开启；第三方 TOML 和 hooks 保留。只有两个前置事件使用后台观察，避免 hook 成功退出被当作批准。退出后的迟到事件不会重开会话。上游活跃会话状态缺少统一序号，因此快速状态切换仍有乱序风险，列入真实版本验收。

## 验证方式

```sh
swift test
python3 Scripts/test-native-hook-bridge.py
python3 Scripts/test-aider-wrapper.py
python3 Scripts/test-terminal-supervisor.py
```

脚本仅使用临时目录、临时 socket 和离线替身；终端测试使用 PTY 验证信号、挂起和恢复。它们不启动真实 Aider/Codewhale 模型任务，也不代替客户端启用后的端到端验收。
