# 旧 Amazon Q CLI 接入

仅限固定源码对应的 `qchat 1.19.7`。包装器会先运行限时 `--version`，不匹配则拒绝启动聊天。`q` 前端、Kiro 和 Amazon Q IDE 不能按名称视为等价；真实发行二进制与原生配置加载仍待验收。

## 配置审查

从你选定的单个 agent JSON 生成候选配置，先写入一个新文件审查：

```sh
"/Applications/X Island.app/Contents/MacOS/di-bridge" amazonq-config-1-19-7 < selected-agent.json > reviewed-agent.json
```

不要将输入和输出指定为同一文件。命令本身只读 stdin、写 stdout，不修改配置文件。它保留 agent 名称、权限、工具设置和现有 hooks，仅追加五种观察事件。完全相同的命令不重复追加；桥接路径改变后需要检查旧条目，生成器不会删除不认识的命令。

固定版本源码中的 agent 路径为项目 `.amazonq/cli-agents/<name>.json` 或全局 `~/.aws/amazonq/cli-agents/<name>.json`。审查后由用户选择部署位置和 agent；本工具不自动覆盖、切换默认 agent 或放宽授权。备份原文件可恢复配置。

## 显式启动

在 XIsland 中开启 Amazon Q“旧 Q 进程观察”。把已经核实的 qchat 启动命令包装为：

```sh
"/Applications/X Island.app/Contents/MacOS/di-bridge" amazonq-1-19-7 -- /absolute/path/to/qchat chat
```

在该命令后保留你原来的 agent 选择和聊天参数，并确认实际选择的 agent 包含审查后的 hooks。包装器只注入临时租约路径，不安装 hook。没有有效租约时，专用 hook 不上报事件，也不替代原生审批。

## 范围与限制

- 原生 hook 没有会话 ID，XIsland 身份仅代表一次包装进程；恢复/切换原生会话不具备独立身份映射。
- 可观察提示提交、工具准备与结果、回合结束、包装进程退出。没有稳定调用 ID，不按工具名配对；没有回复正文，不生成回复历史。
- PreToolUse 之后用户仍可拒绝，所以只显示准备状态；所有观察 hook 保持空 stdout，退出 0 只代表观察不阻断，不代表替用户批准。
- 正常退出撤销租约，晚到事件不能重新打开已退出包装会话。SIGKILL 或监督器崩溃可能无法发送结束事件；后续回调会检查所有者 PID 及启动时间。完整异常退出体验仍待验收。
- 关闭接收开关不终止 qchat。代理与 hook 继续按原进程生命周期运行。

项目中的配置生成、版本门槛、租约和离线包装进程测试见 `Scripts/test-amazonq-wrapper.py`；它们不能替代固定发行客户端的实际配置加载与任务验收。公开状态见[适配矩阵](agent-matrix.json)与[验证摘要](release-verification-2.0.0.json)。
