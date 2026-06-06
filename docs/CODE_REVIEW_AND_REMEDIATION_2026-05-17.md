# X Island 代码审查与修复执行文档

**日期：** 2026-05-17  
**范围：** 逻辑问题、Bridge 生命周期、测试与文档、死代码清理  
**审查方式：** 源码静态分析、`swift test`、GitHub README 对照、UI 测试驱动（GUI 环境受限）

---

## 1. 执行摘要

X Island 是 macOS 原生 SwiftUI 应用（非 Web）。本次审查发现 **2 个 P0 级 Bridge 挂起问题**（待交互清除/会话关闭未回调 `di-bridge`），以及若干 P1–P3 项。本文档记录问题详情、修复方案与执行状态。

| 优先级 | 问题数 | 说明 |
|--------|--------|------|
| P0 | 2 | Bridge 进程阻塞，Agent 可能卡死 |
| P1 | 4 | 自动模式/权限策略/连接失败/MuteRule 语义 |
| P2 | 3 | 测试隔离、文档、回归测试 |
| P3 | 4 | 死代码、定时器、配额展示（部分本次执行） |

---

## 2. 审查环境

```bash
swift test                    # 192 tests（修复前 1 failed）
bash Scripts/test-ui.sh smoke # GUI 环境超时（无显示器时预期失败）
```

**失败用例（修复前）：** `AudioEngineTests.testMuteRulesEmptyByDefault` — `setUp` 未清理 `audio.muteRules`，读取本机 UserDefaults。

---

## 3. 问题清单与修复方案

### 3.1 P0 — Bridge 挂起（必须修复）

#### 问题 A：`clearStaleInteraction` 未回调 Bridge

**位置：** `SessionManager.swift` → `clearStaleInteraction`

**现象：** 当用户在终端内已批准权限/回答问题，随后 Agent 发出 `toolStart` 等消息时，Island 会清除 UI 上的 `pendingPermission` / `pendingQuestion`，但**不调用** `respond` / `cancel`。`di-bridge` 在交互类 hook 上会阻塞等待 Socket 响应（最长 300 秒），导致 Agent 挂起。

**根因：**

```swift
// 修复前：仅清空状态
session.pendingPermission = nil
session.status = .active
```

**修复方案：** 引入 `releasePendingInteraction(_:reason:)`：

| 场景 | 权限 | 问题 | 计划 |
|------|------|------|------|
| `supersededByActivity`（终端已处理，Agent 继续） | `respond(true)` | `cancel?()`，若无则 `respond(首项或"")` | `respond(true, nil)` |
| `userDismissed`（用户关闭会话卡片） | `respond(false)` | `cancel?()` | `respond(false, nil)` |

**验收：**

- [x] `testToolStartClearsPendingPermissionInteraction` 断言 `respond` 收到 `true`
- [x] `testToolStartClearsPendingQuestionInteraction` 断言 `cancel` 或 `respond` 被调用
- [x] 新增 `testDismissSessionReleasesPendingPermissionWithDeny`

---

#### 问题 B：`dismissSession` 未释放待交互

**位置：** `SessionManager.dismissSession`、右键「关闭所有会话」

**现象：** 用户关闭含待审批/待回答的会话卡片时，会话从列表移除，Bridge 仍阻塞。

**修复方案：** 在 `removeAll` 之前调用 `releasePendingInteraction(session, reason: .userDismissed)`。

**验收：**

- [x] 新增单元测试验证 dismiss 时 `respond(false)` / `cancel`

---

### 3.2 P1 — 行为与安全

#### 问题 C：Bypass 模式对多选题一律选第一项

**位置：** `handleQuestionRequest`

**风险：** 自动模式可能选错选项并继续执行危险操作。

**修复：** 仅在 `options.count == 1` 时自动 `respond(firstOption)`；多选题仍展示 Island UI（即使 `bypassMode == true`）。

**验收：**

- [x] `testBypassModeAutoAnswersOnlySingleOptionQuestion`

---

#### 问题 D：OpenCode `external_directory` 一律自动批准

**位置：** `handlePermissionRequest` OpenCode 分支

**风险：** 目录类权限应经用户确认。

**修复：** 仅保留 **空占位** 权限（`tool`/`desc`/`path`/`diff` 皆空）自动批准；`external_directory` 走正常审批 UI。

**验收：**

- [x] 更新 `testOpenCodeExternalDirectoryPermissionIsAutoApprovedAndNotShown` → 改为期望 **不** 自动批准

---

#### 问题 E：`MuteRule.matchField == .tool` 匹配错误字段

**位置：** `MuteRule.matches`

**现象：** 文档写「按工具名」，实现匹配 `SoundEvent.rawValue`（如 `permission_request`）。

**修复：** 优先匹配 `session.currentTool`，为空时回退 `events.last?.tool`。

---

#### 问题 F：Socket 连接失败时交互 hook 静默 `exit(0)`

**位置：** `DIBridge.connectSocket` 失败分支

**修复：** 交互类消息（permission/question/plan）连接失败时 `exit(1)`，非交互保持 `exit(0)`。

---

#### 问题 G：`scheduleLingerCleanup` 重复调度

**修复：** 使用 `lingerCleanupGeneration` 计数器，仅最新一代触发 `visibleSessionsVersion`  bump。

---

### 3.3 P2 — 测试与文档

| 项 | 修复 |
|----|------|
| `testMuteRulesEmptyByDefault` | `setUp`/`tearDown` 清理 `audio.muteRules` |
| README 测试数量 | 125 → 192 |
| 回归测试 | `SessionManagerInteractionReleaseTests` 或扩展现有文件 |

---

### 3.4 P3 — 架构与性能（本次部分执行）

| 项 | 动作 | 状态 |
|----|------|------|
| `IslandHoverManager.swift` | 未被引用，删除 | 执行 |
| Hover 10Hz 轮询 | 保留（NotchContentView 仍需） | 暂不降频 |
| Anthropic 配额探测发真实 messages | 记入后续优化 | 未改 |
| `NotchContentView` 体量过大 | 记入后续重构 | 未改 |

---

## 4. 已知未修复项（后续迭代）

1. **`handleStatus` 子串误判 error** — 需 Agent 结构化错误字段或白名单。
2. **CLI Agent `sessionEnd` → `.idle`** — 需产品决策：立即 completed vs 等待进程退出。
3. **问题去重 2s `contains` 窗口** — 可能误匹配，建议改为规范化 question id。
4. **配额 UI** — Kimi/DeepSeek 余额字段语义与 `formatTokens` 不一致。
5. **UI 测试** — 需在带 GUI 的 macOS 上跑 `Scripts/test-ui.sh`。

---

## 5. 执行记录

| 步骤 | 内容 | 状态 |
|------|------|------|
| 1 | 创建本文档 | ✅ |
| 2 | `SessionManager` Bridge 释放逻辑 | 见 git diff |
| 3 | Bypass / OpenCode / MuteRule / DIBridge / linger | 见 git diff |
| 4 | 测试 + README + 删除 `IslandHoverManager` | 见 git diff |
| 5 | `swift test` 全绿（194 tests, 0 failures） | ✅ |

---

## 6. 验证命令

```bash
# 单元测试
swift test

# 集成测试（需已安装并运行 App）
bash Scripts/test-all.sh

# UI 冒烟（需 GUI）
bash Scripts/test-ui.sh smoke
```

---

## 7. 参考代码位置

| 模块 | 路径 |
|------|------|
| 会话与交互 | `Sources/DynamicIsland/Managers/SessionManager.swift` |
| Bridge CLI | `Sources/DIBridge/DIBridge.swift` |
| Socket 服务 | `Sources/DynamicIsland/Managers/SocketServer.swift` |
| 静音规则 | `Sources/DynamicIsland/Models/MuteRule.swift` |
| 灵动岛 UI | `Sources/DynamicIsland/Views/NotchContentView.swift` |
| 回归测试 | `Tests/TowerIslandTests/SessionManagerStatusTests.swift` |

---

*本文档由代码审查生成，并与同次提交的代码修复保持一致。*
