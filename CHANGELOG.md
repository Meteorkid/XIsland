# Changelog

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
