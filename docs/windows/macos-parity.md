# Windows 功能对齐基准

核查日期：2026-10-13。基准来源为当前 `Sources/DynamicIsland`、`Tests`、`README.md`、`docs/compatibility`。本文记录 Windows 实现前的基线，不是 Windows 验收报告；本轮没有编译、运行客户端或复验历史测试结果。

## 范围与完成定义

- Windows 目标是保留 XIsland 的会话控制与交互能力，并实现 Windows 桌面的悬浮岛体验。AppKit、SwiftUI、SwiftData、Keychain、AppleScript、DMG 安装等系统实现须替换。
- 下表的“未实现”是本次基线冻结时的 Windows 状态；后续只有提交具体实现路径和验证证据后才能更新。表内测试名称是可移植的行为规格，不能直接作为 Windows 测试通过的证据。
- 可直接复用的数据仅指 JSON fixture、事件语义、预期结果；Swift XCTest、macOS UI 驱动和绝对 `/tmp` 路径需要重建或参数化。
- 功能完成必须分别记录：离线契约测试、Windows 实际应用验证、原生客户端端到端验证。合成事件驱动真实窗口只满足第二项。
- 不把“窗口能打开”“有安装包”“配置写入成功”当作 Agent 接入完成。每个客户端必须记录版本、CLI/IDE/桌面载体、Windows 原生/WSL 环境、事件和交互范围。

路径约定：下表中的 `Managers/`、`Models/`、`Views/`、`Testing/` 均相对 `Sources/DynamicIsland/`；测试文件均相对 `Tests/TowerIslandTests/`；`app/` 与 `companion/` fixture 相对 `Tests/Fixtures/`。

## 功能矩阵

| ID / 模块 | macOS 现有源码 | Windows 目标 | 可复用 fixture / 行为规格 | 验收标准 | 基线状态 |
|---|---|---|---|---|---|
| W01 会话列表与筛选 | `Models/AgentSession.swift`、`Views/SessionListView.swift`、`Views/SessionFilterBar.swift`、`Managers/SessionManager.swift` | 多 Agent、多会话独立展示；提示词标题、工作目录、时间、选中项、搜索和筛选 | `app/session-list.json`、`app/empty-interaction.json`；`SessionFilterTests.swift`、`AgentSessionTests.swift` | 同品牌两个工作区不混会话；筛选不删除数据；无会话和长中文路径均可读；重排后选择保持 | 未实现 |
| W02 状态与生命周期 | `Models/AgentSession.swift`、`Managers/SessionManager.swift`、`Models/ObservationLease.swift` | 保留 active、idle、thinking、waitingPermission、waitingAnswer、waitingPlanReview、completed、error、compacting、observationUnavailable、completionUnconfirmed；状态优先级一致 | `companion/observation-events.json`、`companion/kimi-code-hooks.json`；`SessionManagerStatusTests.swift`、`SessionStopFinalityTests.swift`、`SessionProcessExitTests.swift`、`SessionResumeLifecycleTests.swift` | 静默、进程退出、非最终 Stop 不冒充成功完成；迟到消息不恢复终态；合法新轮次可恢复同会话；错误不被普通停止覆盖 | 未实现 |
| W03 子 Agent 与任务树 | `Models/AgentFlow.swift`、`Managers/SessionManager.swift`、`Views/AgentFlowView.swift`、`Views/SessionListView.swift` | 父子关系、独立子 ID、折叠、活动数、等待与错误状态；缺父 ID 时保留未知关系 | `companion/observation-events.json`；`NativeSubagentTests.swift`、`SessionManagerSubagentTests.swift`、`AgentFlowAggregatorTests.swift`、`VSCodeSubagentFinalityTests.swift`、`ClaudeLifecycleIdentityTests.swift`、`QoderLifecycleIdentityTests.swift` | 两个并行子任务分别停止；主任务停止不能抹去活跃子任务；重放不重复计数；不得用名称补造父子关系 | 未实现 |
| W04 工具活动与思考展示 | `Models/ToolEvent.swift`、`Views/AgentActivityView.swift`、`Views/ExpandedSessionView.swift`、`Views/MarqueeText.swift` | 活动时间线、工具输入/结果、读写行数、测试通过/失败统计、思考状态、滚动摘要 | `companion/kimi-code-hooks.json`；`ToolEventTests.swift`、`SessionManagerToolMatchTests.swift`、`MarqueeTextTests.swift` | 并发工具按调用 ID 合并，结果更新不重复建行；未知结果不计作通过；长文本截断后仍可查看完整详情 | 未实现 |
| W05 权限审批 | `Views/PermissionApprovalView.swift`、`Views/PendingTaskCardView.swift`、`Models/InteractionRequestState.swift`、`Managers/SocketResponseChannel.swift`、`Managers/SessionManager.swift` | 显示命令/路径/diff；允许、拒绝及客户端实际支持的持久决定；一次响应对应一次请求 | `app/permission-smoke.json`；`ApprovalInterruptionStateTests.swift`、`InteractionReliabilityTests.swift`、`SocketResponseChannelTests.swift`、`NativeInteractionResolutionTests.swift` | A/B 请求不会串答；过期、重复点击、断连、取消和重启不产生隐式允许；完整原生回传经真实客户端验收 | 未实现 |
| W06 单选、多选与自由问答 | `Views/QuestionAnswerView.swift`、`Views/CustomQuestionInputView.swift`、`Views/MultipleQuestionInputView.swift`、`Models/AgentSession.swift` | 单题/多题、单选/多选、自由文本、草稿和焦点；按各客户端协议回传 | `app/question-smoke.json`、`app/question-custom.json`、`app/question-focus.json`；`CustomQuestionAnswerTests.swift`、`MultipleQuestionAnswerTests.swift`、`DIBridgeQuestionResponseTests.swift` | 中文/emoji/分片 UTF-8 往返一致；空值和不合法选项拒绝；编辑 B 后快捷键只能提交 B；取消保留原客户端处理能力 | 未实现 |
| W07 计划审阅 | `Views/PlanReviewView.swift`、`Views/Components/MarkdownView.swift`、`Managers/SessionManager.swift` | Markdown 计划正文、反馈草稿、批准/拒绝、键盘操作 | `app/plan-smoke.json`；`InteractionContentTests.swift`、`InteractionReliabilityTests.swift`、`UITestScenarioTests.swift` | 展示完整计划并支持滚动；反馈和决定一起传至对应请求；客户端没有已核实计划协议时明确只读，不显示可执行成功 | 未实现 |
| W08 自动模式与交互恢复 | `Managers/SessionManager.swift`、`Models/ApprovalInterruptionState.swift`、`Views/NotchContentView.swift` | 保留手动启停与状态可见性；仅对已核实且明确允许的交互执行自动模式；中断后恢复一致 | `ApprovalInterruptionStateTests.swift`、`NativeInteractionResolutionTests.swift`、`InteractionReliabilityTests.swift`（无独立 JSON fixture） | 未启用时不自动批准；切换模式不重复发送；未知协议不推定允许；原客户端审批保护和信任步骤不被绕过 | 未实现 |
| W09 原生消息与历史 | `Models/StoredSession.swift`、`Models/StoredChatMessage.swift`、`Models/StoredToolEvent.swift`、`Managers/SessionPersistenceManager.swift`、`Views/ChatHistoryView.swift` | Windows 本地持久化会话、消息、工具、状态及来源 ID；保留消息更新和终态语义 | `companion/observation-events.json`；`SessionPersistenceTests.swift`、`NativeMessageHistoryTests.swift`、`ObservationHistoryTests.swift`、`ArchivedSessionLifecycleTests.swift` | 保存/重启/恢复不丢内容；同内容不同 ID 不合并；同 ID 更新不重复；归档后迟到消息不能复活；写失败要可见并可重试 | 未实现 |
| W10 历史保留、备份与导出 | `Managers/HistoryStoreBackup.swift`、`Managers/SessionPersistenceManager.swift`、`Views/ExportView.swift`、`Views/PreferencesView.swift` | 保留期、分页、删除指定记录；JSON/Markdown/CSV 导出；升级数据前备份 | `HistoryStoreBackupTests.swift`、`SessionPersistenceTests.swift`、`SessionExportTests.swift`（Swift 内嵌样本需提取） | 导出保留状态、观察结束和真正完成的区别；中文/引号/换行正确；备份失败阻止迁移；Windows 不直接写 macOS SwiftData 数据库 | 未实现 |
| W11 会话摘要与检查点 | `Managers/SessionManager.swift`、`Models/AgentSession.swift`、`Managers/GitCheckpointManager.swift`、`Views/ExportView.swift` | 展示已收到的 recap；保留检查点功能的显式触发与结果反馈 | `SessionExportTests.swift`、`GitCheckpointManagerTests.swift`（无独立 JSON fixture） | recap 来源可追溯，不凭 UI 声称完成 AI 摘要生成；检查点只作用选定仓库；恢复行为单独确认并验证，不静默改变用户文件 | 未实现 |
| W12 用量与统计 | `Models/HistoryUsageSummary.swift`、`Views/StatisticsView.swift`、`Managers/SessionManager.swift` | 日/周等区间的会话数、时长、Agent 分布、工具频率、token 趋势与来源明确的费用估计 | `StatisticsViewTests.swift`、`CumulativeUsageTests.swift`（Swift 内嵌样本需提取） | 重复累计快照不重复累加；上下文占用不当累计 token；缺数据不显示为 0；跨日/时区/空历史结果准确 | 未实现 |
| W13 配额、余额与凭据 | `Managers/QuotaTracker.swift`、`Models/QuotaInfo.swift`、`Views/PreferencesView.swift` | 保留服务商开关和查询入口；分别建模额度、已用量、余额、币种、采集时间和错误；Windows 安全凭据存储 | `IslandIntegrationSettingsTests.swift`、`StartupIsolationTests.swift` 仅覆盖部分开关/隔离行为；需新增匿名 API 响应 fixture | 无密钥时不请求；密钥不写明文偏好/日志；已用量不显示为剩余额度；余额不换算成虚构 token；超时/鉴权失败/旧数据可辨认 | 未实现 |
| W14 通用设置与托盘 | `Views/PreferencesView.swift`、`IslandIntegrationSettings.swift`、`AppDelegate.swift` | 通用/显示/集成/Agent/声音/历史/统计/关于入口；启动登录、托盘、右键菜单、静音、关闭全部、退出 | `PreferencesViewTests.swift`、`IslandIntegrationSettingsTests.swift`、`AppDelegateStartupTests.swift`（无独立 JSON fixture） | 设置重启保持；退出释放窗口和通信端点；关闭全部不等于替客户端取消任务；登录启动与手动启动不出现双实例 | 未实现 |
| W15 主题、语言与可访问性 | `Managers/ThemeManager.swift`、`Managers/L10n.swift`、`Views/ThemePickerView.swift`、`Testing/TestAccessibility.swift` | 深/浅/跟随系统；中英日韩法；主题切换；Windows 屏幕阅读器和键盘焦点可访问 | `ThemeManagerTests.swift`、`L10nTests.swift`、`PreferencesViewTests.swift`；所有 `app/` fixture 可用作不同主题/语言截图 | 系统主题变化实时生效；语言改变无丢失草稿；中文输入法可用；缩放后文字/按钮不裁切；状态不只靠颜色表达 | 未实现 |
| W16 音效、静音与免打扰 | `Managers/AudioEngine.swift`、`Models/MuteRule.swift`、`Views/PreferencesView.swift` | 事件音效、音量、单事件开关、自定义音效包、全局静音、跨午夜安静时段、按 Agent/工具/目录正则静音 | `AudioEngineTests.swift`、`MuteRuleTests.swift`（无音频回放 fixture） | 22:00–07:00 跨日正确；静音规则只影响匹配项；不可读音效回退；实际 Windows 声音可听且无每条重复事件重复响铃 | 未实现 |
| W17 悬浮岛与动画交互 | `NotchWindow.swift`、`Views/NotchContentView.swift`、`Views/CollapsedPillView.swift`、`Views/IslandSizeCalculator.swift`、`Models/ExpandedAutoCollapsePolicy.swift`、`Models/IslandMotionPolicy.swift`、`SwipeGestureRecognizer.swift` | 无边框置顶胶囊、展开/收起、顶部水平拖动、悬停/滚动设置、宽高自定义、减少动画、自动隐藏/全屏隐藏 | `app/session-list.json`；`NotchWindowTests.swift`、`NotchContentViewTests.swift`、`CollapsedPillViewTests.swift`、`ExpandedAutoCollapsePolicyTests.swift`、`IslandMotionPolicyTests.swift` | 收起不挡无关区域点击；输入期间不意外收起；拖动边界不越屏；全屏行为遵循设置；实际窗口动画与点击区域一致 | 未实现 |
| W18 多屏、DPI 与工作区 | `NotchWindow.swift`、`IslandWindowOwnership.swift`、`Views/IslandSizeCalculator.swift` | 多屏跟随/当前交互固定、热插拔、任务栏工作区；Windows 混合 DPI 和负坐标屏幕 | `NotchWindowTests.swift`、`IslandWindowOwnershipTests.swift`、`NotchShapeGeometryTests.swift`；新增 Windows 专用屏幕 fixture | 在 100/125/150/200% 与混合缩放双屏上展开/拖动/输入无跳变；副屏拔除自动回到可见区域；不同任务栏位置不遮关键控件 | 未实现 |
| W19 快捷键与应用切换 | `Views/NotchContentView.swift`、`AppSwitcher.swift`、`Views/PermissionApprovalView.swift`、`Views/PlanReviewView.swift` | Esc 收起、搜索、会话导航、导出、主题、审批/问答操作；采用 Windows 按键提示和可预测焦点范围 | `KeyboardShortcutTests.swift`、`AppSwitcherTests.swift`、`InteractionReliabilityTests.swift`、`app/question-focus.json` | 输入框编辑不被全局快捷键误截获；快捷键针对当前请求；保留系统/原应用关键快捷键；不要机械把所有 Cmd 映射为 Ctrl 后宣称等价 | 未实现 |
| W20 终端与 IDE 跳转 | `Managers/TerminalJumpManager.swift`、`Models/AgentSession.swift` | Windows Terminal、PowerShell/命令提示符及实际支持的 IDE 窗口定位；显示精确定位或回退层级 | `TerminalAppDetectionTests.swift`、`AppSwitcherTests.swift`（无 Windows 原生定位 fixture） | 两个同名终端和相同目录场景不激活错误窗口；精确 tab/会话定位需独立实测；没有接口时如实回退窗口，不称为精确 tab；WSL 来源单列 | 未实现 |
| W21 自动 hook 配置与卸载 | `Managers/ZeroConfigManager.swift`、`Models/HookConfigurationFile.swift`、`Models/NativeHookProfile.swift` 及各 `*HookConfiguration.swift` / `*PluginConfiguration.swift` | 客户端检测、版本/载体分流、启停、安装/修复/卸载自身条目；Windows 路径与引号处理；原有用户配置保留 | `HookConfigurationFileTests.swift`、`ZeroConfigManagerTests.swift`、`NativeHookProfileTests.swift`、`VSCodeHookInstallationTests.swift`、`KimiRuntimeConfigurationTests.swift`、`DeepSeekHookInstallationTests.swift`、`OpenCodePluginConfigurationTests.swift` 等 | 连续安装两次不重复；卸载仅移除本产品条目；空格/中文路径可调用 bridge；先备份后原子写入；未核实载体不生成猜测配置；客户端实际加载单独验收 | 未实现 |
| W22 本地通信与来源隔离 | `Managers/SocketServer.swift`、`Managers/SocketResponseChannel.swift`、`Managers/SessionManager.swift`、`Models/ObservationLease.swift` | Windows 本地传输适配、分片消息、完整 UTF-8、请求关联、来源命名空间、断连和观察租约 | `companion/observation-events.json`、`companion/kimi-code-hooks.json`；`SocketServerAcceptTests.swift`、`SocketResponseChannelTests.swift`、`SessionManagerMirrorIsolationTests.swift`、`ObservationLeaseTests.swift`、`NativeHookPipelineTests.swift` | 大消息/分片/非法字节/断连安全处理；多个来源同 task ID 不合并；请求仅由对应 channel 回答；本地传输不默认监听公网 | 未实现 |
| W23 SSH 远程 | `Managers/SSHRemoteManager.swift`、`Views/PreferencesView.swift` | 服务器配置、连接检查、bridge 部署、隧道启停、远程事件回传；本地 Windows 与远端系统分别适配 | `SSHRemoteCommandTests.swift`（仅命令/路径规格，无真实主机 fixture） | 参数合法性、空格路径、同标签多服务器隔离；失败不显示已连接；断线状态可见；从真实远程 Agent 往返一次事件；不能把 Unix socket 隧道实现直接当 Windows 可用 | 未实现 |
| W24 更新与安装 | `Managers/UpdateManager.swift`、`Managers/AppUpdater.swift`、`Views/PreferencesView.swift` | 版本检查、Windows 架构/渠道对应安装资产、下载校验、错误恢复、安装重启和保留设置/历史 | `app/update-available.json` 仅复用状态和 Release 结构，DMG 资产必须替换；`UpdateManagerTests.swift`、`UpdateManagerURLTests.swift`、`AppUpdaterTests.swift` | 畸形/相同/较旧版本不升级；错误架构资产拒绝；校验失败不运行安装；真实 Windows 安装/升级/卸载走完且历史保留；不能复用 hdiutil/DMG 流程 | 未实现 |
| W25 单实例、测试隔离与诊断 | `SingleInstanceLock.swift`、`Testing/AppTestConfiguration.swift`、`Testing/AppTestFixtureLoader.swift`、`Testing/AppDiagnosticsSnapshot.swift`、`Testing/AppDiagnosticsWriter.swift`、`AppDelegate.swift` | 单实例端点所有权、可隔离 fixture 启动、状态快照、测试专用配置/数据库/端点 | 全部 `app/` fixture；`AppDelegateSingleInstanceTests.swift`、`StartupIsolationTests.swift`、`AppDiagnosticsSnapshotTests.swift`、`AppTestFixtureLoaderTests.swift` | 第二实例不夺端点；异常退出可恢复；测试不改用户 hooks/密钥/历史；诊断无凭据；fixture 启动的结果不标记原生客户端已验证 | 未实现 |

## macOS 兼容性证据的边界

权威范围见 [现有兼容矩阵](../compatibility/agent-matrix.json) 和 [验收定义](../compatibility/README.md)。本次读取的矩阵 `checkedAt` 为 2026-10-13：

- 原始目标 30 项全部 `complete: false`；其中 28 项为 `implemented_contract_tested`，Kiro 为 `legacy_unverified`，GLM 为 `not_started`。补充 WorkBuddy 为独立条目、`complete: false`，不增加原始目标完成数。
- `implemented_contract_tested` 是代码和协议契约的状态，不保证真实客户端加载配置，也不保证审批、问答、计划和所有事件均可工作。
- Claude Code 2.1.234 仅有原生 init-only 启动/退出链路证据；子代理、工具、审批等完整原生流程仍待验收。
- Codex 0.160.0 的记录是发现六条旧 hook 且未受信任；不能把只读发现当作配置安装、信任或真实执行已经完成。
- Kimi Node 2.1.1 有真实官方客户端经 ACP 加本地模拟模型的验证：20 项 hook 配置被加载，合计 14 类事件、35 条原生投递、29 个隔离 App/SQLite 检查点，包括心跳、中断、重启恢复、压缩、模型失败与拒绝。审批仍是观察能力；余下事件、真实服务商和完整控制未通过全面验收。不能继承为 Windows 已验证。
- OpenCode 自由文本/多选已有 bridge → socket → 隔离 UI 闭环，但实际 OpenCode 宿主 SDK 和完整计划仍未验收。
- Roo/PearAI、ACP、Aider、Continue、Cody、Amazon Q 等已有模拟或包装器观察证据；对应厂商真实客户端、IDE/TUI 形态和原生交互不能混算。PearAI 默认关闭；WorkBuddy 插件未完成真实宿主验收。
- 会话生命周期验证明确标注 `realClientVerified: false`，主要是单元测试和合成厂商事件驱动的隔离应用。进程名观察不能证明某个原生会话的精确进程归属。
- `CustomQuestionRenderTests.swift` 的渲染测试需要 `X_ISLAND_RENDER_CUSTOM_QUESTION=1`；默认跳过不能计为已执行截图验收。

这些未完成项必须在 Windows 的“客户端 × 版本 × 原生/WSL × 能力”验收表继续保留，不以“macOS 已支持”代替新的证据。

## 需要调整语义再移植的地方

1. **配额不能复制旧字段语义。** 当前 `Managers/QuotaTracker.swift` 将 Codex 本地 SQLite 的 `SUM(tokens_used)` 放入 `tokensRemaining`，又将 Kimi 余额按近似比例填入 token 字段。Windows 应分别显示“已用 token”“账户余额/币种”“有官方定义的剩余额度”；未知即未知，避免延续误导性展示。Anthropic 分支会发送真实 `/v1/messages` 请求以读取头部，不能作为默认、无提示的配额探测。
2. **停止不等于完成。** Windows 状态机必须保留 `completionUnconfirmed` 和 `observationUnavailable`；计时器、退出或 lease 失效不能制造成功记录。
3. **平台替换不等于协议替换。** 本地通信可按 Windows 实现，但请求 ID、会话来源、子 ID、超时、取消及原生 fallback 语义必须与已核实的客户端合同一致。
4. **源代码存在不代表体验已验证。** 统计、音效、SSH 和更新已有对应实现/测试规格，本次未复验真实外部 API、音频设备、远端主机或安装器；Windows 必须安排各自的运行验证。
5. **桌面 UI 不依赖实体刘海。** Windows 应以屏幕工作区、任务栏、DPI 和窗口焦点为边界重建布局。macOS safeAreaInsets、Spaces、AppleScript 和 bundle ID 不能直接成为 Windows 验收条件。

## 可直接取用的数据清单

| 数据 | 已有内容 | Windows 复用方式 |
|---|---|---|
| `Tests/Fixtures/app/empty-interaction.json` | 空面板、idle 更新状态 | 初始窗口/空状态截图与交互测试 |
| `Tests/Fixtures/app/session-list.json` | 3 个不同 Agent 的 active/idle/completed 会话 | 基础列表、选择、筛选、布局；路径参数化，不能作为生命周期事件证据 |
| `Tests/Fixtures/app/permission-smoke.json` | 权限工具、描述、路径、diff 字段 | 审批卡片和测试传输回包 |
| `Tests/Fixtures/app/question-smoke.json` | 单选 yes/no | 单选问答与请求关联 |
| `Tests/Fixtures/app/question-custom.json` | 无预设选项的中文自由输入 | 中文输入法、空值校验、UTF-8 往返 |
| `Tests/Fixtures/app/question-focus.json` | A/B 两个待答会话 | 焦点、快捷键与草稿隔离 |
| `Tests/Fixtures/app/plan-smoke.json` | Markdown 计划 | 计划正文、反馈、批准/拒绝界面 |
| `Tests/Fixtures/app/update-available.json` | GitHub Release 形状与可更新状态 | 仅复用状态结构；版本、平台资产及 URL 使用测试值 |
| `Tests/Fixtures/companion/observation-events.json` | 来源命名空间、实例 ID、序号、中文/emoji 原生任务 ID、父子事件 | 去重、来源隔离、观察状态、持久化跨平台黄金样本 |
| `Tests/Fixtures/companion/kimi-code-hooks.json` | 固定 Kimi Node 2.1.1 的 20 类合成 hook 输入与期望消息类型 | 解析器回归；明确保留 `synthetic: true`，不能标记原生客户端实测 |

其余 XCTest 的内嵌输入应在移植相应模块时提取为平台无关 fixture，并保持原始预期；不要为方便 Windows 实现而降低 macOS 的状态和交互约束。

## 每项验收记录应包含

每个 Wxx 至少登记实现路径、测试命令与结果、Windows 版本/架构、应用构建标识、使用的 fixture 或原生客户端版本、截图/录屏或诊断文件、仍未覆盖的分支。涉及真实 Agent 的行还需原生输入和回应证据。涉及安装、系统窗口、多屏/DPI、音效、SSH 的行必须有 Windows 实际运行记录；在 macOS 上通过静态检查或跨平台编译不能代替。

本文件初始状态全部未实现，便于后续逐项审计；功能范围不因首个 Windows 原型能够启动而自动缩小。

## 同日首批实现记录：Claude 纯协议模块

`windows/src/adapters/claude.ts` 已新增 Claude 原生 hook 到 DIMessage 的纯 TypeScript 转换，覆盖会话、工具、通知、压缩、子 Agent、PermissionRequest、单题 AskUserQuestion 的选项和自由文本，以及对应允许/拒绝/单一答案回传。规则参考当前 `Sources/DIBridge/DIBridge.swift` 和已有 Swift 契约测试，没有复制第三方项目源码。

`windows/tests/claude.test.ts` 的 13 个定向 Node 测试在当前 macOS 开发环境通过。这个结果只证明本项目离线协议转换；上方 Windows 实际应用/客户端验收状态不因此变更。多题和多选明确返回 `unsupported_question` 错误，调用方须输出空 JSON 并交回原生客户端，不能只回答首题后批准整组。没有自动配置用户 Claude，也没有完成 Windows 原生执行。PermissionRequest 下的问答响应沿用现有 Swift 形状，仍需对应真实 Claude 版本验证。
