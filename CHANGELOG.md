# Changelog

## v2.3.4 (2026-11-28)

### 新增

- **Ed25519 更新签名**：新增 `UpdateSecurity` 模块和 `xisland-update-verify` 校验器；更新清单签名覆盖版本、DMG 文件名和 SHA256。
- **发布资产扩展**：每个 Release 同时提供 DMG、`XIsland-<version>.manifest.json` 和 `XIsland-<version>.manifest.sig`，构建时把更新公钥写入 Info.plist。

### 变更

- **恢复应用内更新**：不再强制 ad-hoc 包必须有 Developer ID Team ID；有 Ed25519 清单签名时允许更新，没有清单签名且没有可信 Team ID 时仍 fail closed。
- **双重校验**：更新器下载前先验清单签名，安装脚本在 App 退出后再次验签并复查 DMG SHA256 与 App 版本。

### 修复

- **2.3.0 更新自锁**：2.3.0 自己为 ad-hoc 且没有可信 Team ID，却要求下一版本必须有 Team ID，导致 2.3.0 → 2.3.1+ 的应用内更新被切断；2.3.4 用独立更新公钥替代该信任锚。
- **API 配额耗尽时仍有安装入口**：GitHub 匿名 API 限额用尽后，改用 `releases/latest` 跳转 tag 构造 DMG、manifest 和 `.sig` 下载地址，不再因为没有资产列表而只显示发布页按钮。
- 2.3.4 本身仍需手动安装一次；从 2.3.4 开始后续版本可在应用内更新。

验证：`UpdateSignatureVerifierTests` 覆盖签名、篡改、版本、SHA 和 key ID 负向路径；安装事务与回滚测试保留。详细内容见 [2.3.4 更新说明](docs/releases/2.3.4.md)。

## v2.3.3 (2026-11-28)

### 修复

- **SwiftUI `@State` 名称遮蔽**：`PermissionsSection` 内私有 `enum State` 在 Xcode 16.4 / Swift 6.1 中遮蔽 `@State`；改名为 `PermissionState`，同步更新 `row`、`label(for:)`、`color(for:)` 的签名。
- **Swift 6.1 实验特性依赖**：`QuotaTracker` 的 `isolated deinit` 改为普通 `deinit`，通过已标记 `nonisolated(unsafe)` 的 `timer` 在销毁时 `invalidate()`；不再要求 `-enable-experimental-feature IsolatedDeinit`。正常轮询、额度读取和 UI 行为不变。
- **UI 时间窗口测试偶发失败**：`testSwiftUIRootUpdatesPreserveSuppressedLayersDuringOutgoingAnimation` 在 CI 负载下可能在 6 次 SwiftUI 布局采样完成前就结束动画；将延迟窗口调到 0.24 秒、采样改为 4 次/2 毫秒。`completed == false`、图层身份和“不被 SwiftUI 重绘改写”的断言保持不变。
- 2.3.2 的二进制可运行，但源码在 Swift 6.1 上无法干净编译；2.3.3 用空 scratch 目录重新完整构建并重新出包，不沿用 2.3.2 缓存对象。

验证：干净 release 构建通过（82.69 秒）；全量 2254 项/21 跳过/0 失败（206.06 秒）；GitHub Actions Xcode 16.4 / Swift 6.1.2 的 Build 与 Test 通过。详细内容见 [2.3.3 更新说明](docs/releases/2.3.3.md)。

## v2.3.2 (2026-11-28)

### 新增

- **统一质量门禁**：新增 `Scripts/run-quality-gates.sh`，一条命令串联文档、Swift 安全、循环状态、发布预检和负向测试；`--build` 可追加 release build。
- **文档与发布校验**：Markdown 围栏、仓库内相对链接、发行说明必需章节、VERSION/Cask 一致性、LLM 提示覆盖和 DMG 实际 SHA 均可自动检查。
- **Swift 安全 token 门禁**：扫描 `try!`、`fatalError(`、`as!`，要求例外逐条带同行豁免标记。
- **循环状态控制面校验**：校验 `STATE.md` 的必需字段、状态取值和轮次一致性；GitHub Actions 已接入文档、Swift 安全和循环状态的正负向检查。

### 变更

- 发布说明、质量报告和测试基线统一落在 `docs/engineering-loop/`，后续补丁可按同一流程复现检查。
- `docs.yml` 增加文档、安全和循环状态检查；保留既有发布预检工作流。

### 修复

- **ACP 配置崩溃**：`ACPCustomAgentConfiguration` 不再强制转换 `command`；非字符串输入按非法配置拒绝。
- **SSH 校验崩溃**：`SSHInputValidator` 的正则改为可失败编译；pattern 非法时校验返回 `false` 并抛出 `SSHValidationError`，不会在静态初始化时终止进程。
- **测试 socket 路径崩溃**：`DISocketConfig.socketDir` 对非法测试目录回退到 `/tmp/xi-test-<pid>`；生产路径不变。主进程和 bridge 会得到不同 PID 路径，表现为测试无法连接，而不是提前崩溃。

本补丁不新增或变更 AI 客户端接入，接入矩阵仍为 35 个来源条目、30 个可接入、5 个停用保留历史。签名仍为 ad-hoc，自动更新继续 fail-closed，需手动覆盖安装。

验证：全量 2254 项/21 跳过/0 失败，目标 26 项/0 失败，文档与 Swift 安全门禁通过，DMG 挂载版本为 2.3.2。详细内容、限制与验证边界见 [2.3.2 更新说明](docs/releases/2.3.2.md)。

## v2.3.1 (2026-11-27)

### 新增

- **LLM 接入配置提示库**：新增 33 段可直接复制给本机 LLM Agent 的完整提示，覆盖 30 个可接入来源、5 个停用/合并来源，以及审批图 MCP、VS Code 伴生扩展和 GLM 模型接入。Agent 会先检查版本、备份、打印 diff，只合并 X Island 自己的条目，保留第三方 hooks、MCP、模型、JSONC 注释和凭据。
- **每份专项指南的复制提示**：ACP、Aider/Codewhale、Amazon Q、Cody、Continue、豆包工作、Kilo、Kiro、WorkBuddy、Trae、审批图 MCP 和 VS Code 伴生扩展都在文末增加「复制给 LLM」章节。
- **手动确认边界**：提示明确不自动批准权限、不代替用户确认客户端信任；Codex 的 Review hooks、Trae 的 Hooks 开关、WorkBuddy 的市场导入、豆包工作的连接器创建等步骤仍由用户完成。

### 变更

- `README.md`、`README_zh.md` 和 `docs/compatibility/README.md` 增加提示库入口；接入总览更新日期改为 2026-11-27。
- 文档中的提示要求以真实只读任务验证事件到达 X Island，不以“配置文件存在”作为接通证据。

### 修复

- 本补丁不修改 Swift 运行时代码，不包含运行时修复。

详细内容、限制与验证边界见 [2.3.1 更新说明](docs/releases/2.3.1.md)。

## v2.3.0 (2026-11-27)

### 新增

- **豆包工作接入**：豆包工作没有公开的原生 hooks，新增 `doubao-work-mcp` 连接器入口——在客户端「本地电脑」模式添加 STDIO 自定义连接器后，显式调用 `xisland_activity` 的活动会显示在岛上。仅观察，不接管审批、问答与取消；连接器断开即结束，不推断任务完成。可在设置页准备 `connector.json` 与操作说明。
- **Cursor shell / MCP 审批**：`beforeShellExecution` 与 `beforeMCPExecution` 从固定放行的观察 hook 改为可等待岛上裁决的权限 hook；经本机 Cursor 3.15.6 源码核对，宿主只消费 `deny` / `ask`，因此岛上只提供「拒绝」与「交回原生确认」，不再伪造 `allow` 批准。
- **并发审批队列**：参考 AgentBar 的 request/answer 队列语义，同一会话的多个权限请求不再互相取消；当前请求处理后队列中的下一个自动晋级，队列上限 16，重复/溢出请求交回客户端原生流程。
- **子代理审批归因**：Claude 子代理 `PermissionRequest` 的 `agent_id` 现在随请求进入岛上，审批卡显示「子代理 · agent-id」，请求仍归属父会话；不同子代理的同名工具请求不再被误去重。
- **审批租约**：每个权限请求带 310 秒租约，与 hook 的 300 秒超时对齐；过期当前项和队列项自动清理，未过期项继续晋级，避免 bridge 退出后卡片永久悬挂。
- **审批审计账本**：参考 OpenLeash / gate4ai / open-guardrail 的 decision evidence，新增 `ApprovalAuditStore` 向 `~/.xisland/approval-audit.jsonl` 追加带 SHA-256 前序哈希的决定记录，覆盖批准、拒绝、交回原生、超时、原生已处理和取消。记录只存 `toolInput` 哈希，不复制完整命令；审批卡和会话详情显示当前会话最近决定。
- **全局审批记录页**：参考 Agent Belay / OpenLeash 的审批历史与审计导出，新增偏好设置「审批记录」页，读取最近 500 条全量记录、按决定过滤、按工具/会话/来源搜索，显示 SHA-256 链完整性；支持完整原始 JSONL 导出和 Finder 定位。链校验只证明当前文件自洽，不冒充外部防篡改证据。
- **轮次结束清卡**：参考 AgentBar 的 stop 生命周期，Claude `Stop` / `SubagentStop` 到达时按 `originAgentID` 清理当前与队列中的 Claude 权限请求，审计记 `native_turn_ended`；并发子代理和 Cursor 请求互不误清。它只证明本轮原生提示已关闭，不区分允许、拒绝或取消。
- **原生执行回执清卡**：参考 AgentBar 的 `resolved` 生命周期，用 Claude `PreToolUse` 的 `tool_use_id` 和规范化 `tool_input` 哈希关联无 ID 的 `PermissionRequest`；对应 `PostToolUse` / `PostToolUseFailure` 到达时记 `nativeResolved` 并精确清卡。只允许唯一匹配，歧义和无关工具完成不会误清。
- **超时与放弃回退**：参考 claude-permission-popup，Claude Code/Codex/Qwen/Qoder/Trae 在超时或用户放弃时输出空决策并 exit 0，Cursor 输出 `permission: ask`；无人裁决时绝不静默批准或静默拒绝。
- **Claude 兼容计划审查**：Claude Code、Qwen Code、Qoder CN、Trae 的 `ExitPlanMode` PermissionRequest 映射为计划审查；批准时回传 `updatedInput`，拒绝时回传反馈，避免只显示“允许”却仍弹原生确认。
- **拒绝原因回传**：参考 Claude `PermissionRequest` 官方 `decision.message` 合同与 `jetbrains-cc-gui` 的 deny-with-feedback 链路，Claude Code 审批卡新增「拒绝并说明」内联输入；原因经 `DIMessage.denyMessage`、socket 与 bridge 写回 `decision.message`，空白原因退回普通拒绝，上限 1000 字符且拒绝 NUL。只对 Claude Code 生效；Cursor 无已核实 message 合同，继续 deny-only，不伪造支持；原因不写入本地审计账本。
- **修改参数后批准**：参考 Claude `PermissionRequest` 官方 `decision.updatedInput` 合同与 Agent SDK 的 Approve with changes，Claude Code 审批卡新增「修改后批准」。Bash 只编辑 `command` 并保留 `description` 等字段，其他工具编辑完整 JSON 对象；参数经 `DIMessage.updatedInput`、socket 与 bridge 写入 allow 决策，Claude 执行前仍会重新按 deny/ask 规则评估。非法 JSON、NUL、超过 64,000 UTF-8 字节或非对象时保持卡片，绝不降级为批准原始命令；只对已核实合同的 Claude Code 开放，审计 `payloadHash` 记录实际执行的编辑后参数。真实 TUI 端到端待验。
- **拒绝并停止本轮**：参考 Claude `PermissionRequest` 官方 `decision.interrupt` 合同，Claude Code 审批卡新增「拒绝并停止」与「拒绝并说明 → 同时停止本轮」。`interrupt` 只在 deny 分支写入，allow 分支绝不携带；有意同时使用 `message` 和 `interrupt`。只对 Claude Code 开放，其他来源不接受中断并保持卡片；它只停止 Claude 当前回合，不承诺终止后台子代理、后台 Bash 任务或已脱离 shell 的进程。真实 TUI 端到端待验。
- **本会话允许精确 Bash 命令**：参考 AgentBar / agent-hooks 的 Always Allow 交互，但只做 Claude Code 会话内的显式授权。审批卡新增「本会话允许此命令」，经 `decision.updatedPermissions` 写入一条 `addRules`：`behavior=allow`、`destination=session`、单条 `Bash` 精确命令。命令必须完全相同、无 `*`、无换行、非空且不超过 2,000 字节；非 Bash、非 Claude、子代理请求或非法规则保持卡片，不降级为普通批准。子代理审批卡不显示该入口，避免子代理替父会话扩权。不写 `localSettings` / `projectSettings` / `userSettings`，不跨会话、不自动裁决；审计仍只记原始 `toolInput` 哈希和 approved，不复制规则正文。真实 TUI 端到端待验。
- **文件改动内联预览**：参考 Cline（Apache-2.0）和 Claude Code Desktop/VS Code Manual 模式的“先看 diff 再接受”，`Edit` / `Write` / `MultiEdit` / `NotebookEdit` 审批卡从 `tool_input` 生成只读预览：红色旧行、绿色新行、`+N −M` 计数、`replace_all` 和多修改分块。请求到达时缓存解析结果，不读取目标文件、不改变 allow/deny；`Write` 明确提示展示完整写入内容且可能覆盖现有文件。输入限制为 200,000 字节、8 个修改块、每侧 12 行、单行 400 字符，超出只显示截断预览，完整原文仍在工具参数中。
- **Antigravity 接入**：按官方 hooks 文档写入 `~/.gemini/config/hooks.json` 的命名分组 `xisland`，覆盖 SessionStart / PreInvocation / PreToolUse / PostToolUse / Stop 五类事件。PreToolUse 只返回中性 `allow`，不做岛上审批；Stop 一律标「完成未确认」，因为官方没有 SessionEnd。
- **Kilo Code 接入**：Kilo Code（OpenCode 内核的 VS Code 扩展与 CLI）没有 shell hooks，新增原生全局插件 `~/.config/kilo/plugin/xisland.js`，上报会话、提示、工具、助手文本与等待状态；插件只观察，权限、问答与取消留在 Kilo。设置页自动写入，需重启宿主或重载 VS Code 窗口。
- **更精确的会话跳转**：hook 侧沿父进程树解析控制 TTY，新增 Ghostty、Warp 与 tmux（切换 client/session/window/pane 后聚焦外层标签）适配；Claude Desktop 的 Code/Cowork 用应用自己的 `local_*` 索引换 `claude://` 链接；Claude Code VS Code 仅在已完成状态使用官方会话链接（上游 #65542 尚未修复“已打开且忙碌”会被新建空白对话），VS Code 集成终端由 1.1.0+ 伴生扩展按 tty/pid/唯一 cwd 显示已有终端；其余 IDE 仍为项目级打开，并在 AX 树里只点击唯一匹配的会话行/标签，同名或不可按下时放弃而不是猜。
- **既有插件归属收口**：Kilo 插件进入统一的源归属校验，用户改过的文件在修复/卸载时保留。

### 变更

- **合并与改名后的重新适配**：Windsurf 应用（2026-06-02 更名 Devin Desktop）归入 Devin Desktop；Amazon Q CLI（2025-11-17 更名 Kiro CLI）改走 Kiro；TRAE Work（2026-08-25 并入豆包工作）改走豆包工作；通义灵码更名 Qoder CN。
- **停用入口**：Windsurf、Continue（2026-06 被 Cursor 收购）、Roo Code（2026-05-15 停运）、Amazon Q 旧包装器不再出现在接入列表，类型本身保留以读取历史会话；接入说明指向 Cline / Cursor / Kiro / Devin Desktop 等替代入口。
- **降级保留**：Gemini CLI 只保留企业版与付费 API Key（个人版 2026-06-18 停止）；Cody 保留到 2027-01-31 停止支持；Tabnine 自动配置只覆盖被 Tricentis 收购前的旧版 CLI，6.x 按 OpenCode 分支核对。
- **接入数量**：35 个来源条目中 30 个可接入、5 个已停用保留历史（此前为 34 / 29）。
- **历史库迁移到应用专属目录**：生产历史库从通用 `~/Library/Application Support/default.store` 迁到 `~/Library/Application Support/XIsland/XIsland.store`。启动前用 SQLite 在线备份生成含 WAL 的独立文件，`PRAGMA integrity_check` 通过后原子替换；旧库仅在新库校验成功后删除，迁移失败时保留可读取的旧库。旧 `HistoryBackups` 合并进应用目录，`default.store.pre-*` 恢复点改名为 `XIsland.store.pre-*`。

### 修复

- **测试目标无法编译**：`TaskAttentionBounceTests` 仍断言已移除的 `Pose.rotation`，`TerminalAppDetectionTests` / `SessionJumpRoutingTests` 的 `SessionSnapshot` 缺少 `title`；按当前源码修正后测试目标恢复可编译。
- **Antigravity 应用标识**：`TerminalJumpManager` 原先使用的 `com.antigravity.Antigravity` 与实际安装包 `com.google.antigravity` 不符，已按已核实的 bundle id 修正。
- **AF_UNIX 短连接丢帧**：对端写完即关闭时，macOS 对 `SO_RCVTIMEO` 返回 `EINVAL`；`DIBridge.readFramedMessage` 在读取前就退出，审批响应与观察消息会整帧丢失。改用 `poll` 承担超时并以 `MSG_DONTWAIT` 读取；`VSCodeObservationCommand` 的关闭等待同样去掉该选项，补 socketpair 回归测试。
- **Cursor 权限 hook 被观察模板覆盖**：旧配置把 `beforeShellExecution` / `beforeMCPExecution` 映射为 `preToolUse`，并 `>/dev/null` 丢弃 bridge 输出后固定放行；新配置保留 bridge 的等待与权限 JSON，并只在连接失败时回 `permission: ask`。
- **ExitPlanMode 批准被原生确认覆盖**：PermissionRequest 的 allow 缺少 `updatedInput` 时 Claude Code 会忽略 hook 决定；现按原始 `tool_input` 回传，缺字段时不再假装批准。
- **历史恢复点无上限增长**：启动时按总大小修剪恢复点，默认保留 2GB；最新一份无论多大都保留，其余按修改时间从旧到新删除。SQLite 文件至少 50MB 且 freelist 至少 256 页时才 `VACUUM`，拿不到独占锁则跳过，避免每次启动重写全库。长期未结束的 active / idle / error 会话在超过 `max(保留天数 × 3, 90)` 天后清理，等待交互的会话除外。
- **自动更新只验证签名自洽**：`codesign --verify` 不能区分 ad-hoc 与可信发布。更新包现在必须带 Team ID，且与 Info.plist 的 `XIslandUpdateTeamIdentifier` 或当前运行 App 的 Team ID 一致；没有可信 Team ID 时 fail closed。安装脚本同样执行该校验，不留空守卫绕过路径。发布构建可用 `X_ISLAND_UPDATE_TEAM_ID` 注入可信值。
- **UI 测试与生产 App 冲突**：`test-ui.sh` 默认拒绝在生产 X Island 正在运行时启动，避免两个实例争抢刘海窗口导致超时；仅在显式设置 `X_ISLAND_UI_TEST_ALLOW_RUNNING_APP=1` 时放行。
- **卸载残留清理**：Homebrew Cask zap 增加旧 `default.store*`、旧 `HistoryBackups` 与 `~/Library/Application Support/XIsland`，覆盖迁移前后的路径。

详细内容、限制与验证边界见 [2.3.0 更新说明](docs/releases/2.3.0.md)。

## v2.2.0 (2026-11-21)

### 新增

- **任务摘要（LLM）**：会话完成时用模型归纳「做了什么、改了什么、停在哪一步」，替代原来的「最近工具 + 步数」流水。摘要写入会话记录，标题显示为「摘要」；模型不可用时继续使用事件归纳（标题为「回顾」）。
- **多后端支持**：智谱 GLM-4-Flash、Google Gemini、Groq、OpenRouter（:free）、硅基流动、本地 Ollama、OpenAI、Anthropic。免费项排在前面，摘要只需短文本，小模型足够。
- **API Key 存钥匙串**：在设置内输入并加密保存（`dev.xisland.llm-summary`），不写入偏好文件；云端失败自动回退本地 Ollama，再回退事件归纳。
- **Ollama 引导**：检测「未安装 / 无模型 / 就绪 / 下载中」四态，提供获取入口、一键下载 `qwen2.5:3b`、已安装模型下拉选择，以及 5 个推荐模型。
- **模型驻留设置**：30 秒 / 2 分钟 / 5 分钟 / 一直保留，控制生成后模型在内存中的保留时长（默认 30 秒，用完释放约 2GB）。
- **图标风格**：吉祥物 / 对应软件的真实 Logo / 自定义图片三选一，作用于药丸、卡片与列表图标；自定义图片存 `~/Library/Application Support/XIsland/custom-mascot.png`。
- **手动生成摘要**：右键已完成会话 →「生成摘要」，跳过「已生成过」的去重。

### 变更

- **面板展开期间冻结排序**：状态与活动时间变化不再重排，避免点击瞬间卡片位移导致跳到另一个会话；收起后恢复实时排序。
- **图标动画**：提醒跳动由「上跳 + 旋转」改为整体缩放弹跳（`scale 1 → 1.18`），吉祥物、Logo、自定义图同步生效；非吉祥物模式补充运行中的圆角呼吸光晕。
- **摘要可读性**：正文改用主文本色、11.5pt，标题与图标青色提高到 90%，底色提高到 8%。
- **摘要展开/收起**：作为独立按钮放在卡片底部「继续下一步」左侧，仅当摘要超过 3 行或 120 字时出现；摘要正文恢复 3 行折叠。
- **后台静默回填**：启动 8 秒后开始补齐历史会话（串行、每次最多 20 个、间隔 0.8 秒），此后每 10 分钟一轮；面板展开时只即时补最近 1 个。

### 修复

- **Codex 跳转「Chat unavailable on this computer」**：`codex://threads/<id>` 只对本机存在的 thread 有效；跳转前先查 `~/.codex/session_index.jsonl`，未命中时降级为激活应用并打开项目，不再打开错误页。
- **点击摘要区不跳转**：摘要右下角的展开控件会消费点击且只展开。移除该控件后摘要正文回归整卡跳转，展开按钮改到底部操作行。
- **二次完成不更新摘要**：改为按工具事件数量判断增量，事件增加才重新生成并覆盖；客户端上报摘要（Devin、CodeBuddy）永不覆盖。
- **3B 模型摘要串味**：长提示词 + 示例会让 qwen2.5:3b 把示例当输入。改为短指令 + 同类示例，并在代码层剥掉「第 x 行」标签、缺状态行时自动补齐。

## v2.1.0 (2026-11-19)

### 新增

- 权限页自动刷新：从系统设置切回时立即重新检测，停留在权限页时每 1.5 秒轮询；显示当前运行路径，新增「重置授权」（`tccutil reset`）与「重启应用」。
- 版本更新后自动清理旧授权条目：按「版本号 + 可执行文件修改时间」识别新构建，启动时执行 `tccutil reset Accessibility`，避免旧条目（记录上一版代码哈希）让系统误判已授权；权限页提示「版本已更新，旧授权条目已清理」。
- 客户端内查看后自动标记已查看：切到客户端时读取窗口标题，命中待查看会话标题即标记，不再需要回面板点确认。
- IDE 降级跳转：Trae / Trae CN / TRAE SOLO CN / VS Code / Windsurf / Zed / Antigravity 无会话级 deeplink 时，切换到客户端并打开项目目录；客户端已运行时只切换窗口，不新建。
- 授权浮窗补充备用引导：拖拽无效时可用列表下方 `+` 手动选择 App。

### 变更

- 授权浮窗改为横条：一行说明 + 整条可拖的应用条目，置于系统设置下方居中；拖拽源改为 NSView，首次按下即可拖，取消拖拽不收起浮窗。
- 完成提醒停留规则：提醒计时期间不启用指针离开计时；到期时若指针仍在面板上，交回指针离开计时并遵循设置中的延迟（设为 0 即离开立即收起）。
- 面板排序改为四段式：待审批 → 完成待查看 → 运行中 → 静止，同档按最近活动时间降序。
- Trae 适配路径统一：国内版与国际版的全局 Hook 同为 `~/.trae-cn/hooks.json`（`~/.trae/hooks.json` 是项目级路径）。
- 设置窗口默认 1000×700（最小 900×560），标签栏均分宽度，避免被裁切。

### 修复

- 点击卡片不跳转：跳转按钮只覆盖标题区，摘要与留白点击无响应；改为整卡兜底点击，内部按钮仍优先消费。
- 跳转需点两次：请求不可重入且无任何反馈；改为可重入 + 2.5 秒超时复位 + 即时显示「正在跳转…」。
- 跳转到错误客户端：Trae 系 `forAgent` 固定返回国际版；改为按消息到达瞬间的前台应用识别来源发行版。
- 跳转把窗口搬到当前桌面：移除 `activateAllWindows`，由系统切换到窗口所在 Space。
- Trae 旧配置迁移失败：旧 `stop` 事件参数与当前映射不一致导致整体中止；认领条件改为「命令包含本桥接的 trae agent」。

## v2.0.25 (2026-11-18)

### 修复

- 修复完成提醒展开后过早收起：此前「指针离开」的短计时与提醒的 6 秒计时同时生效，前者先触发。现在提醒计时期间不启用指针离开计时；到期时若指针仍在面板上，收起交回指针离开计时，遵循设置中的延迟（设为 0 即离开立即收起）。

### 变更

- 授权浮窗改为横条样式：一行说明 + 整条可拖动的应用条目，放在系统设置下方居中，空间不足时改放上方。

## v2.0.24 (2026-11-18)

### 新增

- 设置页新增独立「权限」标签：集中展示辅助功能、自动化、通知的状态与授权入口，未授权时也可访问。
- 辅助功能授权浮窗：打开系统设置后在其左侧浮起可拖拽的 App 图标，带目标列表提示与关闭按钮；拖拽取消时保留浮窗，只有真正落入列表才收起。

### 变更

- 设置窗口默认尺寸改为 1000×700，最小 900×560；标签栏改为均分宽度并允许轻微缩放，避免 11 个标签被裁切。
- 通用页的隐私区域改为「权限已集中到『权限』页」提示，可一键前往。

## v2.0.23 (2026-11-17)

### 新增

- 设置页新增集中权限面板：展示辅助功能、自动化、通知的当前状态与授权入口，支持打开对应设置、在 Finder 中定位 App，以及刷新状态。

### 修复

- 修复点击卡片摘要区不跳转：摘要区此前位于跳转按钮之外，现在除独立操作按钮外，整张卡片都可点击跳转。

### 变更

- 构建脚本支持可选的固定签名身份（`CODESIGN_IDENTITY` 环境变量或 `~/.xisland/signing-identity`）；未配置时仍使用 adhoc 签名。
- README 补充辅助功能权限说明：授权方式、更新后需重新授权、未授权时的降级行为。

## v2.0.22 (2026-11-17)

### 新增

- 会话卡片新增「继续下一步」：复制指令、激活对应会话窗口并尝试自动粘贴，卡片内提示按回车发送；未授权辅助功能时提示手动 ⌘V 粘贴，并打开系统设置。
- 完成提醒未查看时，收起态吉祥图每 2.4 秒跳动一次，直到查看或标记已查看。

### 变更

- 卡片徽章融合为单一「Agent · 任务编号 [· 来源]」；来源与类型同名时省略，不再出现两个「WorkBuddy」。
- 提醒展开只受「任务提醒」开关控制：减少动态效果、禁用动画、应用隐藏或岛被切换都不阻止展开；这些设置只影响动效与吉祥图跳动。
- 提醒展示时补充强制置顶，避免应用刚被隐藏或另一个岛刚接管时窗口不可见。
- 移除会话卡片的入场级联、转场与列表布局动画，并撤掉实时高度测量：展开高度只由会话数量与卡片模式决定，展开后不再随内容或动画变长变高。
- 移除面板的指针进入「果冻」缩放（`jellyIntensity` 设置项一并删除）：此前鼠标进入面板会让整体轻微放大，但信息量不变。

### 修复

- 修复悬停时卡片变高：关闭按钮改为常驻占位、只切换透明度；来源徽章与时长固定宽度，不再被挤压成逐字竖排。

## v2.0.21 (2026-11-17)

### 修复

- 移除会话卡片入场时的缩放与上浮，仅保留淡入。`LazyVStack` 的 `onAppear` 会在卡片滚出再进入时重播入场动画，表现为卡片「弹一下」。

## v2.0.20 (2026-11-17)

### 新增

- 会话卡片「仅摘要」模式：隐藏提示词、回复流与工具调用；客户端未上报摘要时，改用「最后活动 + 工具次数 + 用时」的本地紧凑描述。
- 面板默认只显示活跃窗口（最近 24 小时内有对话），可在设置中改为 6/12/24/72 小时或全部；右键会话可「保留在活跃列表」。
- 任务完成与审批默认自动展开面板，可分别关闭；另可选「在所有桌面与全屏应用上强制显示」。
- 完成提醒展开后停留 6 秒自动收起，指针仍在面板上时顺延。

### 修复

- 修复程序化展开被 `expandPending` 守卫丢弃，导致面板停在收起或半展开状态。
- 修复面板高度按每卡 80pt 估算造成的底部内容裁剪；展开高度改为读取列表布局后的真实高度。
- 修复永久授权仍显示离线凭证到期日、被误读为授权即将过期。
- 活跃窗口过滤后列表为空时补充空状态与「显示全部会话」入口。

### 变更

- 移除会话卡片的指针距离抬升（缩放）动画，指针经过不再引起卡片跳动。

## v2.0.19 (2026-11-17)

### 新增

- 会话卡片支持「仅摘要」模式：只保留标题与 AI 摘要，隐藏提示词、回复流与工具调用；没有摘要的会话仍显示完整内容。
- 任务完成、审批/问答/计划审核时可自动展开面板，两者可分别开关。完成与审批默认都会展开。
- 可选「在所有桌面与全屏应用上强制显示」，用于跨 Space 的审批提醒。

### 修复

- 永久授权不再显示离线凭证到期日，避免被误读为授权即将过期。

## v2.0.18 (2026-11-06)

### 新增

- 审批上下文地图新增 Agent 可主动写入的显式任务图：任务、计划步骤、状态和父子关系可在审批前集中查看，并支持逐节点保留、撤回和批注。
- 新增本地 `approval_graph_get` / `approval_graph_write` MCP 工具；写入只生成待确认提案，不授予命令、文件、问答或审批权限。
- 首次启用时统一展示目标客户端、配置路径和完整 MCP 命令；用户确认后自动配置已安装的 Codex、Claude Code、Gemini CLI、Cursor 和 Qwen Code。

### 修复

- 自动配置只维护 X Island 自己的精确条目，保留其他 MCP 服务；用户修改过或同名的条目不会被覆盖或删除。
- 关闭上下文地图、拒绝授权或快速切换开关时会向最终状态收敛，只清理自有条目。
- MCP 是否配置、客户端是否真正加载、hook 是否活动改为独立证据；旧 hook 活动不会再冒充 MCP 已接通。
- 后台自动配置失败会持久显示为“检查失败”，包含目标路径和原因；接入页与设置页的“检查并修复”会重新执行配置，成功后自动清除错误。

### 验证

- X Island 2047 项（21 项条件跳过）、授权核心 31 项（1 项条件跳过）、隔离集成 128 项，均 0 失败。
- Codex、Claude Code（`mimo-v2.6-pro`）和 Cursor Agent 均完成真实 MCP 连接与只读 `approval_graph_get`。Cursor CLI 本次使用显式验收会话；其自身 hook 自动建会话仍需后续验证。
- Gemini CLI、Qwen Code 当前未安装可执行文件，因此没有生成孤儿配置；OpenCode 因 JSONC 和多路径变体继续保持手动接入。

详细内容、限制与下载校验见 [2.0.18 更新说明](docs/releases/2.0.18.md)。

---

## v2.0.17 (2026-11-05)

### 新增

- 审批卡片新增上下文地图，把当前任务、计划、文件变更和待审批请求按组展示；默认只展开待审批，其余分组各显示一行摘要，避免审批面板过长。
- 文件变更按新建、修改、删除分别用绿、橙、红标记，并可从摘要中的计数胶囊按类型筛选。
- 上下文地图会提取权限描述或计划正文中的“原因/范围”，帮助在批准前先确认这次操作的目的与影响范围。
- 任务、计划和文件节点支持“批注”：可生成带有节点引用的提问或调整命令，复制到剪贴板后跳转到对应会话继续处理。
- 每轮任务完成时保存地图快照，展开“较上一轮”可查看文件新增、移除、类型变化和计划标题变化。
- 设置中增加上下文地图开关，默认开启；岛体右键菜单也可快速切换。

### 修复

- 收紧上下文地图默认展开高度，避免原审批卡片被较长的计划列表挤出屏幕。
- 差异明细和超长文件列表改为按需展开，并设置计划、文件和差异的展示上限。
- 批注提交使用修剪后的文本，并在剪贴板写入后再触发会话跳转，空批注无法提交。

### 验证

- 地图、快照差异、筛选和节点批注相关测试与 `SessionJumpRoutingTests` 共 47 项：46 项通过、1 项渲染测试按条件跳过、0 失败。
- 全量 Swift 回归保持通过；既有会话跳转、审批和持久化边界未改变。
- 本地 2.0.17 候选版完成了默认分组、计划组展开、提问/命令两种批注和“较上一轮”差异的界面验证。
- 真实客户端精确跳转仍取决于客户端是否提供稳定的聊天或终端定位；合成会话会按设计提示缺少定位标识。

详细内容和验证边界见 [2.0.17 更新说明](docs/releases/2.0.17.md)。

---

## v2.0.16 (2026-11-04)

### 新增

- 系统通知中心：会话需要审批、完成或出错时在通知中心提醒；可选在通知里直接批准 / 拒绝。该能力默认关闭，开启后仍需请求 ID 精确匹配，过期请求一律忽略。
- 推送与 Webhook：支持 Bark、ntfy、钉钉、飞书、企业微信、Slack、Telegram 与自定义 Webhook。默认仅在锁屏或屏保时推送，正文出本机前脱敏，推送只发文本、不代替审批。
- 不打扰策略：锁屏、屏保、显示器睡眠三态独立判断；支持静默目录、子会话抑制与未读事项追加提醒。审批、提问、计划审核不受静默时段限制。
- 会话生命周期：30 分钟无活动自动隐藏、同一工作目录只保留最近活跃的一条、观察型来源失联时撤销挂起审批。均默认关闭；隐藏只影响显示，不删除会话或历史，搜索时可以找回。
- 一键脱敏诊断包：白名单设置、会话状态与日志尾部打包为 zip，渠道地址、标识与历史正文不进入包内。
- 会话感知防休眠：关闭 / 有工作会话时 / 始终三档，仅阻止系统空闲睡眠，低电量且未接电源时自动暂停。

### 验证

- 新增 46 项自动化检查，覆盖事件判重、跨午夜静默、生命周期边界、脱敏规则与诊断打包；全量测试保持通过。
- 系统级能力（通知权限、IOKit 断言、真实推送送达）在测试隔离环境中禁用，尚未进行真机验证。

### 修复

- 修复了仅安装、未运行的另一个岛仍被当作可切换目标，导致本岛让位后无人接管、用户找不到窗口的问题。现在手势只会切换到正在运行的对端；没有对端运行时不再隐藏，并增加 3 秒兜底恢复。
- 修复了首次启动未开启通知就弹出系统授权框的问题；现在只在用户主动开启通知后才请求权限。
- 修复了授权过期后全局快捷键、通知与防休眠断言仍在运行、而设置页却无法进入的问题；重新激活授权后会恢复。
- 修复了「已完成但尚未查看」的会话在 30 分钟后被自动隐藏、与设置页说明不符的问题。
- 修复了观察型来源只有等待状态、没有可回传请求时，该会话被同工作区规则取代并从列表消失的问题。
- 修复了最后一个工作会话结束、宽限期过后防休眠断言仍被长期持有，导致机器无法空闲睡眠的问题。
- 修复了多条未读事项的追加提醒互相取消、只保留最后一条的问题。
- 修复了同一错误状态反复提醒、以及恢复后第二次出错不再提醒的判重错误。
- 修复了推送标题未脱敏、以及关闭「子会话不提醒」后推送仍被抑制的不一致。
- 修复了声音静默时段读取的键名与设置页写入不一致，导致用户配置从未生效的问题。
- 修复了诊断包中较深目录路径未裁剪的问题；现在只保留末两级。
- 推送请求增加了 10 秒 / 20 秒超时，弱网下不再无限挂起。
- 修复了发行包 Info.plist 缺少本地网络权限声明，可能导致伴端在 macOS 上无法发现同 Wi-Fi 设备的问题。
- 修复了未授权状态下仍可开启系统通知、全局快捷键与防休眠的问题；现在未授权时该页面只读展示并提示需要授权。

### 说明

- 所有新增能力默认关闭，需要在「设置 → 通知与自动化」中显式启用。
- 系统通知依赖 `Bundle.main.bundleIdentifier`，SwiftPM 裸可执行文件不会生效，发行版 `.app` 才可用。
- 需要资金或外部条件的 B 类事项（签名公证、真机伴端、Android、App Store 沙箱版等）见 [未来待办](docs/plans/future-backlog-paid.md)；实现边界与已知限制见 [A 类实现说明](docs/plans/a-suite-2026-11-04.md)。

---

## v2.0.15 (2026-10-27)

- 修复了授权到期后，排队中的审批、问题和计划请求仍可能出现或被自动答复的问题。
- 修复了停止授权检查后，迟到的激活或刷新结果仍更新状态的问题。
- 修复了服务器明确撤销或完成解绑后，本机保存异常仍可能保留可用状态的问题。
- 改善了临时凭证存储异常恢复后的重试，并修复了旧错误残留或覆盖新激活提示的问题。
- 统一了“一个月、一年、永久”的期限名称和“激活码”文案，试用期间不再显示解绑入口。

本版保留了 14 天试用、最多 3 台设备和最长 7 天离线使用规则；升级无需清空设置或历史。详细说明见 [2.0.15 更新说明](docs/releases/2.0.15.md)。

---

## v2.0.14 (2026-10-27)

### 修复

- 修复了 WorkBuddy 已完成任务仍显示为空闲、没有待查看提示和自动切回提醒的问题。
- 恢复了同一 WorkBuddy 聊天连续多轮任务的完成提醒，下一轮完成后会重新标记为未查看。
- 保留了任务回复正文，并避免重复完成事件再次提醒或把已查看结果重新变为未查看。
- 保持了取消、中断、失败、子代理结束和普通 Stop 与成功完成的区别，避免误报成功。

### 验证

- 完成了 1850 项自动化检查（21 项条件跳过、0 失败）、11 类插件命令验证和两轮 WorkBuddy 5.9.2 真实任务的自动切回验收。

详细表现、升级方法与验证范围见 [2.0.14 更新说明](docs/releases/2.0.14.md)。本次仅更新 macOS XIsland；未改变授权规则、Windows 适配器或 XNook。

---

## v2.0.13 (2026-10-27)

- 新增了 14 天完整试用，以及月付、年付和永久激活入口。
- 为每份产品授权增加了最多 3 台设备的限制，并支持在软件内或网站账户页解绑换机。
- 增加了最长 7 天的离线使用期限，且不会超过试用或订阅的到期时间。
- 在授权到期后停止了主要监控功能，同时保留购买、激活、历史导出和已有数据。
- 为既有购买保留了原授权权益，可使用原购买邮箱登录网站获取对应的软件激活码。
- 修复了时间误设后无法恢复核验、以及快速锁定后重新激活时接入刷新丢失的问题。

详细授权规则、升级步骤和验证范围见 [2.0.13 更新说明](docs/releases/2.0.13.md)。本版保留了 2.0.12 的任务提醒、统一自动收起、连续双岛切换和编译兼容修复。

---

## v2.0.12 (2026-10-27)

### 新增

- 新增了默认开启的任务提醒，支持完成后切回 X Island 并用吉祥物双跳提醒，以及审批、提问和计划审阅时自动展开。
- 在展开面板、右键菜单和设置中增加了统一的提醒开关，打开详情或成功主动跳转后才确认完成结果已查看。
- 增加了与 X Nook 1.3.24 配套的连续双页预览，双指拖动时露出另一页，松手切换或回弹。

### 变更与修复

- 将三种自动收起延迟统一为独立开关和一个 0–600 秒延迟，0 秒改为移出后立即开始动画，并保留内部悬停、重入取消和待处理保护。
- 为旧设置增加了明确迁移规则，沿用已保存的主延迟、保留普通移出关闭意图，并避免新版选择被重复覆盖。
- 改进了不同尺寸岛的连续形变、反向拖动与回弹，修复了松手后旧岛闪回和重复滑入的问题。
- 修复了背景分层后的果冻动画插值问题，以及提醒与过时切换请求竞争显示权的问题。
- 合并了集中到达的提醒、过滤了过期和重复请求，并优先显示待处理交互及未查看完成任务。
- 修复了提醒后的多屏锚定与全屏隐藏恢复，并移除了审批处理后不必要的自动返回 X Nook。

### 内部

- 改善了较旧 Swift 编译器兼容性，并补充状态、迁移、跨进程交接及原生控件验证，完整回归为 1817 项、1799 通过、18 条件跳过、0 失败。

详细变化、迁移规则、配套版本及待验收项见 [2.0.12 更新说明](docs/releases/2.0.12.md)；真实鼠标、双指半程效果、真实任务触发提醒和实际 FPS 不计作已完成验收。

---

## v2.0.11 (2026-10-25)

- 移除了吉祥物右下角的任务编号，让小尺寸图标保持清晰。
- 移除了无刘海遮挡布局中吉祥物旁的 `+N` 溢出数量，更多任务仍可从展开列表查看。
- 保留了同一聊天的固定配色、各客户端造型、状态表情和右上角状态角标。
- 更新了中、英、韩、日、法五种语言的吉祥物图例，说明如何通过造型、配色和状态识别任务。

详细变化、升级说明和验证范围见 [2.0.11 更新说明](docs/releases/2.0.11.md)；折叠任务数量设置、活跃／总会话计数、任务历史和查看确认行为继续沿用。

---

## v2.0.10 (2026-10-24)

### 会话跳转

- 为 Codex、Cursor 和 WorkBuddy 本地会话接入了原生聊天链接，点击任务时携带明确的会话 ID。
- 为 iTerm2、Terminal、WezTerm 和 kitty 改用了明确的会话、标签或分屏标识，不再根据目录名、前台窗口或仅激活应用推断成功。
- 为子任务沿用了父会话的完整来源信息，缺少定位标识、目标已关闭或暂不支持精确跳转时显示原因。
- 修复了跳转尚未完成就收起面板或清除“完成未查看”的问题，旧回调不会确认新一轮完成结果。
- 增加了终端定位符校验、权限错误反馈和执行超时处理，不再把命令启动当作成功。

### 悬停与收起

- 修复了鼠标静止停在展开面板时仍自动收起的问题，指针在面板或岛内时保持展开。
- 修复了长时间悬停后移出立即收起的问题，倒计时现在从离开面板和岛的时刻开始。
- 重新进入后取消了旧倒计时，再次离开时重新完整计时，并清理了隐藏、重开和设置变化时的旧状态。
- 保留了三项现有延时设置，按当前适用的最短正值处理，并更新了说明文案。

详细支持范围、升级说明和验收边界见 [2.0.10 更新说明](docs/releases/2.0.10.md)。本次为 macOS 更新；原生客户端最终页面切换仍需逐项实测，不能把路由测试等同全部实机通过。

---

## v2.0.9 (2026-10-24)

- 修复了 Codex 确认问题后，内部回复标签被显示成聊天标题的问题，改为展示实际答案。
- 修复了旧桥接与历史记录的标题显示，保留原始历史内容，无需迁移或清空数据库。
- 避免了空或损坏的结构化回复覆盖已有有效标题，并保留普通文字、XML、代码示例和其他客户端消息。
- 同步了 Windows 标题解析逻辑，新增了 26 项回归，并补充了桥接到隔离 App 的持久化验证。

详细内容和升级说明见 [2.0.9 更新说明](docs/releases/2.0.9.md)，验证范围见 [发行验证摘要](docs/compatibility/release-verification-2.0.9.json)。

---

## v2.0.8 (2026-10-24)

- 为31个已支持客户端增加了独立吉祥物轮廓，现有圆角机器人仅用于Codex。
- 为不同聊天／任务标签页分配了固定配色和编号，状态变化、重排及重启不再混淆任务身份。
- 用表情和常驻角标区分了运行、等待授权、等待回答、计划审查、错误和完成未查看等状态。
- 新增了完成未查看记录，主动跳转、查看详情或显式确认后清除，展开列表和悬停不会清除。
- 在历史列表和JSON导出中保留了查看标记，并防止旧历史行确认新一轮结果。
- 在设置中增加了吉祥物识别图例，改善了浅色对比、卡片标签布局与减弱动画下的状态辨识。
- 为历史库追加了可选查看字段，并增加了本次升级前的独立备份恢复点。

详细内容、效果预览与升级说明见 [2.0.8 更新说明](docs/releases/2.0.8.md)，验证范围见 [发行验证摘要](docs/compatibility/release-verification-2.0.8.json)。

---

## v2.0.7 (2026-10-23)

- 修复了连接关闭后重复归还配额的问题，避免并发连接计数低估。
- 为完整消息增加了 10 秒总读取时限，拒绝超时残帧，避免慢速分片持续占用连接。
- 将 Roo Code／PearAI 的 VS Code 配套扩展改为经过原生桥接投递，保持正式连接身份检查。
- 为观察入口增加了来源、序号、会话与父子身份校验，拒绝缺身份及审批类消息。
- 保留了观察队列的顺序、过期清理、流式合并、多窗口隔离与崩溃租约处理。
- 配套扩展升至 1.0.1，需与 X Island 2.0.7 或更新版本配合使用。
- 补齐了不绕过生产认证的隔离检查，并修复了测试脚本依赖旧日志及诊断路径别名的问题。

详细内容和升级步骤见 [2.0.7 更新说明](docs/releases/2.0.7.md)，验证范围见 [发行验证摘要](docs/compatibility/release-verification-2.0.7.json)。

---

## v2.0.6 (2026-10-23)

本次集中加固更新通道与本地连接的安全性，并改善展开／收起的动效手感。

### 安全加固

- 更新通道新增发布者身份校验：安装前校验下载包的签名身份，下载来源收窄为官方仓库域名。
- 本地连接新增对端进程身份校验，拒绝非既定调用链的连接，并检测桥接程序是否被篡改。
- 本地连接增加并发上限、读取超时与交互式连接空闲超时，避免连接堆积导致面板无响应。
- 桥接工具改为内容校验自愈，被篡改后可自动重建；相关目录权限收紧为仅本人可访问。
- 终端跳转的外部命令改为受控环境变量，并统一转义特殊字符。

> 本地连接校验在开发过程中曾出现两处会导致面板完全失联的缺陷，均已在发布前修复，详见下方「发布前修复」。

### 发布前修复

- 修复对端身份校验误用系统常量导致所有连接被拒的问题：原先按 `0x005` 读取对端 UID，而该值在 macOS 上实为 `LOCAL_PEEREUUID`，取到的是对端 UUID 前 4 字节，与真实 UID 永不相等。改为使用 `getpeereid` 读取。
- 修复对端已退出时被误判为不可信的问题：非交互 hook 的桥接程序写入后立即退出，服务端取不到其 PID 与可执行路径，原逻辑会因此关闭连接，导致所有非交互事件无法送达。现在路径不可得时按 UID 放行。
- 上述两项均补充了回归测试，并新增对端身份读取的端到端校验（合成生命周期事件 → 包内桥接 → 隔离应用）。

### 测试基础设施修复

- 修复集成测试脚本 `Scripts/test.sh` 长期失效的问题：它的断言依赖 `~/.xisland/debug.log`，而该文件日志在 v1.6.1 已改为系统统一日志、不再落盘，导致脚本自那时起无法通过。现改为在隔离实例上运行，断言来源为结构化诊断快照与隔离数据库，19 个模块全部恢复可用。
- 集成测试不再重启、也不触碰用户正在使用的 X Island：改为拉起独立实例（独立运行时目录、独立偏好域、独立 socket），测试结束自动回收。
- 修正脚本中残留的旧偏好域名，避免测试写入与生产相同的偏好位置。

### 动效与交互

- 修正展开／收起的动效取向：展开保留明显回弹，收起干脆落定。此前两者取向相反。
- 新增收起看门狗：收起动画若未能正常收尾，约 1 秒内自动复位，避免面板卡住无法操作。
- 新增触觉反馈，覆盖授权审批、失败、等待输入、展开收起与任务切换，可在设置中关闭或调整档位。
- 新增待处理卡片跳转按钮的脉动提示与工具完成的弹跳反馈。
- 新增列表入场级联，卡片依次上浮出现。

详细内容见 [2.0.6 更新说明](docs/releases/2.0.6.md)，验证范围见 [发行验证摘要](docs/compatibility/release-verification-2.0.6.json)。本次为 macOS 更新。

---

## v2.0.5 (2026-10-23)

- 新增了“最近任务数量”设置，收起状态可显示或轮换最近 1–5 个任务，默认 3 个。
- 优先展示实际待处理请求，其余任务按最近活动排序，多余任务以“+N”汇总，展开列表和任务总数保持完整。
- 保存了图标数量选择，关闭图标时保留设置，并处理了越界偏好值。
- 补齐了两种收起布局、原生数量控件及现有五种语言的说明。

详细内容见 [2.0.5 更新说明](docs/releases/2.0.5.md)，验证范围见 [发行验证摘要](docs/compatibility/release-verification-2.0.5.json)。本次为 macOS 更新。

---

## v2.0.4 (2026-10-22)

- 修复了切换到未运行的 XNook 时缺少可靠启动与显示确认的问题，现在会先打开目标，再在岛体出现后隐藏当前岛。
- 增加了启动失败、目标缺失和 8 秒超时的恢复处理，避免切换失败后失去当前界面。
- 修复了重复手势、迟到的显示／隐藏通知以及旧全屏检查覆盖新切换的问题。
- 修复了首次运行和默认 URL 处理器不一致时，联动按钮被错误禁用或打开其他应用副本的问题。
- 修复了把对方设置窗口误认为岛体的问题，并根据窗口实际可见性处理启动显示。
- 补齐了启动早期显示请求的保留和新切换期间的保护，改善连续来回切换的稳定性。

建议与 XNook 1.3.18 配套更新；双向冷启动、双向已运行切换均已实机通过。详细内容见 [2.0.4 更新说明](docs/releases/2.0.4.md)，范围见 [发行验证摘要](docs/compatibility/release-verification-2.0.4.json)。

---

## v2.0.3 (2026-10-22)

- 在设置页的 Codex 待授权状态下新增了操作提示与“查看授权步骤”入口，明确启用接入仍需在 Codex 确认信任。
- 将 Codex 的审查、批量确认和接通验证步骤改为默认可见，并补齐中英文提示。
- 修复了“查看授权步骤”只打开总列表的问题，复用窗口时也能定位 Codex 并展开其当前分组。
- 为客户端缺失或启动失败增加了明确提示与重试保护，避免按钮静默失败或意外跳到网页。
- 修复了重复打开客户端及迟到结果干扰新操作的问题，关闭窗口或重新检查后会清除旧反馈。

详细内容见 [2.0.3 更新说明](docs/releases/2.0.3.md)，验证范围见 [发行验证摘要](docs/compatibility/release-verification-2.0.3.json)。本次只更新 macOS，客户端信任仍由用户在原软件中确认。

---

## v2.0.2 (2026-10-20)

本次集中改善大历史库、长会话和后台保存体验，并补齐审批、配置及更新失败时的数据保护。

### 新增

- 新增了每页 100 条的历史分页和全库搜索，支持提示词、路径、客户端名称、模型与会话 ID。
- 新增了完整历史 JSON 导出、实际导出数量和 Finder 定位入口，不受分页或搜索条件限制。
- 补齐了历史保留期的启动与每小时维护，保留未完成会话及“永不清理”设置。

### 性能与界面

- 将历史查询、统计、导出、清理及接入扫描移到了后台，并通过代次和取消保护避免旧结果覆盖新操作。
- 将生产保存改为串行后台事务和增量子记录更新，保存失败时保留会话并支持重试。
- 优化了最近活动缓存和鼠标轮询，隐藏时暂停、闲置时降频，保留果冻动画与减少动态效果设置。
- 修复了短审批面板按钮需要额外滚动的问题，并统一了内容高度、目标尺寸与动画缓存。
- 补齐了空闲客户端图标回退和无障碍标签，统一了设置入口及快捷键行为。

### 可靠性修复

- 修复了统计被前 5,000 条历史截断、镜像跨批次重复计数，以及删除末页后停留在无效页的问题。
- 为历史、统计和导出失败增加了明确提示与重试，避免将失败显示为空库或成功。
- 修复了审批摘要遮蔽实际命令的问题，并保留完整原始参数。
- 严格识别了 Claude 内置问答工具，移除了按相似问题文本自动复用旧答案的行为。
- 增加了审批发送反馈、重复点击保护及退出前在途审批与写入等待，保存失败时取消退出。
- 加强了配置备份、冲突检查和插件归属校验，保留用户修改，并明确拒绝误写非默认 Codex 配置目录。
- 加强了图形与 CLI 更新的校验和失败回滚，并区分了余额、已用 Token、API 可访问性及未知额度。
- 修复了历史保存失败取消退出后更新安装器仍在后台等待的问题，并防止重复更新与普通退出抢占安装准备。
- 停止了通过自动发送模型生成请求来探测额度的行为，并修复了终端宿主标识缺失的跳转边界。
- 修复了较旧 Swift 工具链的统计模块编译问题，并补齐了 Windows 原生运行下的路径、文件锁与取消连接测试。

详细内容见 [2.0.2 更新说明](docs/releases/2.0.2.md)，验证范围见 [发行验证摘要](docs/compatibility/release-verification-2.0.2.json)。本次提供 macOS arm64 安装包，Windows 修复仅随源码同步；VoiceOver 实际朗读、实际 FPS 和外接多屏保持待验。固定存储版 8 小时长稳通过不等于最终 GUI 整版长稳或全部客户端实机验收。

---

## v2.0.1 (2026-10-17)

- 新增了统一的“软件接入与授权”窗口，自动检测已安装的软件并准备支持的配置。
- 新增了 Codex 信任状态检查与原客户端授权指引，区分待配置、待授权、等待活动和已接入。
- 新增了 WorkBuddy 插件与 Kiro V3 接入文件的自动准备和界面取用入口。
- 保存了当前配置的提醒与接通记录，避免每次启动重复配置或弹窗。
- 修复了检查中关闭窗口后重复提醒、切换开关后状态未刷新，以及检查期间短任务活动漏记的问题。
- 支持成功配置被客户端重写后的自动修复，并保留用户修改过的接入文件。

信任仍由用户在原客户端确认；“已接入”表示收到当前配置的有效活动，不代表完整客户端验收。范围见[接入说明](docs/compatibility/README.md)，构建与验证见[2.0.1 验证摘要](docs/compatibility/release-verification-2.0.1.json)。本次只发布 macOS 更新。

---

## v2.0.0 (2026-10-16)

- 补齐了 Kiro CLI 2.31.0 V3 的观察配置导出、合并与移除，修复了无答案正文的 Stop 事件和同会话恢复。
- 增加了 GLM 在 Claude Code、OpenCode、Cline、Pi 中的模型显示、跨客户端筛选、搜索与历史保存。
- 增加了 WorkBuddy 独立观察插件、Roo Code / PearAI 配套扩展，以及多款 CLI 与外部 ACP Agent 的专用接入。
- 完善了 Codex 的中断、压缩与回合身份处理，以及 Kimi 新版客户端的后台任务、排队和恢复跟踪。
- 修复了过早显示完成、关闭后仍显示运行、迟到事件覆盖新回合及历史记录错配的问题。
- 修复了 Claude 会话和首条提示未及时保存，以及 Codewhale 子代理真实结果、失败和取消状态丢失的问题。
- 完善了多问题、自定义答案、多选答案及中文分片处理，并简化空闲状态展示。

31 项基础路线的固定范围及验证层级见[适配矩阵](docs/compatibility/README.md)。完整客户端验收仍在推进，观察型入口不提供原生审批控制；本版本不宣称所有客户端、版本及服务商全部兼容。Windows 保持独立的 0.1.3 预览版。

---

## v1.13.1 (2026-09-16)

- 补齐了内联计划的全文阅读和反馈输入，权限请求可展开完整说明、路径及文件改动。
- 修复了同类 Agent 的独立请求可能挂到错误会话、迟到操作重新激活会话，以及问题选项变化后复用旧答案的问题。
- 增加了审批发送超时与失败反馈，避免将断开的响应通道误报为提交成功。
- 修复了多项审批完成后无法恢复 xnook 显示的问题，并移除了普通列表中的重复待办卡片。
- 修复了历史记录追加保存遗漏、工具结果未更新和新一轮回答覆盖上一轮回答的问题。
- 增加了历史格式升级前的一致性备份，保存失败的会话会保留并提供重试入口。
- 统一了系统与应用的减少动态效果设置，短文本和零速度不再持续驱动跑马灯刷新。
- 统一了两种折叠布局的活跃/总计轮换，并完善了测试隔离和回归覆盖。

历史备份与恢复说明见 [历史数据恢复](docs/history-recovery.md)。本版本不包含后台周期快照、历史全文搜索或完整性能基线工程。

---

## v1.13.0 (2026-08-14)

- 适配市面主流 AI 编程工具：新增 Roo Code、PearAI、Zed AI、JetBrains AI 支持；将 Windsurf 从 Cursor 中拆分为独立工具。
- 更新 README / README_zh 支持矩阵，补充 Trae CN、Qwen Code、Amp、Pi Agent、Copilot CLI、Cline、Continue、Cody、Tabnine、Amazon Q Developer、Devin、Qoder、Roo Code、PearAI、Zed、JetBrains AI 等工具的接入方式。
- 修复多显示器/多桌面（Spaces）场景下，显示审批面板时可能误判"当前主界面"所在屏幕，导致面板在错误的屏幕/桌面展开的问题；现在审批时会在用户当前正在使用的主界面所在屏幕展开面板。

---

## v1.12.0 (2026-08-01)

- 灵动岛高度无极调节：收起态药丸高度可自由调节，并新增 AppStorageSlider 组件。
- 更新 Cask 安装包版本号与校验和。

---

## v1.11.0 (2026-07-16)

- 新增任务审批置顶功能：当有权限请求、计划审查或问题询问时，自动展开并置顶显示灵动岛，即使 xnook 在前台也会优先显示。
- 审批完成后自动切换回 xnook 的灵动岛，无需手动操作。
- 支持快速连续审批场景，使用计数器防止状态竞态。
- 交互被外部清除时自动重置中断标志，防止误触发恢复。

---

## v1.10.2 (2026-07-15)

- 灵动岛面板顶部不再留空：窗口顶边向上延伸 6px 越出屏幕顶端，消除 1px 缝隙和抗锯齿偏差。
- 面板从上往下展开，顶边固定锚在屏幕外，高度变化只向下生长，视觉更稳定。
- 收起态、拖动、多屏切换、展开/收起动画均统一使用越界机制，避免顶边抖动。

---

## v1.10.1 (2026-07-15)

- 修复点击 Trae 权限审批“允许执行”后 X Island 可能被系统直接终止的问题。
- 审批、问题回答和方案确认写回已断开的 Unix socket 时不再触发 `SIGPIPE`。
- 增加断连写回回归测试，确保对端提前退出时应用仍保持运行。

---

## v1.10.0 (2026-07-14)

本版新增 **Agent Flow 项目视图**，并扩展 Trae 系列客户端支持，让 Codex、Trae、Trae CN 与 TRAE SOLO CN 的会话状态、人工阻塞和审批请求可以在 X Island 中统一呈现和处理。

### Agent Flow

- 新增按项目聚合的 Agent Flow 视图，统一展示项目中的活跃会话、运行状态和阻塞原因。
- 区分等待用户回答、等待方案确认、等待权限审批和工具失败等阻塞类型，便于快速定位需要人工介入的会话。
- 支持未分组会话和多语言阻塞文案，并补充聚合逻辑与视图测试。

### Trae 与审批

- 新增 Trae、Trae CN 和 TRAE SOLO CN 的应用识别、前台检测、终端跳转与设置页展示。
- Trae 权限请求接入 DIBridge 审批响应，可直接在灵动岛中允许或拒绝操作。
- TRAE SOLO CN 使用已确认的 IDE `claudeCode.hooks` 设置路径，避免写入未经验证的配置文件。

### 稳定性

- 修复 DIBridge 与 SocketServer 大消息测试中的同步读写阻塞。
- 修正应用切换、更新校验和测试 fixture，覆盖当前 URL Scheme 与安全校验约定。
- 将 `.codegraph/daemon.pid` 作为本机运行态文件忽略，避免污染版本历史。

---

## v1.9.0 (2026-07-05)

本版为 **双岛联动、收起态信息与动效控制** 版本。相对 v1.8.0，X Island 从“能切换”继续推进到“切得准、启动不重叠、收起态更有信息密度、动画和显示更可调”，同时把应用图标、浅色模式、终端跳转和更新入口也一并收口。

### 与 v1.8.0 对比

| 维度 | v1.8.0 | v1.9.0 |
|------|--------|--------|
| **双岛切换** | 具备基础 URL Scheme 与横滑能力 | 新增启动显示仲裁、收起态独占响应、对方应用状态检查、切换测试入口 |
| **收起态信息** | 内容较固定 | 新增收起态模块开关、活动跑马灯速度与内容模式（活动 / 项目 / 自动轮换） |
| **交互动画** | 动效强度基本固定 | 新增展开动画强度三档、果冻动画强度三档、磁吸偏移与悬停果冻效果 |
| **展开方式** | 主要依赖点击 / 旧交互 | 新增仅收起态生效的双指下滑展开，避免和展开内容滚动冲突 |
| **显示与维护** | 图标与浅色模式、终端跳转仍有打磨空间 | 更新应用图标，优化浅色模式观感，修复终端跳转与联动边界问题 |

### 联动与启动仲裁

- 双指左右滑动切换继续保留，但现在只会由 **当前收起态最上层的灵动岛** 响应，减少两个岛同时监听带来的误切。
- 新增 **启动时显示** 偏好，可在“上次使用 / XNook / X Island”之间选择，解决两个应用开机同时显示时的重叠问题。
- 设置页新增 **联动面板**，可查看对方应用是否已安装、是否运行、URL Scheme / 协议是否就绪，并直接执行“立即切换测试”。
- 切换时的跨进程显示协议进一步收口，避免只是激活目标应用、却没有隐藏当前灵动岛而导致双层窗口重叠。

### 收起态显示与跑马灯

- 新增 **收起态模块开关**，可分别控制 Agent 图标、会话数量和额度摘要是否显示。
- 活动跑马灯新增 **内容模式**：支持显示活动状态、项目名，或在二者之间自动轮换。
- 跑马灯仍保留速度调节，但现在项目模式会优先显示工作区名，而不是把长路径直接塞进一条窄 ticker 里。
- 收起态整体更偏“信息密度可调”，而不是固定模板。

### 交互、动效与主题

- 新增 **双指下滑展开** 开关，而且只在灵动岛收起时响应，避免和展开面板内的横向或内容滚动冲突。
- 展开 / 收起动效新增 **低 / 中 / 高** 三档强度，并会在开启“减少动画”时自动降到最轻。
- 悬停果冻动画新增独立三档强度，参数和 XNook 对齐；同时加入磁吸偏移，让收起态在鼠标从下方进入时更有弹性。
- 设置页与窗口层接入主题管理，浅色模式显示进一步打磨，系统 / 浅色 / 深色切换更完整。

### 图标、更新与质量

- 应用图标更新为新的正式版本，并同步到了构建产物中。
- 终端跳转链路修复后，更适合把灵动岛作为命令流和会话流的快速入口。
- 应用内更新区域继续保留，版本显示与安装入口更清晰；本次同时把构建脚本和打包默认版本号推进到 `1.9.0`。
- 为联动、窗口归属、问题响应、更新状态、Socket 接入和收起态逻辑补充测试，降低后续继续扩展时的回归风险。

---

## v1.6.1 (2026-05-17)

本版为 **性能优化与 UX 打磨** 版本，在 v1.6.0 安全审计修复基础上，针对主线程阻塞、重复计算、CPU 空转等问题进行 6 项手术式优化。

### 与 v1.6.0 对比

| 维度 | v1.6.0 | v1.6.1 |
|------|--------|--------|
| **Socket 日志** | `diLog()` 同步文件 I/O（每次分配 ISO8601DateFormatter + 打开/关闭文件），4 个调用点在 MainActor | `os.Logger` 异步系统日志，零文件 I/O |
| **MarkdownView** | `parseBlocks()` 计算属性，每次 SwiftUI body 重算都重新解析；ForEach 用 offset 做 id | 解析结果缓存为 `let`，init 时一次性计算；`Block: Hashable` + `ForEach(\.self)` |
| **NotchWindow Timer** | 鼠标跟踪 Timer 在 `init()` 创建后永不停止（即使窗口隐藏） | `pauseMouseTracking()` / `resumeMouseTracking()` 按可见性开关；`followMouseIfScreenChanged` 更新共享屏幕缓存 |
| **SessionManager 查找** | 12+ 个方法做 `sessions.first(where:)` O(n) 线性扫描 | `[String: Int]` 字典索引 O(1) 查找 + `suffixCache` 缓存 mirrored 后缀 |
| **QuotaTracker SQLite** | `fetchOpenAI()` 在 MainActor 同步执行 `sqlite3_open_v2` / `sqlite3_step` | `nonisolated static` + `Task.detached(priority: .utility)` 后台执行 |
| **无障碍** | 展开头部 3 个按钮无 `accessibilityLabel` | 静音/设置/关闭按钮添加标签 |
| **AppUpdater** | 安装脚本无 codesign 校验，临时目录手动清理 | `codesign --verify --deep --strict` + `trap` 自动清理 |

### 优化详情

#### SocketServer diLog → os.Logger

**问题**：`diLog()` 每次调用创建 `ISO8601DateFormatter`、打开/写入/关闭 `~/.xisland/debug.log`。8 个调用点中 4 个在 `Task { @MainActor in }` 块内，阻塞主线程。

**修复**：删除 `diLog` 函数，替换为 `Logger(subsystem: "dev.xisland", category: "socket")`。`os.Logger` 底层使用 `os_log`，异步且系统管理。

#### MarkdownView parseBlocks() 缓存

**问题**：`blocks` 是计算属性，每次 SwiftUI 重绘都重新解析 markdown。ForEach 用 `\.offset` 做 id，块插入/删除时全量重建。

**修复**：
- `Block` 枚举添加 `: Hashable`（关联值全是 String/Int，自动合成）
- `blocks` 改为 `let` 存储属性，在 `init` 中一次性计算
- `parseBlocks` 改为 `static func`
- ForEach 改用 `ForEach(blocks, id: \.self)`

#### NotchWindow Timer 生命周期

**问题**：`Timer.scheduledTimer(withTimeInterval: 0.5)` 在 `init()` 创建后永不停止。`followMouseIfScreenChanged()` 独立遍历 `NSScreen.screens`，未使用已有的 `cachedOrRefreshScreen()` 缓存。

**修复**：
- 添加 `pauseMouseTracking()` / `resumeMouseTracking()`
- `activeSpaceDidChange` 中 `orderOut` 时暂停、`orderFrontRegardless` 时恢复
- `followMouseIfScreenChanged` 检测到屏幕切换时更新 `cachedBestScreen`

#### SessionManager 字典索引

**问题**：`sessions` 是数组，12+ 个方法做 `sessions.first(where:)` O(n) 查找。`findOrCreateSession` 链式 3-4 次线性扫描。`mirroredSessionSuffix` 字符串解析重复执行。

**修复**：
- 新增 `sessionIndex: [String: Int]`（ID → 下标）+ `suffixCache: [String: String]`
- 3 个变更点（`createNewSession`、`dismissSession`、`cleanupLingeredSessions`）维护索引
- `sessionById` / `activeSessionById` 改为 O(1) 字典查找，带 stale 检测自动重建

#### QuotaTracker SQLite 后台化

**问题**：`fetchOpenAI()` 在 MainActor 执行 SQLite I/O。

**修复**：提取 `nonisolated static func fetchOpenAITokenCount()`，`fetchOpenAI()` 用 `Task.detached(priority: .utility)` 调用。

### 验证

- `swift build`: 编译通过
- `swift test`: 213 tests, 0 failures
- 改动范围：9 个文件，+110/-51 行

---

## v1.6.0 (2026-05-17)

本版为**安全审计驱动的重大修复版本**，基于约 100 个审视角度的全面审查，修复 2 个 Critical 安全漏洞、4 个 High 级问题，并完成多项可维护性与工程化改进。

### 与 v1.5.2 对比

| 维度 | v1.5.2 | v1.6.0 |
|------|--------|--------|
| **SSH 远程命令** | 字符串拼接 shell 命令，存在注入风险 | Process 参数数组 + NSRegularExpression 输入校验 |
| **Socket 权限** | 755（任何本地用户可连接） | 600（仅 owner）+ 目录 700 |
| **Socket 并发** | `isRunning`/`serverFD` 无同步保护 | `OSAllocatedUnfairLock` 保护 |
| **NotchWindow 并发** | `Task.detached` 直接调用 `@MainActor` API | 快照模式：MainActor 读取 → nonisolated 处理 |
| **Keychain 安全** | 默认 `WhenUnlocked`，备份可提取 | `WhenUnlockedThisDeviceOnly` + 自动迁移 |
| **更新完整性** | 无校验，MITM 可投毒 | SHA256 比对 + codesign --verify |
| **CI** | 无 | GitHub Actions (`swift test`) |
| **死代码** | IslandHoverManager.swift（135 行） | 已删除 |
| **测试路径** | Package.swift 未声明 path | 显式 `path: "Tests/TowerIslandTests"` |
| **测试** | 212 tests | 213 tests |

### 安全修复详情

#### SSHRemoteManager 命令注入 [Critical]

**问题**：所有 SSH/shell 命令通过字符串拼接构建，`server.host`、`server.user`、`server.identityFile`、`server.remoteBridgePath` 全部未转义。攻击者可通过 `remote-servers.json` 注入任意命令。

**修复**：
- 新增 `SSHInputValidator`：host/user 匹配 `^[a-zA-Z0-9._-]+$`，路径匹配 `^[a-zA-Z0-9._/~:-]+$`
- 所有 `Process` 调用从 `/bin/bash -c` 改为直接 `arguments` 数组（绕过 shell 解析）
- `pkill -f` marker 使用校验后的 host

#### Socket 权限 [Critical]

**问题**：Unix domain socket 默认 755，任何本地用户可连接注入 `permissionResponse` 自动批准危险操作。

**修复**：`bind()` 后 `fchmod(fd, 0o600)`，目录 `chmod(dir, 0o700)`

#### SocketServer 数据竞争 [High]

**问题**：`isRunning` 和 `serverFD` 从 `start()`/`stop()`（调用者线程）和 `acceptLoop()`（后台 queue）同时读写。

**修复**：引入 `OSAllocatedUnfairLock<ServerState>` 保护共享状态

#### NotchWindow 跨 Actor 调用 [High]

**问题**：`activeSpaceDidChange` 中 `Task.detached` 调用 `isScreenInFullscreen`，该方法访问 `NSApplication.shared.windows`（`@MainActor` 隔离 API）。

**修复**：拆分为两阶段 — MainActor 上读取窗口快照（值类型），传给 `nonisolated static func` 执行 CGWindowList 查询

#### Keychain 可访问性 [High]

**问题**：`saveAPIKey()` 未设置 `kSecAttrAccessible`，默认 `WhenUnlocked`，API key 可通过设备备份提取。

**修复**：添加 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `migrateKeychainAccessibility()` 自动迁移已有 key

#### 更新完整性校验 [High]

**问题**：DMG 下载无 SHA256 校验、无代码签名验证，MITM 可投毒。

**修复**：
- `UpdateManager`：从 release body 提取 SHA256，传递给 `AppUpdater`
- `AppUpdater`：流式 SHA256 计算（64KB 块）+ `codesign --verify --deep --strict`
- 校验失败拒绝安装，旧版 release 无 checksum 时优雅降级

### P1 可维护性

- 删除 `IslandHoverManager.swift` 死代码（135 行，从未被引用）
- `Package.swift` testTarget 显式声明 `path: "Tests/TowerIslandTests"`

### P2 工程化

- 新增 `.github/workflows/test.yml`：push/PR 触发 `swift build` + `swift test`

### 验证

- `swift build`: 编译通过
- `swift test`: 213 tests, 0 failures
- 改动范围：9 个文件，+354/-245 行

---

## v1.5.2 (2026-05-17)

本版为 v1.5.1 的**文档与打包修正**，同时作为从 v1.4.0 升级的**推荐稳定版本**。

> 如果你正在使用 v1.4.0 或更早版本，建议直接升级到 v1.5.2 — 它包含 v1.5.1 的全部修复，
> 并修正了 CHANGELOG 格式与打包脚本默认版本号。

### 与 v1.4.0 完整对比

| 维度 | v1.4.0 | v1.5.2 |
|------|--------|--------|
| **长时间运行稳定性** | 偶发主线程卡死、CPU 飙高至 100%、应用无响应 | 9 项主线程阻塞修复，后台线程迁移，CPU 空转降至 <1% |
| **内存 / 资源泄漏** | Timer/Observer 不释放，缓存字典无限增长 | deinit 清理 + 孤立缓存定期清理 |
| **展开后无操作收起** | 固定 ~10 秒 | **偏好可调**（秒），支持「永不」 |
| **鼠标离开岛后收起** | 固定 0.5 秒 | **偏好可调**（多档），可关闭 |
| **代码组织** | SessionManager 三处重复查找逻辑，NotchContentView 889 行 God View | SessionManager 统一解析路径，提取 IslandSizeCalculator + IslandHoverManager |
| **测试覆盖** | ~125 条 | **212+ 条**（新增 L10n/MuteRule/AgentSession/AudioEngine/AgentType/ExpandedAutoCollapsePolicy） |
| **许可证** | 无 | MIT LICENSE |

### 性能修复详情（相对 v1.4.0）

| 问题 | 严重度 | 修复前 | 修复后 |
|------|--------|--------|--------|
| TerminalJumpManager 主线程阻塞 | 致命 | `NSAppleScript` + `Process().run()` + `CGWindowList` 全部同步阻塞主线程 | `jump(to:) async` + `Task.detached(priority: .utility)` |
| Hover Timer 过于频繁 | 高 | 0.1s 间隔轮询，`onDisappear` 未停止 | 0.3s 间隔 + `stopHoverPolling()` 清理 |
| NotchWindow 资源泄漏 | 高 | 无 `deinit`，Timer/Observer 不释放 | `deinit` 清理 Timer + NotificationCenter |
| bestScreen() 高频遍历 | 中 | `setFrame` 每次遍历所有屏幕 | `cachedOrRefreshScreen()` 仅跨屏时刷新 |
| CGWindowList 主线程调用 | 中 | `activeSpaceDidChange` 同步调用 | `Task.detached(priority: .userInitiated)` |
| Keychain 主线程读取 | 中 | `QuotaTracker.fetchAll()` 主线程 Keychain I/O | `nonisolated static` + `Task.detached` 批量读取 |
| 缓存字典无限增长 | 低 | `lastAssistantReplySoundAt`/`recentAnswers` 不清理 | `purgeOrphanedCacheEntries()` 定期清理 |
| Thread.sleep 阻塞队列 | 低 | AudioEngine 串行队列被 sleep 阻塞 | `scheduleFile`/`scheduleBuffer` 回调模式 |
| SwiftUI body 重计算 | 低 | `parseBlocks()` 和排序在 body 中重复执行 | 缓存计算属性 `blocks` + `sortedActivityEvents` |

### 行为偏好新增（相对 v1.4.0）

| 设置项 | UserDefaults Key | 默认值 | 说明 |
|--------|-----------------|--------|------|
| 展开无操作收起 | `expandedInactivityAutoHideDelay` | 10 秒 | 0 = 永不自动收起 |
| 鼠标离开收起 | `hoverExitCollapseDelay` | 0.5 秒 | 0 = 不按离开触发 |

- 入口：**设置 → 行为** 分区
- 实现：`ExpandedAutoCollapsePolicy.shouldCollapseOnMouseExit` + `NotchContentView` `@AppStorage`

### 代码质量改进（相对 v1.4.0）

- **SessionManager**: `startSession`/`findOrCreateSession`/`findOrCreateSessionForInteraction` 三处合并为统一 optional chaining 流程
- **NotchContentView**: 889 → ~857 行，高度/宽度计算委托 `IslandSizeCalculator`
- **IslandHoverManager**: 新建 135 行 hover 状态管理类（为后续集成准备）
- **AudioEngine**: `SoundEvent.displayName` 接入 L10n 五语系统
- **L10n**: 新增行为相关文案五语翻译

### v1.5.1 → v1.5.2 变更

- 修正 CHANGELOG.md 对比表格式（Markdown 表格对齐）
- 打包脚本 `package-dmg.sh` 默认版本号更新为 1.5.2
- `build.sh` Info.plist 版本号更新为 1.5.2

### 测试

- `swift test`: **212 tests, 0 failures**
- 新增覆盖：ExpandedAutoCollapsePolicy 参数化用例 + hoverExitDelay=0 分支

---

## v1.5.1 (2026-05-17)

本版为**相对上一正式发布 [v1.4.0](https://github.com/Meteorkid/XIsland/releases/tag/v1.4.0) 的汇总更新**：在 v1.4.0 的 Agent 扩展、面板与勿扰、Bypass、子 Agent 可视化等能力之上，补上**长时间运行稳定性**、**可配置的展开/收起节奏**，并做了一轮**结构重构与测试补强**。

### 与 v1.4.0 对比（高层）

| 维度 | v1.4.0 | v1.5.1 |
|------|--------|--------|
| 长时间挂机 / 多会话 | 偶发主线程卡死、CPU 飙高 | 终端跳转、Keychain、窗口枚举等迁至后台；Hover 轮询降频并在视图消失时停止；窗口释放 Timer/观察者 |
| 展开后无操作收起 | 固定约 **10s** | **偏好可调**（秒），可选 **永不** |
| 鼠标离开岛后收起 | 固定 **0.5s** | **偏好可调**（多档），可 **关闭** 该规则 |
| 代码组织 | — | `IslandSizeCalculator` 统一尺寸；`SessionManager` 合并重复 session 查找/创建路径 |
| 测试 | 约 **125** 条 | **212+** 条（含 L10n/MuteRule/AgentSession/AudioEngine/AgentType 等） |
| 仓库授权 | — | 默认分支含 **MIT LICENSE**（提交 `4eb70c3`，与功能同周期合入） |

### 性能、响应性与资源（相对 v1.4.0）

- **TerminalJumpManager**：`jump` 改为异步；AppleScript、`Process`、`CGWindowListCopyWindowInfo` 等在 `Task.detached` 中执行，避免阻塞 UI 主线程（此前多会话 / 频繁跳转时易出现「应用无响应」）。
- **Hover 轮询**：定时器间隔由 **0.1s 调整为 0.3s**；`onDisappear` **停止轮询**，避免窗口不可见时仍持续占用 CPU。
- **NotchWindow**：补充 **`deinit`**，清理鼠标跟踪 Timer 与 `NotificationCenter` 观察者，减少泄漏与后台活动。
- **屏幕选择**：`bestScreen()` **缓存**结果，仅在鼠标跨屏时刷新；减轻 `setFrame` 路径上的全屏遍历。
- **空格 / 全屏检测**：`activeSpaceDidChange` 内 `CGWindowListCopyWindowInfo` 移至后台线程。
- **QuotaTracker**：Keychain 读取批处理移到后台线程后再回主线程，避免首屏或刷新配额时卡顿。
- **会话缓存**：`purgeOrphanedCacheEntries()` 等清理已完成会话相关缓存，避免字典长期增长。
- **AudioEngine**：长音效路径使用 **`scheduleFile` / `scheduleBuffer` 回调** 替代 `Thread.sleep`，减少串行队列被长时间占用。
- **SwiftUI**：`MarkdownView` 解析与活动日志排序改为缓存计算属性，降低 body 重复重算成本。

### 行为与偏好（相对 v1.4.0）

- **展开后无操作自动收起**：`UserDefaults` 键 `expandedInactivityAutoHideDelay`（默认 **10** 秒）；**0** 表示关闭该项自动收起。偏好界面位于 **设置 → 行为**。
- **指针离开后再收起**：键 `hoverExitCollapseDelay`（默认 **0.5** 秒）；适用于**悬停展开**或**无可见会话**时的离开延迟；**0** 表示不按「离开」触发收起。同样可在 **行为** 分区调节。
- **实现要点**：`ExpandedAutoCollapsePolicy.shouldCollapseOnMouseExit` 增加 `hoverExitDelay`；`NotchContentView` 使用 `@AppStorage` 并在偏好变更时刷新无操作计时；`AppDelegate.register(defaults:)` 注册默认值。

### 代码质量与结构（相对 v1.4.0）

- **SessionManager**：合并 `startSession` / `findOrCreateSession` / `findOrCreateSessionForInteraction` 中重复的 session 解析与创建路径，统一 optional chaining 流程。
- **NotchContentView**：高度/宽度等委托 **`IslandSizeCalculator`**，减少重复计算；引入 **`IslandHoverManager`** 文件（为未来集中管理 hover 状态占位）。
- **NotchWindow**：与尺寸、屏幕相关的逻辑与 v1.4.0 相比更贴合「高频路径不重复做重活」的原则（见上节缓存）。

### 测试与质量门（相对 v1.4.0）

- 新增/强化覆盖：**L10n**、**MuteRule**、**AgentSession**、**AudioEngine**、**AgentType** 等专用测试文件。
- **ExpandedAutoCollapsePolicy**：为可配置 `hoverExitDelay` 补充参数化用例及「delay 为 0 不收起」分支。
- 规模：**约 125** → **212+** XCTest（以当前 `swift test` 为准）。

### 其它

- **本地化**：新增行为相关文案走 **L10n** 五语；日文说明有一处措辞修正（`hoverExitCollapseDesc`）。

---

## v1.4.0 (2026-05-16)

### 新增 Agent 支持

- **Aider**: 完整支持，通过索引信号文件接入
- **Kiro**: 完整支持，通过 Spec hook 接入
- **CodeBuddy**: 完整支持，通过配置 hook 接入
- **Droid (Factory)**: 基础支持

### 新功能

- **面板尺寸自定义**: 偏好设置中可调整面板宽度 (320-600px) 和最大高度 (320-700px)，步长 20px
- **定时勿扰 (Quiet Hours)**: 基于时间的自动静音，支持跨午夜区间 (如 22:00-07:00)，状态栏显示 moon 图标
- **右键上下文菜单**: 收起状态右键可快速静音/取消静音、打开偏好设置、退出；展开状态增加关闭所有会话选项
- **Session 回顾总结 (Recap)**: 已完成的 session 显示可展开/收起的 AI 生成摘要，最多 5 行
- **自定义静音规则 (Mute Rules)**: 基于正则表达式的静音规则，可按 Agent 类型、工具名或工作目录匹配事件
- **Bypass/自动模式**: 自动批准所有权限请求、问题回答和计划审查，状态栏显示闪电图标
- **Subagent 嵌套可视化**: 子 Agent session 左侧 2px 紫色竖线 + 24px 缩进，父卡片底部可展开/收起子 Agent 列表
- **L10n 多语言完善**: 所有新增 UI 字符串接入五语系统 (中/韩/日/法/英)，偏好设置中新增语言手动切换器
- **VS Code 扩展**: 支持从灵动岛直接跳转到 VS Code 终端标签页

### 修复与改进

- 修复 Kiro/Gemini/Droid/CodeBuddy 假 Hook 问题，全部实现真实 di-bridge 调用
- AgentType/AgentMeta 数据驱动注册表重构，消除 SessionManager 中的 switch 重复
- 内聚性重构：SessionManager 代码从 ~1200 行缩减，逻辑归位到 Manager/Model 方法中

### 技术变更

- `DIMessageType.recap` 新增 recap 消息类型
- `DIMessage.recapText` 字段
- `AgentSession.recapText`、`AgentSession.isSubagent`、`AgentSession.subagentIds`、`AgentSession.terminal`
- `AudioEngine.isMuted` 改为计算属性 (手动 mute || quiet hours)
- `AudioEngine.play(_:session:)` 新增 session 参数做静音规则匹配
- `SessionManager.bypassMode` 自动批准逻辑
- 新建 `MuteRule.swift` 数据模型
- 125 XCTest 测试全部通过，0 失败
