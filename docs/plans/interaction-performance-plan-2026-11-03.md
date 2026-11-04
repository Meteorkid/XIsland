# X Island 交互与性能收敛方案

> 立项日期：2026-11-03
> 依据：`docs/design/hooks-installer-comparison.md` 与四家竞品源码核查
> 状态：P0 执行中

## 一、目标与边界

**目标**：解决三类已确认的实际问题——任务抢位导致内容频繁换位、多实例动画时钟的能耗浪费、Hermes 接入基于过时判断。

**不做的事**（明确排除）：

- 不引入 coucou 的 Mochi 形象、表情动画、音效、图标（其 `LICENSE-ASSETS.md` 明确限制）
- 不复制 MioIsland 任何代码（CC BY-NC 4.0，本项目含付费授权，属 NonCommercial 禁止范围）
- 不把 CodeIsland 的 20fps 直接套到果冻动画与双指跟手切换——帧率必须实测后定
- 本轮不改发布签名流程（需 Developer ID 证书，属外部条件）

---

## 二、现状盘点

| 能力 | 现状 | 证据 |
|---|---|---|
| 收起态任务排序 | ⚠️ 存在两套互不一致的排序 | `CollapsedTaskSelection.swift` 与 `RotatingSessionIcon.sortedSessions` |
| 收起态轮播停留 | ✅ 已有，按状态分档 | `CollapsedPillView.swift:341-350`（error/waiting 5s，运行 0.8s） |
| 收起态最短驻留 | ❌ 无 | 无跨重算的状态，顺序随 `lastActivityTime` 抖动 |
| 失败态独立优先级 | ❌ 无（外层排序） | 排序键只有 pending / needsReview / 时间 |
| 展开自动收起 | ✅ 已有，纯函数参数化 | `ExpandedAutoCollapsePolicy.swift` |
| 展开原因决策 | ⚠️ 分散在 View 内 | 无 `(surface × trigger)` 矩阵 |
| 连续动画门控 | ✅ 已有 3 布尔判断 | `IslandMotionPolicy.swift` |
| 共享动画时钟 | ❌ 无 | 4 个文件各自 `TimelineView`，起点均为 `.now` |
| 能耗档位 | ❌ 无 | 无 active/background/suspended 区分 |
| Hermes 接入 | ⚠️ 手动 wrapper + 空 JSON | `ZeroConfigManager.swift:962-985` |
| 配置写入安全 | ✅ 五家最强 | `HookConfigurationFile.swift` |
| JSONC 注释保留 | ❌ 全量重写即丢 | `HookConfigurationFile.swift:40` |

**关键判断**：写入链路（`HookConfigurationFile`）不需改动，其双重 CAS + fsync 已超过四家竞品。本轮所有改动都在**展示层与会话选择层**，不触碰注入内核，风险可控。

**根因修正（执行中发现）**：换位的直接原因并非"没有驻留时间"，而是**两套排序并存**——
`CollapsedTaskSelection` 按「待处理 > 完成待查看 > 活动时间」排，`RotatingSessionIcon` 又按
`SessionStatus.statusPriority` 二次排（该表把 `error` 定为最优先、`completed` 定为最末）。
两者档位不一致导致顺序翻转；而轮播用 `index` 定位，顺序一变同一个 `elapsed` 就指向另一个会话，
表现为内容突然跳变。因此修复的重点是**统一排序 + 锁定顺序**。


---

## 三、四项工作的方案

### 工作项 1：收起态展示稳定性（P0）

**问题**：`CollapsedTaskSelection.select` 是无状态纯函数，每帧重算。两个任务优先级相近且都在活动时，`lastActivityTime` 的微小变化会导致显示内容在两者间跳动。

**参照 coucou**：`SessionBoard.swift:138-141` 的 minHold 机制——只有当新任务优先级**严格更高**时才允许抢占，同级或更低要等驻留时间过去。

**设计**：新增 `CollapsedBoardState`（`@Observable`），持有 `shownId + shownSince`，对外暴露稳定的选择结果。

**规则**：

1. `hasPendingInteraction` 永远可立即抢占（用户正在等的不能被延迟）
2. 其余任务：新候选优先级必须**严格高于**当前，或当前已过 `minHold`（建议 1.2s），才允许切换
3. 新增第 2 优先级档：`status == .error` 且发生在最近 60s 内（coucou 的 `errorMoment`），排在 pending 之后、needsReview 之前
4. 排序尾部必须有确定性兜底（现已有 `lhs.id < rhs.id`）

**改动文件**：

- `Sources/DynamicIsland/Models/CollapsedTaskSelection.swift`（加 error 档 + minHold 逻辑）
- `Sources/DynamicIsland/Views/CollapsedPillView.swift`（持有状态，传入 shown/since）
- `Tests/`（新增排序与驻留单元测试）

**验收**：构造两个同优先级任务交替活动，1.2s 内显示内容不切换；出现 pending 任务时立即切换。

### 工作项 2：共享动画时钟（P0）

**问题**：`MascotView` 用 `TimelineView(.periodic(from: .now, by: 0.15))`，且 `.now` 作起点意味着**每个实例相位不同**。收起态显示 3 个任务时最多 3 个独立 timer 非对齐唤醒。

**参照 CodeIsland**：`FrameClock.swift:73-118` —— 单例 `FrameTicker`，`beat(every:)` 订阅不同间隔，`tick % beat.steps == 0` 分频，**无订阅者时循环条件自然退出**。

**关键澄清**：`step` 是**网格粒度**，不是所有动画的帧率。果冻动画可订阅 `beat(every: 1/60)`，只要网格细于它。

**设计**：

```swift
@MainActor final class FrameTicker {
    static let shared = FrameTicker()
    nonisolated static let grid: TimeInterval = 1.0 / 60
    private var beats: [Int: Beat] = [:]
    private var task: Task<Void, Never>?
    func beat(every interval: TimeInterval) -> Beat
    // 循环条件：任一 beat 的订阅数 > 0
}
```

**接入范围（本轮只改吉祥物）**：

| 文件 | 现值 | 改为 |
|---|---|---|
| `MascotView.swift:32` | `.periodic(from: .now, by: 0.15)` | 订阅共享 ticker |
| `MarqueeText.swift` | 独立 TimelineView | 保持，下轮评估 |
| `CollapsedPillView.swift` | 2 处 | 保持，下轮评估 |
| `NotchContentView.swift` | 1 处 | 保持，下轮评估 |

**不改果冻动画与双指切换**——它们的帧时间必须实测，不能凭推测设帧率。

**新增文件**：`Sources/DynamicIsland/Managers/FrameTicker.swift`

**验收**：收起态 3 个任务时，timer 唤醒从 3 路降至 1 路；隐藏窗口后 ticker 自动停（`isRunning == false`）。

### 工作项 3：Hermes 接入修正（P1）

**问题**：现有代码基于错误前提。

**必须先修的三处**（`ZeroConfigManager.swift:962-985`）：

1. 删除错误注释 `// Hermes does not have a formal hook system.`——Hermes 官方有 4 套 hook 系统（Gateway / Plugin / Shell / Outbound）
2. `echo '{}' |` 改为可传入真实事件负载
3. 硬编码 `/Users/$USER/...` 改为 `$HOME`；`SESSION="hermes-$(pwd)"` 会因同目录多会话而撞，改为接收真实 session id

**接入注意事项（来自官方文档核查）**：

- Hermes 的 `pre_tool_call` shell hook 是 **fail-closed**：超时或异常会**阻断工具调用**，与 Claude Code 的 fail-open 相反。bridge 必须在 timeout 内必定返回，且不能成为单点
- `pre_approval_request` 是 **observer，仅观察，不能否决**——审批必须走 `pre_tool_call`
- `pre_tool_call` 返回格式兼容 Claude 形状 `{"decision": "modify", "tool_input": {...}}`，可复用现有 payload

**本轮只做**：修掉三处错误 + 在代码标注 fail-closed 风险。完整 hook 接入需实测（固定 Hermes 版本，验证观察/工具事件/完成中断/续问四项），单独立项。

### 工作项 4：JSONC 注释保留与备份可见（P1）

**问题 A**：`HookConfigurationFile.update` 用 `JSONSerialization` 全量重写，用户 `settings.json` 的注释与键序全部丢失。

**问题 B**：备份名 `.settings.json.xisland-{UUID}.bak` —— 隐藏文件、UUID 命名，用户无法自行恢复。

**方案**：

- B 立即改：`settings.json.bak-{yyyyMMdd-HHmmss}`，含同秒去重（coucou `freeBackupURL` 模式）
- A 分两步：先加**注释检测**——发现原文件含注释则跳过自动写入并提示，附 diff；确认无副作用后再做局部替换

**改动文件**：`HookConfigurationFile.swift:40`、`:153`

---

## 四、执行顺序

| 批次 | 内容 | 依赖 | 风险 |
|---|---|---|---|
| P0-a | minHold + error 优先级 | 无 | 低，可单测 |
| P0-b | FrameTicker + MascotView | 无 | 低，可 sample 验证 |
| P1-a | 备份命名改可见 | 无 | 最低，单点改动 |
| P1-b | Hermes 三处错误修正 | 无 | 低 |
| P2-a | 二维展开矩阵 + popOut | P0-a | 中，需交互回归 |
| P2-b | 能耗档位 | P0-b | 中，需功耗实测 |
| P3-a | JSONC 局部替换 | P1-a | 中高，需充分回归 |
| P3-b | Hermes 完整接入 | P1-b | 中，需固定版本实测 |

**分批原则**：每批独立可编译、可测试、可回滚。P0-a、P0-b、P1-a、P1-b 互不依赖，可并行。

## 五、验收口径

不做"实测更流畅"这类无依据表述。每项以可观测指标验收：

- **P0-a**：单测覆盖 4 种抢占场景（同级/更高级/pending/超时）
- **P0-b**：`isRunning` 生命周期单测 + `sample` 观察 timer 数量
- **P1-a**：备份文件出现在用户可见目录，命名含时间戳
- **P1-b**：生成的 wrapper 在不同家目录名的机器上可执行

## 六、已知未决

1. `minHold` 取 1.2s 是参照 coucou 的经验值，需在你的实际使用节奏下复核
2. `errorMoment` 取 60s 同理
3. 果冻动画与双指切换的目标帧率**未定**，需 Instrument 实测帧时间后决定
4. 签名发布依赖 Developer ID 证书，当前不具备，不纳入本轮

---

## 七、执行记录（2026-11-03）

### 已完成

| 批次 | 改动 | 文件 |
|---|---|---|
| P0-a | 新增 `rank()` 五档优先级，`error` 提到档 1、`pending` 保持档 0 | `Models/CollapsedTaskSelection.swift` |
| P0-a | 新增 `stableSelection()`：集合不变锁定顺序 + `minHold` 驻留 | 同上 |
| P0-a | **删除** `RotatingSessionIcon` 内部的 `statusPriority` 二次排序 | `Views/CollapsedPillView.swift` |
| P0-a | View 持有 `displayedOrder`，用 `onChange` 回写 | 同上 |
| P0-b | 新增 `FrameTicker`：单例、60Hz 网格、分频、无订阅者停钟 | `Managers/FrameTicker.swift`（新） |
| P0-b | 新增 `SharedFrameClock` 视图包装，订阅生命周期挂 `.task` | 同上 |
| P0-b | `MascotView` 从独立 `TimelineView` 改为共享时钟 | `Views/Components/MascotView.swift` |
| P1-a | 备份改为 `settings.json.bak-yyyyMMdd-HHmmss`，同秒去重 | `Models/HookConfigurationFile.swift` |
| P1-b | 删除 Hermes 过时注释、去掉 `echo '{}'`、`$HOME` 替代 `$USER`、session id 改用环境变量 | `Managers/ZeroConfigManager.swift` |

### 验证

```
swift build --disable-sandbox          → BUILD_EXIT=0
swift test --filter CollapsedTask      → 22 tests, 0 failures (1 skipped)
swift test                             → 1851 tests, 0 failures (19 skipped)
```

> 注意：`swift build | tail` 的退出码取自 `tail`，会掩盖编译失败。构建脚本必须检查 `swift build` 自身的退出码，或加 `set -o pipefail`。

### 执行中修正的测试缺陷

备份命名从 `.settings.json.xisland-{UUID}.bak` 改为 `settings.json.bak-{时间戳}` 后，
`HookConfigurationFileTests` 有 4 项失败。其中一处暴露出旧测试的**无效断言**：

`testUpdatesDoNotReuseExistingBackupOrTemporarySymlinks` 原本预置一个名为
`.settings.xisland-existing.bak` 的符号链接，指望它撞上新建的备份名——但旧命名含 UUID，
**永远不可能撞上**，该测试事实上从未验证过它声称保护的行为。

改用可预测的时间戳命名后，测试改为预置「当前秒 / 前一秒」两条同名符号链接，才真正触发
`O_EXCL` 分支。这是新命名带来的附带收益：**备份名可预测，所以必须被验证**。


### 未做（按计划后置）

- P2-b 能耗档位（`EnergyGovernor` 式 5 档）
- P3-a JSONC 局部替换
- P3-b Hermes 完整 hook 接入（需固定版本实测）
- 签名发布

---

## 八、P2-a 实现记录（2026-11-04）

### 做了什么

新增 `Models/IslandExpansionRouter.swift`：把 6 个展开入口的守卫条件收敛为一个纯函数决策器。

**触发源与优先级**（用户意图 > 系统提示）：

| 触发源 | 语义 | 会被什么拦住 |
|---|---|---|
| `.click` | 用户点击药丸 | 仅展开动画进行中 / 跨应用切换 |
| `.autoInteraction` | 出现待处理请求 | 无目标；跨应用切换时改为"等切换完" |
| `.notification` | 任务提醒 | 无可见会话；有阻塞项时改为呈现对应面板 |
| `.hover` | 悬停 | 开关关闭 / 终端聚焦抑制 / **已展开** |
| `.scroll` | 滚轮 | 冷却 0.5s / 已展开 / 收起动画中 |

`NotchContentView` 中 4 处调用改为走路由（click / hover / scroll / autoInteraction）；
另外 2 处（通知分支、Agent Flow 入口按钮）是**已决策后的动作**，保留原样。

### 附带修复的既有缺陷

悬停分支在收敛前没有"已展开"判断：

```swift
if !manager.visibleSessions.isEmpty {
    if !hoverToExpandPanel { return }
    if smartSuppression && isAgentTerminalFocused() { return }
    expand(to: .expanded)          // 已展开时会把 permission 面板切回总览
}
```

`expand(to:)` 内部只防并发（`expandPending`），不防重复展开。因此**在审批面板展开时，
鼠标在岛内移动会把面板切回总览**。收敛后由 `!isExpanded` 拦住。

### 未采纳 popOut

coucou 的 `popOut`（多会话争用一个 pill 时，把等待项弹出去独立成 pill）**不适用于本项目**：

- coucou 的收起态是**一个 pill 只显示一个会话**，多会话必须争位，所以需要"分身"释放冲突
- X Island 的收起态是**多图标平铺（最多 5 个）+ 单图标轮播**，冲突靠排序与锁定解决，
  不存在"争夺单一显示位"的结构性问题

强行引入会让收起态同时存在两种空间模型（平铺 + 弹出岛），复杂度收益比不成立。
若将来收起态改为"只显示一个会话"，再重新评估。

### 验证

```
swift build --disable-sandbox                    → BUILD_EXIT=0
swift test --filter IslandExpansionRouter        → 13 tests, 0 failures
swift test                                       → 1864 tests, 0 failures (19 skipped)
```

较上一批（1851）增加 13 项，全部为新增的路由决策测试。

---

## 九、P2-b / P3-a / P3-b 实现记录（2026-11-04）

### P2-b 能耗档位

新增 `Managers/EnergyGovernor.swift`：5 档（active / idleVisible / quietBackground /
systemSuspended / wakeGrace），由锁屏、睡眠、唤醒与会话活动驱动。

**订阅源**（复用系统通知，不新增轮询）：

| 事件 | 来源 |
|---|---|
| `willSleep` / `screensDidSleep` | `NSWorkspace` |
| `didWake` / `screensDidWake` | `NSWorkspace` |
| `screenIsLocked` / `screenIsUnlocked` | `DistributedNotificationCenter` |

后两项必须单独订阅：**仅锁屏（Ctrl+Cmd+Q）不触发 `willSleep`**。

**判定优先级**：`suspended > wakeGrace > 面板展开 > 闲置时长`。
面板展开时即使闲置一小时也保持 `active`——用户正看着，不能把动画停掉。

**唯一消费点**：`FrameTicker`。`animationLevel == .staticFrames` 时不推进、也不再启钟。
改动集中在时钟一处，所有共享时钟订阅者自动受益，无需逐个改 View。

**刻意没做的**：`idleVisible` 仍是 `full`。没有实测帧时间之前，不臆造降帧比例——
这正是上一轮拒绝照搬 20fps 的同一条原则。

活动时间来源：`SocketServer` 收到有效消息时 `noteActivity()`；面板展开/收起时
`notePanelExpanded(_:)`；应用启动时 `start()`。

### P3-a JSONC 注释保留

新增 `Models/JSONTextSurgery.swift`（约 190 行）：只替换**顶层**某个键的值，其余字节原样保留。

**两项前置改动**：

1. `HookConfigurationFile.configuration(from:)` 现在会先按标准 JSON 解析，失败再剥注释重试。
   此前含注释的 `settings.json` **根本读不出来**，也谈不上保留。
2. `update` 走新的 `encode(_:preservingCommentsOf:)`：仅当原文件**含注释**且能通过
   "剥注释后语义完全等于目标文档"的校验时，才使用局部替换；任一条不满足则回退全量重写。
   无注释的文件行为完全不变。

**为什么做得这么窄**：这是用户配置文件的核心写入路径。能力边界收在
"替换已有顶层键的值"，不新增键、不处理嵌套、不猜结构，任何不确定都返回 `nil` 交给回退。

### P3-b Hermes 接入（部分完成）

已完成：修正过时注释、去掉丢弃事件的 `echo '{}'`、`$USER`→`$HOME`、session id 改用
`${HERMES_SESSION_ID:-hermes-$$}`、补充 fail-closed 保护与文档链接。

**未做自动注册，理由**：本项目无 YAML 解析依赖，用手写文本插入去改用户的
`config.yaml`，格式判断一旦失误就是破坏性写入；且环境里没有 Hermes 可实测。
改为在 `~/.xisland/bin/HERMES-SETUP.md` 生成一份说明，由用户粘贴、可自行撤销。

### 签名发行

不执行。缺 Developer ID 证书与公证凭据，无法产生可验证产物。
清单见 `docs/releases/signing-checklist.md`，含"先签内层再签外层""di-bridge 必须独立签名"
两个容易踩错的点。

### 本批验证

```
swift build --disable-sandbox                          → BUILD_EXIT=0
swift test --filter "JSONTextSurgery|HookConfigurationFile|EnergyGovernor"
                                                       → 32 tests, 0 failures
swift test                                             → 1880 tests, 0 failures (19 skipped)
```

较 P2-a 的 1864 增加 16 项：7 项能耗档位、8 项 JSON 文本手术、1 项 JSONC 端到端注释保留。

---

## 十、自我审计与修复（2026-11-04）

上一批交付后做了一轮自查，发现 **5 个真实缺陷**。按严重度排序：

### 1. 伴端命令从未接通（严重）

`CompanionPublisher.onCommand` 从未被赋值，`start()` 从未被调用，`allowsRemoteDecisions`
永远是 `false`。**手机上的按钮即使点亮也什么都不会发生**——伴端是个空壳。

修复：
- `SessionManager` 新增 `handleCompanionCommand(_:)`，接到已有的
  `approvePermission` / `denyPermission` / `answerQuestion` / `respondToPlan`
- 两道校验：会话必须仍存在，且必须仍处于对应等待态。
  缺第二道会在用户已于 Mac 处理过时重复 `respond`，向已关闭的 socket 写数据

### 2. 能力位无法下发到伴端（严重）

iOS 端 `remoteDecisionsAllowed` 是 `private(set)` 且从未被赋值，**按钮永久置灰**。
Mac 端即便打开开关也传不过去——因为协议里根本没有这个字段。

修复：`CompanionSnapshot` / `CompanionDigest` 新增 `allowsDecisions`。
**解码时缺失按 `false` 处理**：旧版 Mac 不带该字段，安全侧必须收紧，
否则任何连上来的设备都能自行放开审批权。

### 3. FrameTicker 竞态导致动画永久停摆（中）

旧循环退出时执行 `tickerTask = nil`。若此刻 `reevaluate()` 刚启动新一轮 task，
旧循环会把新 task 清成 nil，而 `isRunning` 变 false 后无人再启动它。

修复：引入 `taskGeneration` 代号，只有代号未变时才允许清空。

### 4. 分频用取模，一次睡眠超时就跳过整拍（中）

`tickIndex % beat.steps == 0` 在 `Task.sleep` 不准时会导致该档动画卡住，
直到下一次对齐——表现为偶发短暂停顿。

修复：改为判断"距上次推进是否已过一个间隔"，天然容忍抖动，最多晚一个间隔。
同时给 `lastAdvancedAt` 加 `@ObservationIgnored`，否则每次 tick 会多触发一轮无关重绘。

### 5. 动画时钟未统一，能耗策略有漏洞（中）

`MarqueeText` 用 `TimelineView(.animation)`（按屏幕刷新率驱动）、
`RotatingSessionIcon` 仍用 `.periodic`——**两者都不受能耗档位约束**，
锁屏后仍在唤醒。

修复：两者均改为 `SharedFrameClock`。现在全应用只剩一个时钟，
能耗策略一次生效。

### 附带

- `EnergyGovernor` 补 `stop()`，此前观察者与评估任务没有清理路径
- `CompanionPublisher.publish` 过滤掉空闲会话，只推待处理与运行中的
- `CompanionConnection` 的 `import UIKit` 从文件中部移到头部
- 手表端在 Mac 未开启远程审批时显示"需在 Mac 上处理"，而不是给两个按不动的按钮

### 本批验证

```
swift build --disable-sandbox                    → BUILD_EXIT=0
swift test                                       → 1902 tests, 0 failures (19 skipped)
swiftc -typecheck (iphonesimulator)              → 0 errors
swiftc -typecheck (watchsimulator)               → 0 errors
```

新增 11 项测试：6 项共享时钟（含竞态回归）、4 项能力位、1 项空摘要容错。

### 仍然没有解决的

1. **端到端未跑通**：Mac ⇄ iPhone 的 Multipeer 配对、iPhone ⇄ Watch 的
   `applicationContext` 送达时机，都还没在真机上验证过
2. **iOS 后台保活**：系统会在后台挂断 Multipeer，需要推送或延长后台任务配合
3. **Live Activity / 表盘 complication**：未实现
4. **无运行时性能数据**：`sample` / Instruments 一次都没跑过，
   因此"更省电"这个结论**依然没有证据**

---

## 十一、第二轮审计与修复（2026-11-04 中午）

对照四家源码再查一轮，又发现 **5 个真实缺陷**。

### 1. 伴端同步漏掉两条会话删除路径（严重）

`publish` 只接在 `handleMessage` 上。但会话被移除有两条独立路径：

| 路径 | 位置 | 后果 |
|---|---|---|
| 用户手动关闭会话 | `dismissSession` | 手机上残留已关闭的会话 |
| 超时淘汰已完成会话 | `cleanupLingeredSessionsImmediately` | 手机上堆积过期会话 |

修复：新增 `publishToCompanion()` 作为**唯一入口**，并接上两条删除路径。
刻意做成一个方法而不是到处直接调 `publish`——上一轮就是因为分散调用漏了两处。

### 2. 新设备连上时补发的是过期数据（中）

`publish` 在无连接时提前返回，所以 `lastSnapshot` 可能停留在很久以前。
`sendCurrentState()` 原本优先发缓存，等于**刚连上的手机看到一批早已结束的会话**。

修复：改为优先向上层索要实时数据，缓存只作兜底。

### 3. 残留 4 处 TimelineView，能耗策略仍有漏洞（中）

上一轮只改了 `MascotView`。实际还有：

- `MarqueeText` 用 `.animation`（按屏幕刷新率驱动）
- `CollapsedPillView` 的图标轮播、计数轮播
- `NotchContentView` 的 ticker 轮播

**这四处都不受能耗档位约束，锁屏后仍在唤醒。** 已全部改为 `SharedFrameClock`，
现在 `Sources` 里 `TimelineView(` 的出现次数为 **0**（仅剩注释）。

### 4. 伴端功能没有开关入口（中）

`CompanionPublisher` 默认关闭，但设置界面里**没有任何开关**——
功能等于永远无法启用。

修复：新增 `CompanionSettings`（集中管理键名与默认值），
`PreferencesView` 增加两个开关（广播 / 允许远程审批），`AppDelegate` 接线。

### 5. 用户删掉的 hook 事件会被自动加回（中）

借鉴 CodeIsland #182。我们的 `isConfigured` 只判断"配置是否完整"，
用户若有意删掉某个事件（比如某事件在他项目里频繁干扰），
点"检查修复"会**把删掉的加回来**，而且他会以为设置没生效。

修复：新增 `HookDriftPolicy`，接入 `shouldRepairNativeHooks`。
判定不依赖各配置类型的 private `isOwned`，而用「移除操作是否改变配置」等价判断：
- 移除后**有变化** → 存在我们的条目 → 剩余缺失视为用户有意删减 → 不修复
- 移除后**无变化** → 从未安装 → 正常安装
- 结构过期（旧版字段）→ 优先重写，不保留

### 本批验证

```
swift build --disable-sandbox        → BUILD_EXIT=0
swift test                           → 1915 tests, 0 failures (19 skipped)
swiftc -typecheck (iphonesimulator)  → 0 errors
swiftc -typecheck (watchsimulator)   → 0 errors
TimelineView( 残留                   → 0 处（仅注释）
```

新增 13 项测试：8 项伴端同步（含删除路径与命令校验）、5 项漂移策略。

### 两轮审计的共同教训

两次都是**"测试全绿但功能是死的"**。根因一致：

> 单测覆盖的是纯函数，覆盖不到"谁调用它"。

协议层、策略层测试可以全绿，而 `start()` 从未被调用、`onCommand` 从未被赋值、
设置里没有开关。**接线错误是测试盲区**，只能靠读代码发现。

因此后续新增功能时，必须显式检查三件事：入口是否被调用、
回调是否被赋值、开关是否可达。

---

## 十二、第三轮审计与修复（2026-11-04 下午）

### 1. 快照与摘要共用序号导致 iOS 端丢数据（严重）

Mac 端一次 `publish` 只递增一次序号，快照与摘要**共用同一个值**。
而 iOS 端用**单一 `latestSequence`** 判断：

```
序号 7 → 摘要到达，游标 = 7
序号 7 → 快照到达，7 > 7 为假 → 被当作旧包丢弃
```

**结果：手机只显示一条摘要，完整列表永远不出现。**

修复：Mac 端明确"摘要复用快照序号"的语义；iOS 端改为**两条通道各记游标**。

### 2. HookDriftPolicy 是死代码（严重）

上一轮新增的 `HookDriftPolicy` **在生产代码里没有任何引用**，只有测试在用。
`ZeroConfigManager` 里另写了一段等价逻辑。这是"测试全绿但功能没接上"的
第三次重演。

修复：给 `HookDriftPolicy` 增加 `shouldPreservePartial(original:stripped:)` 重载，
让生产路径调用它——**被测试的就是生效的**。

### 3. iOS / watchOS 缺少 App 入口（严重）

`ios/` 下没有任何 `@main`。用户在 Xcode 建好 target 后会直接编译失败。

修复：新增 `CompanionApp.swift`（iOS）与 `CompanionWatchApp.swift`（watchOS），
用条件编译隔离两个 `@main`。

### 4. 连接对象随视图销毁（中）

`CompanionConnection` 由 `CompanionRootView` 的 `@State` 持有，
且 `onDisappear` 会 `stop()`。切后台或视图重建就断线，回来要重走 Bonjour 发现。

修复：连接提升到 App 层注入，移除 `onDisappear { stop() }`；
新增 `handleForeground()` / `handleBackground()` 应对 iOS 后台挂断。

### 5. 高频 hook 向主线程堆积 Task（中）

`SocketServer` 每次收到消息都 `Task { @MainActor in ... }`。
`handleClient` 跑在后台队列，而主线程同时有 60Hz 动画时钟——
高频 hook 下会堆积大量短命 Task。

修复：改为 `EnergyGovernor.signalActivityFromBackground()`，
用锁保护的标记合并同一轮内的多次投递。活动时间只需秒级精度。

### 本批验证

```
swift build --disable-sandbox        → BUILD_EXIT=0
swift test                           → 1922 tests, 0 failures (19 skipped)
swiftc -typecheck (iphonesimulator)  → 0 errors
swiftc -typecheck (watchsimulator)   → 0 errors
```

新增 7 项测试：3 项双通道序号、3 项漂移策略重载、2 项跨线程信号合并。

---

## 十三、为什么到此为止

第三轮仍能查出 5 个缺陷，但**边际收益已明显下降**，且剩余问题的性质变了：

| 类型 | 现状 |
|---|---|
| 接线错误 | 三轮已系统排查（入口 / 回调 / 开关 / 死代码），本批 5 个中 3 个属此类 |
| 可静态验证的逻辑缺陷 | 已覆盖，剩余需运行时才能暴露 |
| **需要真机才能推进的问题** | 端到端连通、后台保活、`applicationContext` 送达时机 |
| **需要实测才能下结论的问题** | 能耗与帧率是否真的改善 |

继续第四轮的结果大概率是：**再找出几个同类接线问题，或者开始臆造"优化"**。
后者比前者更危险——上一轮我拒绝照搬 20fps 降帧，就是因为没有实测数据支撑。

因此这一轮作为收尾。**下一步必须由真机验证驱动，而不是继续读代码。**

仍未解决（需外部条件）：

1. Mac ⇄ iPhone 的 Multipeer 配对从未跑通
2. iOS 后台保活未处理
3. Live Activity / 表盘 complication 未实现
4. **零运行时性能数据**——`sample` / Instruments 一次都没跑过
5. 签名与公证（缺证书）

### 三轮审计的方法论沉淀

三次都栽在同一件事上：**单测覆盖纯函数，覆盖不到"谁调用它"**。

| 轮次 | 漏掉的东西 | 表现 |
|---|---|---|
| 一 | `onCommand` 未赋值、`start()` 未调用 | 手机按钮点了没反应 |
| 二 | 设置界面无开关 | 功能永远无法启用 |
| 三 | `HookDriftPolicy` 无引用、`ios/` 无 `@main` | 新逻辑不生效、target 编译失败 |

**结论：新增功能后必须显式验证三件事——入口被调用、回调被赋值、开关可达。
这三项无法靠单测保证，只能靠人工核查。**

---

## 十四、第四轮：致命逻辑审计（2026-11-04 下午）

本轮专查**崩溃、误报、隐私、资源**四类致命问题，共 6 处。

### 1. MCPeerID 超限导致不可捕获崩溃（严重）

```swift
MCPeerID(displayName: String("XIsland \(name)".prefix(63)))
```

`prefix(63)` 按**字符**截断，但 `MCPeerID` 的 displayName 上限是 **63 字节**。
一个汉字占 3 字节，**22 个汉字即越界**。超限时抛
`NSInvalidArgumentException`——在 Swift 里**不可捕获，直接崩溃**。

触发场景很现实：Mac 名含较多中文（如「刘鑫宇的 MacBook Pro（广州）」再长一些）。

修复：新增 `CompanionPeerName.sanitized(_:)`，按字节累加并停在字素簇边界。
Mac 端与 iOS 端同时修复。

### 2. `handleForeground` 的条件写反（严重）

```swift
guard session == nil || !hasConnectedPeer else {
    if session != nil { return }   // ← 不可达死代码
    start()                        // ← 永远执行不到
    return
}
reconnect()
```

两个问题：
- `else` 分支里 `session != nil` 必为真（否则 guard 条件已满足），`start()` 不可达
- 更严重的是**逻辑方向错了**：`handleBackground` 会停掉发现，
  但 `connectedPeers` 可能仍是陈旧的非空值，此时 `handleForeground` 判定"无需重连"
  → **永久停在断线状态，且发现已停，再也不会恢复**

修复：不再信任 `connectedPeers`，改用显式的 `wasBackgrounded` 标记；
进过后台就重建连接。

### 3. 伴端回答命令误报"已送达"（中）

`handleCompanionCommand` 的 `.answer` 分支只检查 `pendingQuestion != nil` 就返回 `true`。
但 `answerQuestion` 内部还有三重校验（多选题、空文本、不在选项内且不允许自定义）。
**校验不通过时回答被静默丢弃，伴端却收到成功。**

修复：把校验前移到命令入口，与 `answerQuestion` 的前置条件保持一致。

### 4. 排序不确定导致摘要反复翻转（中）

`ordered` 只比较优先级与时间。同一秒内的两条同类会话视为相等，
`sorted` 在两次调用间可能给出不同次序 → 摘要内容反复变化 → 每次都触发无效发送。

修复：加 `id` 作最终比较，保证次序收敛。

### 5. 关闭广播后缓存未清理（中）

`stop()` 未清 `lastSnapshot`。用户关闭广播、稍后重新开启时，
新连上的设备会立刻收到一份**关闭之前**的会话列表——隐私泄露。

修复：`stop()` 一并清掉 `lastSnapshot`。

### 6. `isEnabled` 与 `Task` 的 actor 隔离隐患（低）

`MCSessionDelegate` / `AdvertiserDelegate` 是 `nonisolated`，
但 `invitationHandler` 被捕获进 `Task { @MainActor in ... }` 后跨 actor 传递。
当前能编译，但依赖 `@preconcurrency` 的宽松处理；已加注释说明，
未改动以避免引入新的行为变化。

### 本批验证

```
swift build --disable-sandbox        → BUILD_EXIT=0
swift test                           → 1931 tests, 0 failures (19 skipped)
swiftc -typecheck (iphonesimulator)  → 0 errors
swiftc -typecheck (watchsimulator)   → 0 errors
```

新增 9 项测试：4 项对端名字节截断、5 项命令前置条件与排序确定性。

### 仍然没有解决的（性质已不同于代码缺陷）

1. 端到端连通（需真机）
2. iOS 后台保活（需真机，且可能需推送配合）
3. Live Activity / 表盘 complication（未实现）
4. **零运行时性能数据**（需 `sample` / Instruments）
5. 签名与公证（需证书）







### 遗留观察

`SessionStatus.statusPriority`（`AgentSession.swift:32-46`）仍把 `error` 定为最优先、`completed` 定为最末，与收起态的 `rank()` 不一致。收起态已不再使用它；但它若被其他列表视图使用，需要单独确认语义是否有意为之。


