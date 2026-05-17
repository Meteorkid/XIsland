# Changelog

## v1.5.1 (2026-05-17)

本版为**相对上一正式发布 [v1.4.0](https://github.com/Meteorkid/XIsland/releases/tag/v1.4.0) 的汇总更新**：在 v1.4.0 的 Agent 扩展、面板与勿扰、Bypass、子 Agent 可视化等能力之上，补上**长时间运行稳定性**、**可配置的展开/收起节奏**，并做了一轮**结构重构与测试补强**。

### 与 v1.4.0 对比（高层）

| 维度 | v1.4.0 | v1.5.1 |
|------|--------|--------|
| 长时间挂机 / 多会话 | 偶发主线程卡死、CPU 飙高 | 终端跳转、Keychain、窗口枚举等迁至后台；Hover 轮询降频并在视图消失时停止；窗口释放 Timer/观察者 |
| 展开后无操作收起 | 固定约 **10s** | **偏好可调**（秒），可选 **永不** |
| 鼠标离开岛后收起 | 固定 **0.5s** | **偏好可调**（多档），可 **关闭** 该规则 |
||| `IslandSizeCalculator` 统一尺寸计算；`SessionManager` 去重 session 查找链 |
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
