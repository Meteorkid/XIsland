# AI 工具接入与兼容性

本页说明 X Island 的 35 个来源条目：30 个可接入，5 个已停用并只保留历史（hermes 预留、Windsurf、Continue、Roo Code、Amazon Q CLI）。不同客户端的接口能力不同：有的可以回传审批或答案，有的只能显示状态，豆包工作目前只能观察显式上报的活动。CLI、IDE、桌面端和同品牌插件分别核实，不能互相代替。

更新日期：2026-11-27。30 个可接入条目都有通过项目契约测试的基础路线（GLM 按实际客户端接入）；所有目标的完整验收均未完成。2.0.1 发行构建的具体测试结果以[公开验证摘要](release-verification-2.0.1.json)为准；机器可读状态见[适配矩阵](agent-matrix.json)。

## 2026 年合并、改名与停用

| 旧入口 | 市场变化 | 本项目的处理 |
| --- | --- | --- |
| Gemini CLI | 2026-05-19 个人版迁到 Antigravity CLI（agy），2026-06-18 个人版停止服务 | 新增 Antigravity（`~/.gemini/config/hooks.json`）；Gemini CLI 只保留企业版与付费 API Key 场景 |
| Windsurf | 2026-06-02 Cognition 自动更新为 Devin Desktop，Cascade 品牌退役 | 同一应用身份归入 Devin Desktop；旧会话按 `windsurf` 保留在历史 |
| Amazon Q CLI | 2025-11-17 更名为 Kiro CLI；Q IDE 插件 2027-04-30 停止支持 | 新接入走 Kiro；旧 qchat 1.19.7 包装器只保留历史 |
| Continue | 2026-06 被 Cursor 收购，仓库只读，最后版本 v2.0.0-vscode | 停用入口，改接 Cursor |
| Roo Code | 2026-05-15 停运，仓库归档，团队转向 Roomote | 停用入口，改接 Cline 或 Kilo Code |
| Cody | 2027-01-31 停止支持，新注册仅企业版；Amp 已拆分为独立公司 | 保留到停止支持；不把 Amp 当作 Cody 的继任 |
| Tabnine | 2026-07-30 被 Tricentis 收购，6.x CLI 改为 OpenCode 托管分支 | 自动配置只覆盖旧版 CLI；6.x 按 OpenCode 插件方式核对 |
| TRAE Work | 2026-08-25 随 TRAE/Coze 并入豆包工作 | 应用身份归入豆包工作；TRAE IDE/CLI 仍是豆包品牌下的编码产品 |
| Qoder（通义灵码） | 2026-05-20 更名为 Qoder CN 系列 | 显示名更新为 Qoder CN；QoderWork 并入千问办公，不与 IDE/CLI 入口混用 |
| 豆包工作 | 2026-08-25 公开发布，支持 STDIO 自定义连接器 | 新增连接器级活动观察；没有原生 hooks，不接管审批与问答 |
| Kilo Code | 2026-07-15 被 Anaconda 收购，产品与 CLI / VS Code 扩展继续 | 新增原生全局插件；不按“被收购”猜测停运，也不改走未核实的云接口 |

## 如何接入

1. 安装 X Island，在集成设置中找到实际使用的客户端。
2. 原生 hooks 或插件来源按对应设置项配置；需要外部包装器的来源使用下方指南。
3. 配置生成、文件存在或接收开关开启，只能说明入口已准备；还需在原客户端完成必要的插件启用或信任，并运行实际任务确认事件进入 X Island。
4. 没有可靠应答接口的来源只观察状态，审批、问答和取消继续在原客户端完成。

### 让 Agent 直接配置

不想手写 hooks 时，可以把对应客户端的整段提示复制给能操作本机的 LLM Agent。提示会要求 Agent 先检查版本、备份、保留第三方配置，再合并 X Island 条目；客户端内的启用与信任确认仍由用户完成。

- [复制给 LLM：接入配置提示库](llm-setup-prompts.md)
- 使用专项指南的来源，提示写在该指南末尾，例如 [Trae](../integrations/trae-hooks.md)、[Kilo](kilo-setup.md)、[Kiro](kiro-setup.md)。

### 交互回传边界

只有原生 hook/插件明确提供了“把用户决定写回原进程”的字段，X Island 才展示批准、拒绝、回答或计划审查控件；仅能读到 `waitingPermission` / `permission_prompt` 的来源不会伪造按钮。

| 交互 | 已接入岛上回传的来源 | 仅观察或留在原客户端 |
| --- | --- | --- |
| 权限批准 / 拒绝 | Claude Code、Codex（信任 hooks 后）、Qwen Code、Qoder CN、Trae 的 Claude Code hooks、Devin、OpenCode 插件 | Claude Code 支持带原因的 deny.message、修改参数后批准（updatedInput）、拒绝并停止（interrupt）、本会话精确 Bash 规则（updatedPermissions）与 Edit/Write/MultiEdit/NotebookEdit 内联 diff 预览；Cursor 的 `beforeShellExecution` / `beforeMCPExecution` 只消费 `deny` 和 `ask`，岛上只提供「拒绝」与「交回原生确认」，不伪造批准；Kimi Code、Kilo、WorkBuddy、豆包工作、Antigravity、Factory Droid、Copilot CLI、Kiro、Amp、Pi、Aider、DeepSeek/Codewhale、CodeBuddy、VS Code Copilot、Zed/JetBrains 外部 ACP 仍只观察 |
| 问答 | Claude Code `AskUserQuestion`、OpenCode 的 `question.asked` | 其余来源；Trae/Cursor/Qoder/Qwen 的原生问答入口尚未取得可核实的回传合同 |
| 计划审查 | Claude Code、Qwen Code、Qoder CN、Trae Claude Code hooks 的 `ExitPlanMode` | OpenCode 及只上报 `waitingPlanReview` 的观察型来源 |

`ExitPlanMode` 的 allow 必须带回原始 `tool_input`；缺少这一字段时 bridge 不会假装批准成功。Cursor 权限 hook 在 X Island 未运行时返回 `permission: ask`，交回 Cursor 原生确认，而不是默认放行或永久阻断。

**并发审批**：同一会话的多个权限请求不再互相取消。当前请求处理完后，队列中的下一个请求自动晋级；队列上限 16，超出或重复请求会关闭新 hook 连接，交回客户端原生流程。这是参考 AgentBar 的 request/answer 队列语义实现的最小版本。每个权限请求带 310 秒租约；hook 的 300 秒超时后，当前和队列中的过期项会自动清理，未过期项继续晋级，避免 bridge 已退出但卡片永久悬挂。

**子代理归因**：Claude 子代理的 `PermissionRequest` 若带 `agent_id`，请求仍归属父会话，但审批卡会显示「子代理 · agent-id」。不同子代理使用相同工具名时不会互相去重；这避免了多子代理并发审批看起来像同一个请求。

**超时 / 放弃**：Claude Code、Codex、Qwen、Qoder、Trae 的空决策会输出 `{}` 并 exit 0；Cursor 输出 `permission: ask`；两者都不会在无人裁决时静默批准或静默拒绝。

**审批审计**：每次批准、拒绝、交回原生、超时、原生已处理或取消，都会向 `~/.xisland/approval-audit.jsonl` 追加一条记录，字段包括会话、来源、工具、子代理、native request id、决定、延迟、`toolInput` 的 SHA-256 和前一条记录哈希。文件权限为 `0600`；只存输入哈希，不复制完整命令/文件内容。审批卡和会话详情显示当前会话最近决定。这是本地可追溯性，不是外部可验证凭证：能改本地文件的人也能重写整条链。

**拒绝原因**：Claude Code 的审批卡支持「拒绝并说明」，原因经 `DIMessage.denyMessage` → socket → `DIBridge` 写入 `PermissionRequest` 的 `decision.message`，Claude 会收到这段反馈；官方合同明确 `message` 只用于 deny，`updatedInput` 只用于 allow。空白原因自动退回普通拒绝，原因截断到 1000 字符并拒绝 NUL；它不写入审批审计账本，避免把自由文本复制进持久化记录。Cursor 没有已核实的 `message` 合同，继续只提供 deny 与交回原生确认，不伪造支持。

**修改参数后批准**：Claude Code 的审批卡还支持「修改后批准」，对应官方 `PermissionRequest` 的 `decision.updatedInput` 与 Agent SDK 的 Approve with changes。Bash 先编辑 `command` 并保留 `description` 等其它字段；其他工具编辑完整 JSON 对象。参数经 `DIMessage.updatedInput` → socket → `DIBridge` 写回 allow 决策，执行前 Claude 仍会按 deny/ask 规则重新评估修改后的输入。空白、含 NUL、超过 64,000 UTF-8 字节或不是 JSON 对象时，X Island 拒绝提交并保留审批卡，绝不降级为批准原始命令；该能力只对已核实合同的 Claude Code 开放，审计的 `payloadHash` 记录实际执行的编辑后参数。

**拒绝并停止本轮**：Claude Code 审批卡另有「拒绝并停止」和「拒绝并说明 → 同时停止本轮」两条路径，对应官方 `PermissionRequest` 的 `decision.interrupt`。该字段只用于 deny，`true` 会停止 Claude 当前回合，可与 `message` 同时使用；X Island 只在 Claude Code 的拒绝分支写 `interrupt`，allow 分支绝不携带。它不承诺终止后台子代理、后台 Bash 任务或已脱离 shell 的进程，其他来源不伪造“已停止”。

**本会话允许此命令**：Claude Code 的 Bash 审批卡可显式选择「本会话允许此命令」，对应 `decision.updatedPermissions`。X Island 只接受主代理（非子代理）请求，且只构造一条 `addRules`：`behavior=allow`、`destination=session`、`rules=[{toolName:"Bash", ruleContent:<命令>}]`；命令必须完全相同、无 `*`、无换行、非空、不超过 2,000 字节。含通配符、非 Bash 或子代理卡片不显示该入口，管理器也会拒绝。规则只留在 Claude 会话内存，不写 settings 文件、不跨会话、不自动裁决；它不覆盖宿主已有 deny 规则，后续新请求仍会回到岛上。

**文件改动预览**：参考 Cline（Apache-2.0）和 Claude Code Desktop/VS Code Manual 模式的“先看 diff 再接受”，`Edit` / `Write` / `MultiEdit` / `NotebookEdit` 审批卡会从 `tool_input` 生成只读内联预览：红色 `-` 旧行、绿色 `+` 新行、`+N −M` 计数、`replace_all` 标记和多修改分块。它不读取目标文件，因此没有真实行号或未修改上下文；`Write` 明确提示展示的是完整写入内容、可能覆盖现有文件。预览有 200,000 字节输入预算、8 个修改块、每侧 12 行和单行 400 字符上限，超出时标注截断；它只帮助裁决，不参与 allow/deny。

**原生执行回执**：Claude 的 `PermissionRequest` 不带 `tool_use_id`，X Island 从同会话、同工具、同 `tool_input` 哈希、同子代理的 `PreToolUse` 记录中补齐 `tool_use_id`。对应的 `PostToolUse` / `PostToolUseFailure` 到达时，说明该工具已经越过权限阻塞，X Island 记为 `nativeResolved` 并只清这一张卡。没有唯一匹配时不清卡，仍由 310 秒租约兜底；原生拒绝没有等价回执。Claude `Stop` / `SubagentStop` 到达时，本轮原生提示必然已关闭，X Island 按 `originAgentID` 兜底清理当前和队列中的 Claude 权限请求并记 `nativeTurnEnded`；这不区分允许、拒绝或取消，也不能证明拒绝发生的瞬间。

**审批历史**：本地账本在偏好设置「审批记录」页可查看最近 500 条全量决定，可按 decision 过滤，也可按工具、会话或来源搜索。页面会校验 SHA-256 前序链并显示第一条断裂位置；可导出完整原始 JSONL 或在 Finder 中定位 `~/.xisland/approval-audit.jsonl`，导出文件同样为 `0600`。链校验只证明当前文件从第一行到当前行自洽，不证明整份文件没有被替换。

已有配置、其他插件、凭据和信任设置不会被通用模板强制替换；无法确认版本或配置归属时应保留原文件并按指南检查。

## 下一版接入流程（开发中）

开发版本已提供一键批量准备。X Island 只为检测到已安装、已启用且支持自动配置的客户端补齐缺失配置；已有配置不重复写入，已关闭的来源保持关闭。自动准备失败后不会持续重试，用户可再次点击批量准备明确重试。待完成项目集中展示，已准备和已连接项目折叠；主按钮会转到下一项需要处理的软件。

首次需要授权时，在对应客户端完成确认。Codex 的入口是输入区（Composer）的 **Review hooks**：核对命令，**仅勾选 X Island 项**，再点击 **Allow selected** 一次确认所选项。其他客户端仍按自己的插件启用、信任或外部入口要求操作。X Island 会自动回查可查询的授权状态，并记住当前配置的提醒与接通证据；配置未变且授权有效时无需每次启动重复确认，配置改变或授权被撤销后重新提示。收到有效活动后才显示“已接入”，配置文件存在本身不能证明授权或接通。

开发版本在设置页的 Codex“待授权”下直接显示操作路径，并提供“查看授权步骤”。点击后会定位到 Codex，已有窗口和已折叠的当前分组也适用；普通后台回查不会反复改变滚动位置。授权窗口默认展开审查与确认步骤，不需要再打开折叠详情；“打开 Codex 确认”只打开原客户端，仍由用户审阅并确认信任。

桌面客户端未找到或启动失败时，窗口会显示具体的下一步提示；只安装 CLI 不代表桌面应用可打开。启动按钮不会自动改为打开网页，用户可单独选择“打开完整指南”。重新检查会清除旧的启动错误，迟到的启动结果不会覆盖新的操作。

WorkBuddy 与 Kiro 只在 X Island 自有目录准备文件，可从窗口直接在 Finder 查看；仍需按各自指南导入或放置。Kiro 2.31.0 V3 是模板基线，不代表检测到该版本。其他外部 Agent、服务地址与启动参数继续保留各自的设置步骤。

窗口打开时自动回查授权结果，切回 X Island 时立即刷新；检查期间保持列表位置稳定。默认 Settings、`⌘,` 和状态栏设置入口已统一到真实设置面板，避免出现旧的空白设置窗。

设置页使用接入管理器已经检查的结果，不在绘制软件列表时同步读取客户端文件；尚无缓存时显示“尚未检查”。开发版本通过了 1162 项本地测试和 22 张界面样例检查；隔离打包应用的默认菜单、快捷键、普通启动、代理页及接入页开关已实机验证，未授予任何真实客户端信任。

本节描述尚未发布的开发版本，不改变下述 2.0.1 的发行测试记录或各客户端验收范围。

## 2.0.1：软件接入与授权

2.0.1 增加统一接入窗口。启动时检测实际安装的应用、CLI 或扩展，仅为已启用且支持自动配置的来源准备配置；历史配置目录本身不作为安装证据。菜单栏和设置的「软件接入与授权」可再次打开窗口。

| 状态 | 含义与下一步 |
| --- | --- |
| 待配置 | 当前配置不完整，点击「准备接入」重试 |
| 待授权 | 客户端明确报告尚未信任；点击「前往授权」，在原客户端审阅确认 |
| 待完成设置 | 需要导入插件、选择启动入口或连接外部服务，按该来源的步骤完成一次设置 |
| 等待活动 | 配置已准备，开始一条真实任务以确认接收链路 |
| 已接入 | 当前配置下收到有效活动；不代表该客户端的全部功能已经验收 |
| 检查失败 | 无法读取有效授权状态，不按已授权或已接通处理，可重新检查 |

Codex 通过只读 `hooks/list` 精确核对 X Island 命令的启用状态、信任状态和当前定义指纹。2.0.1 的窗口引导用户前往 Codex 的「设置 → 编码 → 钩子」；不会写入信任记录，也不会将其他 hooks 一并信任。其他客户端未提供可靠授权查询时不虚构“已授权”，以原客户端确认和实际事件为准。

WorkBuddy 插件及 Kiro 2.31.0 V3 模板会准备到 X Island 自有接入目录，可点击「查看接入文件」在 Finder 取用。文件按内容复用，不覆盖被修改的文件；导出不等于安装或信任。Kiro 的版本是模板基线，仍需用户核对实际版本与加载目录。需要外部 Agent、服务地址或启动参数的来源保留各自的设置步骤。

已展示的提醒和接通证据按配置指纹保存。同一配置不会每次启动都弹窗；配置变化、已确认授权被撤销或新软件被检测到时再提醒。关闭检查中的窗口也会记住该轮最终结果。失败的自动配置不会不停重试，成功配置后来丢失则可自动修复；「准备接入」允许显式重试。未授权仅影响该来源，其他来源可以继续使用。

本地验证包含状态/提醒持久化、并发刷新、有效事件接收、文件准备与保留、只读 Codex 探测及中英界面渲染。测试使用临时目录与独立偏好，不授予真实客户端信任；对应客户端的真实加载与完整任务仍按下方验收层级单独记录。

本轮接入改动通过了 1132 项 Swift 测试（0 失败、0 跳过）、10 张界面渲染和 Release 打包；打包桥接的 WorkBuddy 11 类合成事件通过隔离 socket 验证。最终发行产物校验以 2.0.1 验证摘要为准。

## 接入路线

“基础已实现”表示存在通过项目契约测试的指定通道，仍有下表限制；“待补齐”表示尚未具备可按当前范围交付的完整基础路线。

| 客户端 | 接入方式 | 基础状态 | 已知范围与限制 |
| --- | --- | --- | --- |
| Claude Code | 原生 settings hooks | 基础已实现 | 2.1.234 的隔离真实读取、岛上拒绝写入已通过；ExitPlanMode 已接入岛上计划审查路径（allow 回传 updatedInput，桥进程已验证）；并发权限队列、拒绝原因、修改参数后批准与拒绝并停止已过单元/桥进程测试，真实并发、子代理、TUI 和真实服务商待验 |
| Codex CLI / 桌面核心 | 原生 hooks.json | 基础已实现 | 12 类事件的项目契约已测；原生加载、工具和审批需在信任最终 hooks 后验证 |
| Gemini CLI（企业 / 付费 API Key） | 原生 settings hooks | 基础已实现 | 个人版已于 2026-06-18 停止；只保留企业 Gemini Code Assist 与付费 API Key，个人请用 Antigravity |
| Antigravity App / CLI / IDE | 命名分组全局 hooks | 基础已实现 | 五类官方事件契约已测；PreToolUse 只回中性 allow，不做岛上审批；真实 App/CLI/IDE 加载待验 |
| Cursor | 原生 hooks | 基础已实现 | 11 类事件契约已测；`beforeShellExecution` / `beforeMCPExecution` 只消费 `deny` / `ask`，岛上只提供拒绝与交回原生确认，不伪造 allow；桥不可用时回 `permission: ask`；文件读取、问答、具体版本与多 hooks 组合待验 |
| Trae / Trae CN / Solo | Trae CN 独立 hooks | 基础已实现 | 当前固定范围是 CN 协议；国际版和 Solo 不借用 CN 的验收结果。Claude Code hooks 路径的权限与 ExitPlanMode 计划审查路径已接入，独立 hooks 仍只观察。TRAE Work 已并入豆包工作 |
| 豆包工作 | STDIO 自定义连接器 + 活动上报 | 基础已实现（仅观察） | 无原生 hooks；只显示显式调用 xisland_activity 的动作，不接管审批、问答或取消，连接器断开即结束 |
| OpenCode | 专用插件 / 实例 SDK | 基础已实现 | 审批及单选、多选、自由文本通道已实现；实际宿主 SDK 和完整计划交互待验 |
| Factory Droid | 原生 hooks.json / settings | 基础已实现 | 已核对观察事件；没有已核实的 PermissionRequest，前置通知不提供伪造审批 |
| Qoder CN（原通义灵码） | 原生 settings hooks | 基础已实现 | 2026-05-20 更名；原生会话和子任务身份已处理；ExitPlanMode 计划审查路径已接入，IDE、完整问答及真实版本待验 |
| VS Code Copilot | Local hooks | 基础已实现 | Local 8 类事件已接入；Agent Host、Remote、自定义数据目录及完整交互另验 |
| CodeBuddy Code | CLI 原生 settings hooks | 基础已实现 | CLI 10 类观察事件已测；完整权限协议、IDE 和 WorkBuddy 分别验证 |
| Qwen Code | 原生 settings hooks | 基础已实现 | 已核对权限协议与身份关联；ExitPlanMode 计划审查路径已接入；完整问答和实际客户端待验 |
| Kimi Code CLI | Python / Node 独立 hooks | 基础已实现 | Node 2.1.1 的部分原生 ACP / Web API 场景通过；完整控制、回复、任务树和旧 Python 版本待验 |
| DeepSeek-TUI / Codewhale | 固定版本原生 hooks | 基础已实现 | 仅第三方 Codewhale 0.10.0 已核对的 14 类观察事件；旧版、实际客户端与交互待验 |
| Kiro CLI / IDE | 2.31.0 V3 独立配置显式导出 | 基础已实现 | 六类观察事件及配置合并/移除已测；真实CLI加载、审批、IDE和其他版本待验 |
| Amp | 专用 Plugin API | 基础已实现 | 4 类观察事件及模拟宿主通过；工具开始、审批和真实宿主待补验 |
| Pi | TypeScript extensions | 基础已实现 | 8 类观察事件及模拟宿主通过；实际宿主、版本和交互待验 |
| GLM 使用场景 | Claude Code / OpenCode / Cline / Pi 的模型元数据 | 基础已实现 | 保留客户端身份，显示、筛选和保存GLM模型；缺失字段不猜测，真实服务商与完整交互待验 |
| Aider | 显式进程包装器 + 通知 | 基础已实现 | 仅进程与通知观察；工具、轮次、原生交互和固定 0.86.2 实机待验 |
| Windsurf（已停用） | 原原生 snake_case hooks | 已停用 | 2026-06-02 应用更新为 Devin Desktop；旧会话保留，新接入请用 Devin Desktop |
| Devin Desktop / Devin CLI | 原生 hooks | 基础已实现 | 沿用原 Windsurf 应用身份；桌面端改名后的真实加载、云端会话与完整问答待验 |
| Amazon Q CLI（已并入 Kiro） | qchat 1.19.7 包装器 | 已停用 | 2025-11-17 更名 Kiro CLI；旧包装器只保留历史会话，新接入用 Kiro |
| Tabnine（Tricentis） | 旧版 CLI JSON hooks | 基础已实现 | 2026-07-30 被收购，6.x 为 OpenCode 分支；自动配置仅覆盖旧版，IDE 与 6.x 另验 |
| Cody（2027-01-31 EOL） | 显式 jsonrpc-stdio 包装器 | 降级保留 | 仅企业版可继续注册；普通 IDE 会话与审批仍待验，Amp 不共享此通道 |
| Cline VS Code / SDK CLI | VS Code 事件脚本 | 基础已实现 | 扩展 6 类事件已接入；启用与信任、实际版本、独立 CLI / SDK 及完整交互待验 |
| Continue（已停用） | cn serve /state 限时观察 | 已停用 | 2026-06 被 Cursor 收购，仓库只读；改接 Cursor，旧会话保留 |
| GitHub Copilot CLI | 原生 JSON hooks | 基础已实现 | 12 类观察事件已接入；审批输入、并发 ID 和实际版本待验 |
| Roo Code（已停运） | 任务事件观察扩展 | 已停用 | 2026-05-15 停运并归档；改接 Cline 或 Kilo Code，旧会话保留 |
| Kilo Code CLI / VS Code | 原生全局插件（OpenCode 内核） | 基础已实现 | 插件源码与适配器契约已测；真实 CLI / 扩展加载、权限状态与完整交互待验 |
| PearAI | Roo fork 实验观察扩展 | 基础已实现 | 默认关闭；固定 fork 3.15.3，实际发行产物与宿主待验，不覆盖 Continue fork |
| Zed | 显式外部 ACP Agent 包装器 | 基础已实现 | 仅包装的外部 Agent，权限留在编辑器；内置 AI 和实际客户端待验 |
| JetBrains AI / Junie | 显式外部 ACP Agent 包装器 | 基础已实现 | 仅包装的外部 Agent，不代表内置 AI Assistant 或所有 Junie 路径已适配 |
| WorkBuddy（额外客户端） | 手动导出观察插件 | 基础已实现 | 5.7.6 / 5.7.7 固定资源已静态核对；真实插件加载、任务触发与完整交互待验 |

## 安装与使用指南

- [复制给 LLM：接入配置提示库](llm-setup-prompts.md)
- [Aider 与 Codewhale](aider-codewhale-usage.md)
- [Zed / JetBrains 外部 ACP Agent](acp-setup.md)
- [豆包工作连接器](doubao-work-setup.md)
- [Kilo Code 原生插件](kilo-setup.md)
- [Amazon Q 旧 CLI（历史）](amazonq-setup.md)
- [Cody Agent](cody-setup.md)
- [Continue 服务状态观察（历史）](continue-setup.md)
- [WorkBuddy 观察插件](workbuddy-setup.md)
- [Kiro CLI V3](kiro-setup.md)
- [GLM 多客户端](glm-setup.md)
- [PearAI 扩展](../../Sources/XIslandVSCode/README.md)

## 怎样理解验证结果

| 层级 | 能证明什么 | 不能单独证明什么 |
| --- | --- | --- |
| 协议与版本核查 | 对应版本存在这些字段、事件或配置入口 | 实际客户端已加载配置 |
| 契约与编译桥接测试 | 合成输入经真实桥接进程正确转换和返回 | 厂商客户端实际发出相同事件 |
| 隔离应用验证 | 消息进入实际 X Island，界面状态和历史记录按预期变化 | 真实服务商、客户端所有界面或完整业务流程 |
| 隔离真实客户端验证 | 固定客户端在指定场景实际执行了工具或事件 | 未覆盖分支、其他版本、真实服务商或全产品验收 |
| 完整验收 | 约定版本、形态及功能范围全部经过目标客户端验证 | 当前没有任何一项达到此层级 |

Claude 与 Kimi 已有部分隔离真实客户端证据，均使用本地模拟模型；具体构建、场景与限制记录在[2.0.0 历史摘要](release-verification-2.0.0.json)。历史构建的通过结果不会自动转算为 v2.0.1 安装包的测试结果。

需要继续验证的权限、恢复、任务归属、版本和运行环境见[验收缺口](acceptance-gaps.md)。所有 30 项可接入条目与 5 个历史条目的 `complete` 仍为 `false`，基础接入完成率与完整验收完成率分别统计。
