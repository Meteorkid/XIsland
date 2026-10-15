# Windows 协议与状态核心移植基线

更新日期：2026-10-13。依据当前工作树静态阅读整理；没有运行 Swift 测试，也没有完成 Windows 客户端验收。下文行号对应本次阅读的工作树，后续修改可能使行号移动。

本文件仅定义复用边界和已有行为。现有协议没有独立的 `DIResponse` 类型：请求、通知和响应都编码为 `DIMessage`。Windows 可以把响应子集命名为 `DIResponse`，但不能因此改变 JSON 字段或增加必填的请求编号。

## 1. 线协议

证据：`Sources/DIShared/Protocol.swift:69-90,115-240`；`Sources/DynamicIsland/Managers/SocketResponseChannel.swift:12-28`。

- UTF-8 JSON，一条消息尾部追加 LF（`0x0A`）；不是 JSON-RPC，也没有协议版本、通用 `id` 或 `payload` 外层。
- 字段名使用下面的 camelCase；事件类型使用 snake_case。Swift 的可选字段可省略或为 `null`，发送端通常省略；未知字段由当前 Codable 解码忽略。
- `type`、`sessionId`、`timestamp` 是必填字段。构造器生成时间不意味着接收时允许缺失时间。
- 时间使用 ISO 8601 字符串；现有编码器使用 `.iso8601`，共享观察 fixture 为 `2026-10-09T13:22:24Z`。Windows 输出应保持这一格式；不能把 Unix 毫秒数直接写入 `timestamp`。
- 当前服务器每个连接读取一帧。观察事件不回复；交互请求保留该连接等待唯一答复。首个 LF 以后的额外内容不作为同一连接上的第二条业务请求处理。
- 当前主 bridge 与服务器限制单帧 16 MiB；VS Code 观察发送器另有 256 KiB 单帧、2 MiB/2048 条队列上限。应保留两类限制的区别。
- 当前读帧在正常 EOF 时允许尝试解码未带 LF 的完整 JSON；超时的未完成帧不能作为成功响应。若 Windows 收紧为必须 LF，应明确这是行为变更。
- 交互等待总截止时间默认 290 秒；服务端一次写回共享 3 秒截止时间，不能每个分片重置等待预算。完整写入仅证明本地连接写入完成，不证明供应商已应用裁决。

传输证据：`Sources/DIBridge/DIBridge.swift:14-15,273-304`；`Sources/DynamicIsland/Managers/SocketServer.swift:111-207`；`Sources/XIslandVSCode/src/transport.ts:19-38`。

### 事件类型（完整列表）

| 类别 | JSON 值 |
| --- | --- |
| 会话 | `session_start`, `session_end` |
| 工具 | `tool_start`, `tool_complete` |
| 权限 | `permission_request`, `permission_response` |
| 问答 | `question`, `question_response` |
| 交互被原端解决 | `interaction_resolved` |
| 计划 | `plan_review`, `plan_response` |
| 状态 | `status_update`, `progress` |
| 子代理 | `subagent_start`, `subagent_end` |
| 压缩与回顾 | `context_compact`, `recap` |
| 观察来源控制 | `observation_heartbeat`, `observation_ended` |

### DIMessage 字段（完整列表）

`?` 表示可省略/可为 null；`integer` 表示 JSON 整数，不能接受布尔值冒充数字。Swift `Int`/`Int64` 与 JavaScript `number` 的精度不同；TypeScript 核心必须拒绝不能精确表示的整数或单独实现无损整数解析，不能静默四舍五入。

| 字段 | JSON 类型 | 含义 |
| --- | --- | --- |
| `type` | 上述事件字符串 | 消息类型，必填 |
| `sessionId` | string | 规范化会话身份，必填 |
| `agentType` | string? | 代理来源 |
| `timestamp` | ISO 8601 string | 事件时间，必填 |
| `nativeEvent` | string? | 原生 hook/事件名 |
| `nativeAgentId` | string? | 原生代理身份 |
| `nativeTurnId` | string? | 原生轮次身份 |
| `nativeBackgroundTask` | object? | 原生后台任务事实，见下表 |
| `nativeMessageId` | string? | 原生聊天消息身份 |
| `nativeMessagePartial` | boolean? | 流式消息尚未完整 |
| `nativeMessageReplay` | boolean? | 历史重放，不证明新活动 |
| `sourceNamespace` | string? | 观察来源持久命名空间 |
| `sourceInstanceId` | string? | 观察来源本次实例 |
| `nativeTaskId` | string? | 被观察的供应商任务原始 ID |
| `observationSequence` | integer? | 来源级递增序号 |
| `terminal` | string? | 终端或宿主标识 |
| `termSessionId` | string? | 终端会话身份 |
| `workingDir` | string? | 工作目录，核心应当作数据 |
| `prompt` | string? | 用户提示 |
| `toolCallId` | string? | 单次工具调用身份 |
| `tool` | string? | 工具名 |
| `toolInput` | string? | 已规范化的工具输入文本 |
| `toolResult` | string? | 已规范化的工具结果文本 |
| `linesAdded` | integer? | 新增行数 |
| `linesRemoved` | integer? | 删除行数 |
| `nativeRequestId` | string? | 原生交互身份 |
| `nativeRequestKind` | string? | 原生交互种类；当前解决事件使用 `permission`/`question` |
| `permDescription` | string? | 权限说明 |
| `diff` | string? | 修改差异 |
| `filePath` | string? | 文件路径 |
| `approved` | boolean? | 权限答复 |
| `questionText` | string? | 一题的正文 |
| `options` | string[]? | 一题的选项标签 |
| `allowsCustomAnswer` | boolean? | 显式允许自由文本 |
| `allowsMultipleAnswers` | boolean? | 显式允许本题多选 |
| `answer` | string? | 单选或自由文本答复 |
| `selectedAnswers` | string[]? | 本题多选答复 |
| `planMarkdown` | string? | 计划正文 |
| `planApproved` | boolean? | 计划裁决 |
| `feedback` | string? | 计划反馈 |
| `status` | string? | 状态说明或助手回复 |
| `observedState` | string? | 适配器已确认的状态；未知值不能凭猜测映射 |
| `statusIsAssistantReply` | boolean? | 区分说明文本与助手回复 |
| `tokensIn` | integer? | 输入 token |
| `tokensOut` | integer? | 输出 token |
| `totalTokens` | integer? | 总 token |
| `costUSD` | number? | 美元成本 |
| `usageIsCumulative` | boolean? | true 为累计快照，否则按既有增量规则处理 |
| `model` | string? | 模型名 |
| `recapText` | string? | 会话回顾 |
| `parentSessionId` | string? | 子代理事件的父会话 |
| `subagentId` | string? | 子代理身份 |
| `subagentEndIsProvisional` | boolean? | 只收到准备停止信号，尚未确认完成 |

`hasObservationMetadata` 是计算属性，不在 JSON 中。任一观察身份字段出现，或类型为两种观察控制事件，即进入严格观察来源校验，不能作为普通 hook 绕过验证。

`nativeBackgroundTask` 字段（`Protocol.swift:95-112`）：

| 字段 | JSON 类型 |
| --- | --- |
| `id` | string，必填 |
| `kind` | string? |
| `status` | string，必填 |
| `description` | string? |
| `startedAtMilliseconds` | integer?（Swift Int64） |
| `result` | string? |

### 响应子集（Windows 可命名为 DIResponse）

每种响应仍有 `type`、`sessionId`、`timestamp`。现有响应不会回显 `nativeRequestId`；连接和本地请求令牌承担关联责任。

| type | 业务字段 |
| --- | --- |
| `permission_response` | `approved: boolean` |
| `question_response` 单选/文本 | `answer: string`，不同时带 `selectedAnswers` |
| `question_response` 多选 | `selectedAnswers: string[]`，不同时带 `answer` |
| `plan_response` | `planApproved: boolean`, `feedback?: string` |

不要把响应消息直接作为供应商的 stdout：`DIBridge.swift:123-171` 按适配器转换为各自的 JSON、纯文本和退出码；例如 OpenCode 多选的 stdout 键为 `answers`，线路字段却是 `selectedAnswers`（`Sources/DIBridge/OpenCodeHookAdapter.swift:86-100`）。

## 2. 身份、去重与状态不变量

### 来源与消息身份

1. 普通会话先按完整 `sessionId` 查询。仅允许明确的 Claude 与 Cursor/Trae/Windsurf 镜像配对；恰好一个候选、前缀与显式 agent 不冲突时才能合并。不同 IDE、不同代理不能仅凭相同后缀/目录合并；精确 ID 优先。镜像 Claude 的开始/结束不能覆盖 IDE 生命周期。证据：`SessionManager.swift:904-992`；`SessionManagerMirrorIsolationTests.swift:28,58,146,168,236`。
2. 原生聊天消息去重键为 `sessionId + NUL + role + NUL + nativeMessageId`，SHA-256 前 16 字节构成 UUID；原生 ID 必须非空、UTF-8 不超过 512 字节且无 NUL。同一个 ID 的流式更新替换原记录，角色/会话不同不能串联。证据：`SessionManager.swift:1270-1291,1550-1587,1660-1666`；`NativeMessageHistoryTests.swift:26-69`。
3. 工具优先按 `toolCallId` 匹配；无 ID 时只匹配同名、也无 ID、未完成的记录。未知结果可成为独立的已完成记录，不能误结束另一个仍在运行的工具。ACP/Continue 快照更新已存在的工具，不重复追加。证据：`SessionManager.swift:1485-1540`；`SessionManagerToolMatchTests.swift:7-45`。
4. 累计用量逐字段取最大值，拒绝重复计费/倒退；增量模式对 input/output/cost 加法，对 total 赋值。不要把两种模式统一为加法。证据：`SessionManager.swift:1816-1829`。

### 观察租约与来源隔离

- 当前严格观察协议只接受 `roo_code`、`pearai`；namespace 是 24 位小写十六进制，instance 是规范小写 UUID。新增来源必须同时增加适配器与验证，不能放开为任意来源。
- 来源 ID 为 `agent-namespace-instance`；任务会话 ID 追加 `-base64url(UTF8(nativeTaskId))`，无填充。禁止把目录、进程 ID 或本次启动时间假装成供应商任务 ID。
- 序号范围为 `1...9007199254740991`，按整个来源严格递增，重复/倒序拒绝。普通事件最大陈旧 30 秒，心跳 5 秒，未来偏移最多 5 秒；过期计算使用单调时钟，时间戳新鲜度使用墙钟。
- 控制帧必须无 nativeTaskId 且 sessionId 等于来源 ID；普通观察事件仅允许 session_start/status_update/subagent_start/subagent_end，并核对规范会话 ID。子任务也必须属于同一来源实例。
- 30 秒未见来源标记 `observationUnavailable`，不能宣称任务完成。心跳不创建任务、不刷新任务活动、不自动恢复显示的工作状态；只有新业务事实能恢复。显式 ended 来源拒绝迟到帧。账本最多 1024 来源，结束记录/过期记录按现有保留期限清理。
- 观察身份会话拒绝无身份的普通 hook 更新，也不能产生可操作审批。观察到“等待原应用审批”只改变显示事实。

证据：`Sources/DynamicIsland/Models/ObservationLease.swift:12-83`；`SessionManager.swift:512-535,881-900,995-998,1029-1031`；`ObservationLeaseTests.swift:31-167`。

### 主子会话与结束语义

- 目前状态全集为 active、idle、thinking、waitingPermission、waitingAnswer、waitingPlanReview、completed、error、compacting、observationUnavailable、completionUnconfirmed（`AgentSession.swift:5-16`）。显示状态与是否持有可提交交互是两件事。
- `session_end` 不必然意味着 completed：明确 `observedState=completed` 时关闭；具有可持续 CLI 进程的代理可能只是 idle。Stop/准备停止常映射为 completionUnconfirmed，不能靠超时改成成功。证据：`SessionManager.swift:1306-1343,1591-1604`；`SessionStopFinalityTests.swift:15,41,76`。
- 子代理使用 `parentSessionId ?? sessionId`；未知父会话不挂到其他会话。相同 subagentId 的开始幂等；父会话自己的 Stop 不能隐去仍活动的子代理。证据：`SessionManager.swift:1685-1706`；`SessionManagerSubagentTests.swift:7,25`；`SessionStopFinalityTests.swift:59`。
- provisional 子代理结束必须带 ID，不能使用“最后一个子代理”的旧协议兜底。它只设置完成未确认，不删除关联、不记最终完成；最终结束只完成对应子代理。Claude/Qwen 的特定原生 SubagentStart 可恢复同一个未确认子代理。证据：`SessionManager.swift:1689-1742`；`VSCodeSubagentFinalityTests.swift:61,100`。
- 已结束会话的迟到工具结果、历史重放、说明文本可以在适当路径补充事实，不能清除完成时间或激活；已归档状态必须按精确身份读取，读取失败不能当成新会话。新的有效 prompt/tool start 等才可恢复；重复 prompt/tool ID 不构成新活动。此处不能简单用“所有消息都 revive”或“完成后永远丢弃全部消息”。证据：`SessionManager.swift:1375-1382,1511-1536,1607-1626,1832-1902`；`ArchivedSessionLifecycleTests.swift:46,86,162`。
- 还存在供应商专属关闭规则：Amazon Q wrapper 的 end 后忽略该 wrapper ID；DeepSeek session_end 后忽略迟到非 session_start；Kimi Code 的审批观察、后台任务、压缩投影有独立账本，不能由通用 reducer 冒充已经移植。证据：`SessionManager.swift:516-542,610-863`，对应 `KimiCodeApprovalObservationTests.swift`、`KimiCodeBackgroundTaskSessionTests.swift`、`KimiCodeCompactionTests.swift`。

## 3. 审批、自由文本、多选与多题

### 一次请求只能裁决一次

- 每个本地 pending 请求有新 UUID；UI 提交必须同时匹配会话、种类、当前请求 UUID。旧按钮、旧异步完成不能作用到替代请求。
- phase 为 pending → sending → sent/failed；只有 pending 可提交。失败保留可见请求，但已关闭通道不能直接重复发送；需供应商新请求/新通道。
- 响应连接在同一串行队列执行 send/cancel，写入后即关闭并置无效；取消与重复提交不可能再操作被复用的描述符。Windows 必须以一次性通道对象保留此语义。
- 新的同类请求先取消旧通道；结束/删除会话取消所有未决请求而不批准。权限、问题、计划可并存，提交一个后仍显示其他未决项。
- `interaction_resolved` 必须精确匹配 sessionId + nativeRequestKind + nativeRequestId，关闭对应通道，无本地批准动作；旧 request ID 不得取消新请求。
- 有原生 request ID 的交互不被普通并行工具活动清除；遗留无 ID 交互才按旧规则清理。观察来源和历史重放不能产生可审批请求。
- bypass 是用户设置的明确能力：权限/计划批准；单选取首项；多选和纯自由文本不会被凭空代答。Windows 默认应关闭 bypass。

证据：`InteractionRequestState.swift:17-26`；`SocketResponseChannel.swift:5-50`；`SessionManager.swift:995-1110,1119-1149,1160-1245,1353-1372,1780-1813`；`InteractionReliabilityTests.swift:48,85,158,191`；`NativeInteractionResolutionTests.swift:22,40,135,248`。

### 问答校验与串行流程

- 单选接受精确选项标签；自定义文本须 `allowsCustomAnswer=true`，去除首尾空白后非空、无 NUL、UTF-8 ≤8192 字节。空选项不能隐式开启自由输入。
- 多选须 `allowsMultipleAnswers=true`；1...128 项、无重复、每项有效、合计 UTF-8 ≤8192 字节，至多一项为自定义值。选择输出按照原 options 顺序，最后附自定义文本；不使用无序集合的遍历顺序。
- 单选与多选 response 分别使用 answer/selectedAnswers，不能二者同时存在。草稿、展开状态、所选值归属本地请求 UUID，替换请求不能继承草稿。
- 空问题拒绝；遗留正文恰为 `Question` 且无选项/无原生 ID/无自定义能力的占位请求取消。有 nativeRequestId 或自由文本能力的真实 `Question` 不应误判。
- 遗留答案缓存仅对无 nativeRequestId、2 秒内相同或相互包含正文、相同选项集合且缓存答案仍是选项的请求生效。任何有 nativeRequestId 的请求均不得复用该缓存；两个正文相同的原生请求仍分别作答。
- **多选不等于多题。** DIMessage 一次只承载一题。OpenCode 插件对原生 questions[] 按顺序逐题调用 bridge，以 `[N/M]` 标注，最后一次向原端提交 `answers: string[][]`。多个题可共用同一 nativeRequestId，仍应有不同本地请求 UUID/通道。插件按 `(kind, session, native ID)` 去重完整原生请求、按会话串行排队。
- 当前 Claude 通用桥接只展示 `questions[0]`，回写 first question 的 answer/answers 以及 updatedInput 的 answer/answers；不能把它描述成完整的多题支持。Windows 若补齐此能力，需要单独定义兼容测试。

证据：`AgentSession.swift:248-282`；`SessionManager.swift:1032-1079,1169-1194`；`OpenCodePluginConfiguration.swift:144-205`；`DIBridge.swift:770-803,949-992`；`CustomQuestionAnswerTests.swift:8-83`；`MultipleQuestionAnswerTests.swift:7-76`。

## 4. 可复用 fixture 与测试证据

| 现有文件 | 可直接复用的内容 | 使用条件/范围 |
| --- | --- | --- |
| `Tests/Fixtures/companion/observation-events.json` | 11 条真实格式 DIMessage JSON，含中文/emoji task ID、Roo/Pear 分离、子代理、心跳和结束 | fixture 自述为编译后的 TS observer 生成的合成事件，不是供应商客户端流量；注入 fixture 的墙钟，不能用当前日期直接跑新鲜度校验 |
| `Tests/Fixtures/companion/kimi-code-hooks.json` | 20 条原生 Kimi Code 输入，带 expectedType/expectedState | synthetic=true，固定 @moonshot-ai/kimi-code 2.1.1/来源 commit；需先经对应适配器，不能直接投给 DIMessage decoder |
| `Tests/Fixtures/app/permission-smoke.json` | 权限等待视图状态 | AppTestFixture 数据，不是线路消息；测试加载器适配后可共用 |
| `Tests/Fixtures/app/question-smoke.json` | 单选问题状态 | 同上 |
| `Tests/Fixtures/app/question-custom.json` | 无选项的自由文本问题 | 同上 |
| `Tests/Fixtures/app/question-focus.json` | 两会话交互焦点 | 同上 |
| `Tests/Fixtures/app/plan-smoke.json` | 计划审批状态 | 同上 |
| `Tests/Fixtures/app/session-list.json` | 3 个会话的列表状态 | 同上 |
| `Tests/Fixtures/app/empty-interaction.json` | 空态 | 同上 |
| `Tests/Fixtures/app/update-available.json` | 更新可用 UI | 同上；发布更新实现不属于状态核心 |

App fixture schema 见 `Sources/DynamicIsland/Testing/AppTestFixture.swift:8-68`，当前 pendingQuestion fixture 只有 allowsCustomAnswer，没有多选字段。现存 JSON 未覆盖完整多选、多题取消、迟到写回；应从 Swift 行为测试提取新的平台无关序列，不修改现有 fixture 以假装已覆盖。

建议移植的首批行为用例：`ObservationLeaseTests`、`NativeMessageHistoryTests`、`SessionManagerMirrorIsolationTests`、`SessionManagerToolMatchTests`、`ArchivedSessionLifecycleTests`、`SessionStopFinalityTests`、`VSCodeSubagentFinalityTests`、`InteractionReliabilityTests`、`NativeInteractionResolutionTests`、`CustomQuestionAnswerTests`、`MultipleQuestionAnswerTests`。这些文件是行为参考；本文未执行其中任何测试。

## 5. 最小纯 TypeScript / Rust 核心边界

推荐先用纯 TypeScript 复刻协议/状态，以复用现有 VS Code 观察器测试思路；Rust 同样可行，下面边界不依赖 UI 技术选择。不要同时实现两套 reducer。核心不能 import Electron、Windows API、文件系统、socket、SwiftUI 等平台模块。

| 边界 | 输入与输出 | 必测不变量 |
| --- | --- | --- |
| `protocol` | unknown JSON/字节帧 → DIMessage；ResponseDecision → response JSON | 必填/可选字段、错类型、UTF-8、日期、单帧限制、响应互斥字段 |
| `identity` | message + 已知来源/会话索引 → 精确/允许镜像/拒绝 | 跨代理后缀隔离、canonical IDs、消息稳定键 |
| `observation-ledger` | message + monotonicNow + wallNow → event/heartbeat/ended/rejected | 新鲜度、来源序号、跨窗口子任务、超时不等于完成 |
| `session-reducer` | SessionState + 规范化事件 + 时间/ID依赖 → 新 State + Effects[] | 重放、工具配对、迟到结果、停止未确认、主子任务、用量 |
| `interaction-reducer` | 当前 pending + 带本地 request token 的动作/投递结果 → State + Effects[] | stale token、一次提交、取消替换、原生解决、多选/自定义校验 |
| `adapter` | 供应商原生事件 → DIMessage；响应 → 供应商 stdout/退出码 | 每个代理显式能力，不对未知 hook 猜测可审批性 |

Effects 只表达 `sendDecision(channelToken, response)`、`cancelChannel(channelToken)`、`saveSession(snapshot)`、`playSound(kind)`、`focusInteraction(token)` 等意图；外壳执行效果，再把带原 token 的投递结果送回核心。存储读取失败必须作为错误输入，不能转换成“不存在”。时钟和 ID 生成器可注入，测试不依赖真实睡眠或系统时间。

Windows 平台层负责命名管道/本地 IPC、用户边界、进程/终端监督、路径与 shell 命令、持久化、窗口/焦点/通知。当前 `DISocketConfig` 的 `/tmp`、`~/.xisland/di.sock`、104 字节限制是 Darwin 传输约束；不要移植进通用 JSON validator。`workingDir`/`filePath` 也不能统一要求 `/` 开头，需容纳 Windows 盘符和 UNC。

实现顺序：先建立 codec 与 fixture 解码；再做身份/观察租约；再做会话 reducer 和一次性交互；最后连接 Windows IPC/存储/UI 并逐代理验收。纯核心测试通过只证明协议/状态行为，不能替代 Windows 真机上的窗口、终端、供应商 hook 或审批写回验收。

平台差异证据：`Protocol.swift:31-63`；`ObservationSender.swift:2-24`；`TerminalProcessSupervisor.swift:1,39-55,140-176`；`VSCodeHookInstallation.swift:4-9`；`VSCodeHookConfiguration.swift:13,58,100`；`Sources/XIslandVSCode/src/extension.ts:27,37`。

## 6. 首批 TypeScript 核心交付与当前边界

实现位于 `windows/src/core/`，统一从 `index.ts` 导出；契约定义在 `protocol.ts` 与 `types.ts`。

- `parseDIMessage` / `decodeMessage` / `encodeMessage`：严格基础类型校验；现有 Swift DIMessage 的 53 个存储字段全部对应，未知字段忽略，null 可选字段归一为省略。
- `SessionStore.apply(message, {requestId, expiresAt}?)`：返回 `{accepted, reason?, cancelRequestIds}`。平台必须执行返回的取消列表；交互必须绑定唯一真实 transport requestId，不能按当前选中的会话找连接。
- `snapshot()` 与 `subscribe(listener)`：输出隔离快照，订阅时立即通知；`select(id)` 选择可见会话。
- `prepareResponse(sessionId, interactionId, decision)`：返回 `{interactionId, sessionId, transportRequestId, response}` 并锁定 sending；镜像会话 response 保留原始 wireSessionId。只有平台实际写回成功后调用 `confirmResponse(id, true)`；失败调用 false，不能以点击成功代替送达成功。
- `endTransport(requestId, error?)`：异常断开/原端超时使匹配 pending 失效；不能把正常成功写回的关闭事件抢先作为失败通知。
- `expire()`：注入时钟驱动，返回应取消的 transport IDs；`loadFixture` 仅加载显式测试场景，虚拟通道前缀为 `preview:`，不得发到真实原生接口。
- `serialize()` / `restore()`：版本化历史、原子校验、剥离连接凭据；恢复后的未决请求不可重发。非终态历史在恢复时标为 observationUnavailable，等待新的业务事件；序号和显式结束的观察来源账本一并保存，避免重启后接受旧帧。
- `dismiss(id)` / `clearHistory()`：仅清理 completed/observationUnavailable 且无 pending 的记录，不静默结束活动任务。

当前实现不能宣称与完整 macOS SessionManager 等价，仍须单独处理：

1. 供应商专属 Kimi Code 审批/压缩/后台任务投影账本；当前只保存已收到的后台任务字段，没有复刻其全部投影逻辑。
2. 通用 session_end 在缺少明确 completed 事实时保守显示 idle，没有复制 macOS 的 processNames/进程存活表。原生适配器需提供最终事实，平台进程监督另行验收。
3. 遗留“2 秒内问题文本近似匹配自动复用答案”目前不启用；每个新通道仍等待用户裁决。原生 ID 的去重和逐题回答已经覆盖，不应把文本相同当成同一原生请求。
4. 每个会话每种交互保留一个 pending，后到同类请求取消前一个，这与当前 Swift 行为一致；原生插件应对同会话多题/多审批按既有 lane 串行调度，尚未提供任意并行同类审批队列。
5. 聊天记录内部 ID 使用 `(wireSessionId, role, nativeMessageId)` 的无歧义 JSON 元组键，保持去重/替换语义，但不是 Swift SHA-256 派生 UUID；不提供 macOS SwiftData 数据库直接迁移。
6. codec 验证完整 JSON 消息；字节流分片、管道访问控制、并发/帧截止时间、原生 stdout/退出码由平台和 adapter 层负责。

验证：`windows/tests/core.test.ts` 的纯核心回归覆盖协议、身份、观察来源、迟到/重放、主子任务、累计用量、单次交互、自由文本/多选/串行多题、历史恢复和现有 fixture。另以仅 ES2022 + Node 类型（不含 DOM lib）编译 `src/core/index.ts` 通过；字段集合比较为 Swift 53 / TypeScript 53，缺失和额外字段均为 0。所有这些都属于本地契约验证，不是 Windows 真机或 30 客户端验收。
