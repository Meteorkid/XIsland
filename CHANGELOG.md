# Changelog

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
