# Continue 服务状态观察

当前通道基于 `@continuedev/cli` 1.5.47 的 `cn serve` `/state` 快照。普通 TUI、IDE 插件和未接线的 hooks 不属于此通道。真实客户端验收尚未完成。

在 XIsland 设置中打开 Continue 接收开关。针对已经由你启动的服务，显式运行应用内的观察命令（端口替换为实际值）：

```sh
"/Applications/X Island.app/Contents/MacOS/di-bridge" continue-state --url http://127.0.0.1:3000 --duration 300 --interval 1
```

可加 `--session 原生会话ID` 固定期望身份。观察器只访问指定数字回环地址的 `/state`，拒绝重定向，遇到会话变化或异常响应便退出，不自动重连。它不会启动服务、修改配置或关闭会话。GET `/state` 会刷新服务活动时间；观察最多 3600 秒，默认 300 秒。

可观察处理/空闲/待审批状态、工具调用、累计用量和回复预览。审批仍在 Continue 完成：请求编号在服务重启后会复用，当前接口不足以安全绑定独立审批写入。消息没有稳定 ID，因此预览不会伪造聊天历史身份。轮询可能遗漏两次快照间的短暂状态；断开仅表示观察结束，不代表原生会话完成。

关闭设置中的接收开关会停止 XIsland 接收该来源；已启动的观察命令仍运行到时限或被手动终止。

状态解析与回环 HTTP 边界可通过 `Scripts/test-continue-state.py` 验证，离线测试不等于真实客户端验收。公开状态见[适配矩阵](agent-matrix.json)与[验证摘要](release-verification-2.0.0.json)。

## 复制给 LLM

Continue 已停用。下面提示只用于判断是否还要保留旧观察，不应新建 Continue 配置。

```text
你是我的 macOS 配置助手。我正在检查 Continue 的旧 X Island 接入，请不要为它新建 hooks。

已知：
- Continue 已于 2026-06 被 Cursor 收购，仓库只读，最后版本 v2.0.0-vscode；新接入应改用 Cursor。
- 旧通道只是对已启动的 cn serve /state 做限时观察，不修改 Continue 配置、不接管审批，也不启动服务。

执行：
1. 检查我是否仍在运行旧 Continue 服务、是否存在指向 continue-state 的 X Island 观察进程。
2. 如果只是历史残留，列出进程和配置位置，先备份，再只移除可证明属于 X Island 的条目；不要删除 Continue 用户数据。
3. 如果我确实需要继续观察，给出显式命令：di-bridge continue-state --url http://127.0.0.1:<实际端口> --duration <不超过3600> --interval 1，并说明轮询可能漏状态、审批仍在 Continue。
4. 建议我迁移到 Cursor 接入，并报告仍未迁移的旧会话或配置。

边界：
- 不新建 hooks.json，不自动重连，不把观察结束当成任务完成。
- 不读取或输出 Continue 的凭据；不修改服务配置。
- 完成后报告：发现的旧进程/配置、备份、清理结果和迁移建议。
```
