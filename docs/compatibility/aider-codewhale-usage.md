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

## 复制给 LLM

下面两段分别用于 Aider 和 Codewhale。复制对应的一段即可，不要同时让 Agent 修改两套配置。

### Aider

```text
你是我的 macOS 配置助手。请为本机 X Island 配置 Aider 包装入口。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- Aider 入口应准备为 $HOME/.xisland/bin/xisland-aider；普通 aider 启动不经过该入口。
- 不要修改 Aider 的 YAML、.env、模型或凭据；只准备并验证包装入口。

执行：
1. 检查 Aider 是否在 PATH 中，以及 xisland-aider 是否已存在；备份已有的可执行文件。
2. 如缺失，使用 X Island 的接入准备流程生成 xisland-aider；生成后检查它是可执行文件，并确认调用时会保留原 Aider 参数。
3. 用 $HOME/.xisland/bin/xisland-aider --xisland-help 做一次离线检查；不要用真实模型跑任务。
4. 告诉我如何用该入口启动一条只读任务，并在 X Island 中检查进程会话是否出现。

边界：
- 不替换系统里的 aider，不修改 PATH，不写通知命令到用户配置。
- Aider 的通知可能出现在自动确认前，不能据此断言任务成功或必须回答。
- 完成后报告：入口路径、备份、检查命令和仍需我运行的只读任务。
```

### Codewhale / DeepSeek-TUI

```text
你是我的 macOS 配置助手。请为本机 X Island 配置 Codewhale 0.10.0 观察 hooks。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 仅 Codewhale 0.10.0 的已核实版本可自动匹配；它不是 DeepSeek 官方聊天产品。
- 配置路径按优先级处理 CODEWHALE_CONFIG_PATH、DEEPSEEK_CONFIG_PATH、CODEWHALE_HOME，再选择已有的 ~/.codewhale/config.toml 或 ~/.deepseek/config.toml。

执行：
1. 检查版本和实际配置路径；版本不是 0.10.0 或无法确认时停止，不要套用通用模板。
2. 备份目标 TOML，读取现有 hooks；只追加带 XIsland:Codewhale 标记的块，保留第三方 hooks 和其他配置。
3. 校验 TOML 可解析，确认全局 hooks 没有被显式禁用；如果用户禁用了 hooks，不要强行开启。
4. 启动一条只读任务，检查 X Island 是否出现会话和工具状态。

边界：
- 14 个事件只观察；不要伪造审批、问答或 tool call 的 allow。
- 不修改模型、凭据和启动参数；不要新建高优先级文件遮蔽已有旧路径。
- 完成后报告：版本判断、实际配置路径、备份、TOML 校验和真实事件结果。
```
