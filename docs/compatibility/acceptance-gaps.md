# 接入验收与剩余工作

更新日期：2026-11-25。30 项原定目标与额外客户端（WorkBuddy、Antigravity、豆包工作、Kilo Code）均保留：30 项可接入，5 项已停用并只保留历史。所有完整验收标记仍为 `false`。公开状态见[适配矩阵](agent-matrix.json)，构建和验证范围见[发布验证摘要](release-verification-2.0.0.json)。

## 本轮补齐的基础接入

- Kiro：已补齐 CLI 2.31.0 V3 独立配置导出、幂等合并与移除、六类观察事件；真实加载、IDE 与其他引擎版本仍待验。见[使用指南](kiro-setup.md)。
- GLM：已按用户选择接入 Claude Code、OpenCode、Cline、Pi 的模型字段，支持显示、筛选、搜索和历史；客户端身份不变。见[使用指南](glm-setup.md)。
- Kilo Code：已补齐 OpenCode 内核的原生全局插件、源归属校验、会话/工具/等待状态映射；真实 CLI 与 VS Code 扩展加载、权限提示和完整交互仍待验。见[使用指南](kilo-setup.md)。
- 审批审计：已新增本地 append-only JSONL 账本（`~/.xisland/approval-audit.jsonl`），记录批准/拒绝/交回原生/超时/原生已处理/取消、来源、延迟、payload 哈希与前序哈希；审批卡和会话详情显示当前会话最近决定。偏好设置「审批记录」提供最近 500 条全局记录、按决定过滤、按工具/会话/来源搜索、SHA-256 前序链校验、完整 JSONL 导出和 Finder 定位；尚无保留策略/自动轮转/外部 witness，链校验只证明当前文件自洽。
- 拒绝原因：Claude Code 审批卡新增「拒绝并说明」，原因经 Protocol/socket/bridge 写回 `PermissionRequest.decision.message`；空白原因退回普通拒绝，上限 1000 字符，原因不落审计账本。只对 Claude Code 生效，Cursor 仍 deny-only；真实 Claude TUI 的反馈展示未验。
- 修改参数后批准：Claude Code 审批卡新增「修改后批准」，Bash 编辑 `command`，其他工具编辑完整 JSON，经 Protocol/socket/bridge 写回 `PermissionRequest.decision.updatedInput`；修改后的输入仍由 Claude 重新按 deny/ask 规则评估。非法 JSON、NUL、超过 64,000 字节或非对象时保持卡片，不降级为批准原始命令；审计 `payloadHash` 记录实际执行参数。只对 Claude Code 开放，真实 Claude TUI 端到端未验。
- 拒绝并停止本轮：Claude Code 审批卡新增「拒绝并停止」与「拒绝并说明 → 同时停止本轮」，经 Protocol/socket/bridge 写回 `PermissionRequest.decision.interrupt`；官方合同只在 deny 分支读取该字段，allow 绝不携带。它只停止 Claude 当前回合，不承诺终止后台子代理、后台 Bash 任务或已脱离 shell 的进程；其他来源不接受中断并保持卡片。真实 Claude TUI 端到端未验。
- 本会话允许精确 Bash 命令：Claude Code 的 Bash 审批卡新增「本会话允许此命令」，经 Protocol/socket/bridge 写回 `PermissionRequest.decision.updatedPermissions`。岛侧只接受主代理（`originAgentID` 为空）请求，且只接受单条 `addRules`、`behavior=allow`、`destination=session`、`toolName=Bash`、无 `*`/换行、非空且不超过 2,000 字节的精确命令；非 Bash、非 Claude、子代理、非法 JSON 或带持久化 destination 时保持卡片，不降级为普通批准。子代理卡片不显示该入口，避免子代理替父会话扩权。不写 settings 文件、不跨会话、不自动裁决；审计只映射 approved 并保留原始 `toolInput` 哈希，不复制规则正文。真实 Claude TUI 端到端未验。
- 文件改动内联预览：参考 Cline（Apache-2.0）与 Claude Code Manual 模式，`Edit` / `Write` / `MultiEdit` / `NotebookEdit` 审批卡从 `tool_input` 生成只读旧/新行预览，显示 `+N −M`、`replace_all` 和截断提示；请求到达时缓存，不读取目标文件，不改变 allow/deny。`Write` 标注完整写入内容可能覆盖现有文件。限制为 200,000 字节输入、8 个修改块、每侧 12 行、单行 400 字符；没有真实行号、未修改上下文或完整 unified diff。真实 Claude TUI 端到端未验。
- 原生执行回执：已用 Claude `PreToolUse.tool_use_id` + 规范化 `tool_input` 哈希关联 `PermissionRequest`，在对应 `PostToolUse` / `PostToolUseFailure` 到达时精确清卡并记 `nativeResolved`。Claude `Stop` / `SubagentStop` 到达时按 `originAgentID` 兜底清理当前/队列中的 Claude 权限请求，记 `nativeTurnEnded`；不区分允许、拒绝或取消，也不承诺拒绝瞬间清卡。缺失 `tool_use_id`、事件丢失和多子代理歧义仍不自动清卡。

## 候选入口取舍

- **Kilo Code（已接入）**：官方插件在 CLI 与 VS Code 扩展共用，且有公开的 `plugin/` 目录与默认导出契约，具备可验证的本地通道。
- **Roomote**：Roo 团队转向的云端产品，没有经过核实的本地 hooks 或事件文件；不纳入，避免把云 API 只读状态当成本地观察。
- **Zoo Code**：Roo Code 的社区分支，发行渠道与任务 API 尚未按固定版本核对；暂不纳入，等有可复现的本地入口再加。
- **QoderWork / 千问办公**：桌面端合并后的入口没有公开的 hooks 或插件协议；不生成猜测配置。
- **Kilo 的 JetBrains 插件**：与 VS Code 共用部分配置格式，但官方插件文档只声明 CLI 与 VS Code；未验证前不计入覆盖。

## 已有实现仍需完成的验收

| 范围 | 已有证据 | 下一步与限制 |
| --- | --- | --- |
| Claude Code 2.1.234 | 隔离真实读取与岛上拒绝写入通过；ExitPlanMode 计划审查与 allow 回传 `updatedInput` 已有契约/进程验证；关闭后的未决工具保留“完成未确认” | 并发权限队列、子代理来源标记、310 秒审批租约、本地审计账本、Stop 轮次结束清卡、拒绝原因、修改参数后批准、拒绝并停止、本会话精确 Bash 规则与文件改动内联预览已实现并通过单元测试；继续真实并发、允许/取消/超时、真实子代理、执行失败、TUI 与真实服务商；运行中首提示保存已修复，最终发行原生复验另列；缺失调用 ID 的精确拒绝归属仍有限制 |
| Codex | 12 类事件契约；中断、压缩、迟到回合与隐藏恢复已测 | 最终 hooks 需在客户端审阅信任后再验证原生工具与审批，不把只读发现或模拟输入当作原生执行 |
| Cursor | 11 类事件契约；`beforeShellExecution` / `beforeMCPExecution` 的 deny/ask JSON、allow→ask 降级、超时回退与同会话权限队列已过单元/桥进程验证 | 真实 Cursor 版本、多 hooks 组合、文件读取审批与原生问答仍待验；Cursor 宿主只消费 deny/ask，不能把岛上 allow 冒充成原生批准 |
| Kimi Node 2.1.1 | 部分原生生命周期、压缩、拒绝、后台任务与排队场景通过 | 完整任务树、完整回复、通知抑制、自动压缩、岛上控制、真实服务商及旧 Python 入口仍待验；队列取消缺少外部 hook，不能即时修正已观察长度 |
| WorkBuddy | 独立插件导出、固定资源静态核对、合成事件验证；2026-10-27 在 5.9.2 已启用环境完成两轮真实主任务提醒与自动切回验收 | 首次导入与信任、嵌套代理归属、压缩恢复和并发迟到乱序仍待验；当前只观察，不提供权限决定 |
| 其他 CLI / IDE | 各自指定通道的契约、配置或离线进程测试 | 按具体版本验证加载、真实事件、权限、取消、恢复、多窗口与历史；同品牌不同客户端不能共用验收结论 |

## 已修复的实现缺陷

- Claude：新会话和首条用户提示在 Stop 前保存，保存失败可重试。
- Codewhale：子代理真实结果与 failed/cancelled/interrupted/unknown 状态进入历史及导出，失败或取消不再显示成功标识。
- Kiro：接受没有答案正文的 Stop，明确 SessionStart 可恢复同 ID 历史。
- GLM：Pi 补发模型字段，跨客户端保留模型显示、筛选与历史信息。
- 桥接：对端已关闭的 AF_UNIX 短连接上 `SO_RCVTIMEO` 会返回 `EINVAL`，`readFramedMessage` 与 VS Code 观察入口的关闭等待均已改为 `poll` + `MSG_DONTWAIT`，并补 socketpair 回归测试。

厂商未提供的调用身份、控制接口以及不同载体的实机验证继续保留为缺口，不以基础路线完成代替完整验收。

## 全局验收要求

- 配置安装、重复安装、卸载和冲突处理应保留用户已有文件及第三方配置。
- 任务和工具必须按可靠的原生身份关联，迟到事件、重复事件、断线或进程退出不能冒充成功完成。
- 观察通道不得展示无法可靠回传的批准、拒绝或问答能力；需要原生授权的步骤由原客户端处理。
- 发布测试需要对应最终源码和二进制；旧开发构建的测试数字只作历史证据。
- macOS 与 Windows 分别验收，macOS 主机上的构建或浏览器预览不能替代 Windows 目标机器运行。

原始模型请求、运行数据库、客户端输出和本地研究记录保留在维护者的隔离取证目录，不随源码发行；公开摘要保留证据哈希、测试类型、固定版本及未完成范围。
