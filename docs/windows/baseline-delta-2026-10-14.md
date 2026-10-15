# 冻结基准与当前 macOS 源码差异审计

审计日期：2026-10-14。范围限于指定的五个 macOS 文件，以及判断 Windows 覆盖程度所需的对应代码。本次只读比较源码，并运行一段纯 TypeScript 合成事件检查；未修改 macOS 源码或冻结 manifest，未运行真实 Kimi 客户端，也未以 Windows 编译成功推定行为已经对齐。

结论：五个文件的变化对应 **一处历史缓存清理修复、一个共用判定函数的提取、两处失败状态展示修复，以及 Codex 回合观察保护和压缩恢复语义的新增约束**。`AgentActivityView` 的改动是等价替换，不能另算新增功能。Windows 当前有后台任务和回合 ID 的协议字段，但没有完整覆盖对应的 Kimi 和 Codex 增量，不能将其标为完成。

## 版本与定位

冻结目录：`.build/windows-baseline-2026-10-13`。冻结 manifest：[`baseline-manifest.json`](baseline-manifest.json)。其记录的 `head` 为 `90fdc0af202a86cabe94d59c6f1328314bf55cee`，但 `basis` 明确是 **包含未提交修改的工作目录**；因此该提交号不单独代表冻结内容。

本次逐文件核对，五个冻结副本的 SHA-256 均与 manifest 一致。manifest 本身的 SHA-256 为 `e77c1c502015fd81a6a13b361b84a26e24a00ade46ec113f1c0d0c61644fea56`。

审计中进行了结束时复核：`SessionManager.swift` 从首轮读取的 `1d609700b9695ed130ac908f9d04f91790ac08f0a692de32fcd22c555f81e9db` 变为下表版本。因此本文补入 D5，并将该文件的当前行号更新到新版本；不推断改动来源。

下列路径相对 `Sources/DynamicIsland/`；“冻结行号”指冻结副本，“当前行号”指本次采样的工作目录文件。行号只在对应 SHA-256 版本下有效。

| 文件 | 冻结 SHA-256 | 当前 SHA-256 | 主要变化位置：冻结 → 当前 |
|---|---|---|---|
| `Managers/SessionManager.swift` | `20846cdfcc87a94d43dcdd6db1cd5d41fc2462beaf41d5e4c0db21e2e9d1d90b` | `3530a2ec0db28dbf83f9011943be342eb02a6eea914f596f4e8ce75b024941cc` | 冻结 551 / 590 / 600 / 1004 / 1753 / 1848 附近 → 当前 551–556 / 599 / 614–625 / 1028 / 1777–1779 / 1874–1879 |
| `Models/KimiCodeApprovalObservation.swift` | `fb44fb9827670e4d4bd5504cb89cfe42b1c0efc984f4bab303f7ece9ebff37d3` | `118703f307ac636dd3922220969a0a9744044813363b858ed9198a2f73b7550c` | 在冻结 137 行后新增 → 138–140 |
| `Views/AgentActivityView.swift` | `0fdf2e132adb600f41d42b66ae8275ef6ff91fe798cf0f784eec30f812531601` | `f1b1ab06e0cc3e6565ba6271cc2f3b9095ec2ce65bb1669181e7d5ab12ecb8ab` | 9 → 9 |
| `Views/NotchContentView.swift` | `2f182d096d4141e3bbc56d5a46b6368278ce5170d6fa2c3031c29bd7ec6dac32` | `2b823e34d190cf51d04b9add06f61bd146305458147bf280a4b5d29fa688d32b` | 1211–1272 → 1211–1276 |
| `Views/SessionListView.swift` | `c72f47ad779530783c5f47002a4b23a4ba55926e8a97989927d39f81cd12dc39` | `e4272db8b8c4f2213372b1638614d0ba5529dcfaac692614ddeba26cb6124306` | 340–347 → 340–349 |

## 逐项行为变化

### D1：历史已不存在时，丢弃对应的 Kimi 后台任务待保存缓存

位置：`SessionManager.restoreArchivedSessionIfNeeded`，当前 1856–1879 行；清理增量实际位于 1874–1879 行。

冻结版本在找不到持久化会话时直接返回 `true`。当前版本在这个分支先移除当前 `message.sessionId` 对应的 `unsavedKimiBackgroundTasks`；**只有确实移除了该缓存，才同时移除 `unsavedSessionIDs` 中的同一 ID**，然后允许正常事件继续处理。

相关已有行为解释了这个修复的作用：

- 当前 634–674 行的后台任务处理，会在隐藏历史对象保存失败时保留任务事实，以便以后重试。
- 当前 1408–1426 行附近的 `persistSession` 会把该待保存事实合入会话。
- 如果历史后来被删除或清理，普通新活动再次使用同一会话 ID，旧缓存不应被带进新建记录。
- `retryPendingHistorySaves` 在冻结版本就已有“找不到记录时丢弃对应缓存”的逻辑；此次是把同样的保护补进普通归档恢复入口，不能称为首次实现缓存清理。

边界：内存中已有会话、成功找到历史、或查询历史抛错，都不是这次新增的“确认记录不存在”分支。不能把查询失败当作删除，也不能顺便清空其他会话的待保存标记。

**Windows：对应语义尚未实现。** 当前 `windows/src/core/session-store.ts` 没有独立的隐藏 Kimi 后台任务待保存缓存，也没有该归档恢复分支。主窗口已有串行历史保存和删除确认机制（`windows/src/main.ts` 117–143 行），但这不能证明 D1 已覆盖，也不能据此断言 Windows 当前已经存在完全相同的缓存复活缺陷。移植 Kimi 隐藏任务事实和失败重试时，应把本修复作为约束一并实现。

### D2：统一后台任务失败判定，原活动详情行为保持不变

位置：`KimiCodeApprovalObservation.swift` 当前 138–140 行；`AgentActivityView.swift` 当前 8–11 行。

新增 `isFailedBackgroundTask(_:)`，只将 `failed`、`timed_out`、`killed` 判为失败；`nil`、`running`、`completed`、`lost`、`unconfirmed` 均不进入这一失败集合。

`AgentActivityView` 把原有的内联集合判断替换为该函数。冻结版本已经会优先显示失败图标，因此 **这一文件本身没有新增可见行为**。函数提取使另外两处展示能够使用相同规则。

**Windows：没有等价的共用失败判定及使用点。** 当前工具事件类型只有 `isComplete` 和 `completionUnconfirmed` 等通用字段；后台任务状态虽然另行保存，却没有与活动行关联。不是必须复制 Swift 函数名，而是要在各展示处保留同一语义。

### D3：全局活动日志将后台失败与成功完成区分

位置：`NotchContentView.activityLogContent`，当前 1211–1276 行。

当前版本先汇总各会话的原生后台任务状态，通过事件 UUID 查得某活动对应的任务状态，再应用统一失败判定。失败活动现在显示红色叉号和浅红背景；成功完成仍保留原有成功样式。以成功完成为条件的弹跳与 `ToolCompletionEffect` 改用 `isComplete && !failed`，避免把失败结束当作成功完成来强调。

冻结版本只按 `isComplete` / `completionUnconfirmed` 选择图标与完成效果。后台失败也是“已经结束”，因此只看 `isComplete` 会出现成功勾号的歧义。此次没有改变任务运行结果，也没有把整个父会话改成 error；它修正的是活动展示。

**Windows：未覆盖。** 当前 `windows/src/ui/index.ts` 404–407 行的 `activityPanel` 只按 `event.isComplete` 输出 `✓` 或 `…`，没有查询 `backgroundTasks`。它不能区分失败结束与成功完成。

### D4：会话卡片的近期活动同步显示失败状态

位置：`SessionListView.toolActivity`，当前 340–349 行。

当前版本为卡片中的最近五个事件建立会话内的原生任务状态映射，失败时优先显示红色方形叉号。冻结版本只看完成/未确认标记，失败结束可能被画成绿色勾号。其余工具文本和结果摘要规则没有在这次增量中改变。

**Windows：未覆盖。** 当前 `windows/src/ui/index.ts` 338 行的卡片末条活动仅按 `isComplete` 选择 `check` 或 `terminal`；417 行的详情摘要也只按 `isComplete` 添加 `✓`。详情这一缺口相对冻结版本就已存在，不能全部归入本次 D4 的新增范围。

### D5：Codex 的中断与压缩观察绑定当前回合，压缩不再按三秒推断结束

位置：`SessionManager.swift` 当前 551–556、599、614–625、1028、1777–1779 行。

当前版本新增以下约束：

- 将 Codex 的 `Interrupt`、`PreCompact`、`PostCompact` 识别为回合观察事件。在进入归档恢复前，要求内存中已经存在对应会话、消息携带 `nativeTurnId` 且等于该会话的 `codexTurnID`。
- 存在待处理交互，或会话处于 completed、observationUnavailable、error、waitingPermission、waitingAnswer、waitingPlanReview 时，拒绝这些观察事件改变状态。
- 对非重放的 `UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`PermissionRequest`、`Stop` 记录回合身份。新提示可以确认切换回合；其他这些事件只在尚无回合身份时补齐，不能让迟到结果把当前回合倒退。权限请求的独立处理入口也调用这项记录逻辑。
- Codex 原生 `PreCompact` 不再进入三秒后自动恢复 active 的旧通用分支，而是等待后续原生事实。Kimi 的相应例外在冻结基线中已经存在。

这五个文件的差异可以证明上述管理器约束；它们不能单独证明 Codex 原生 hook 字段已经被正确解析、所有事件已注册，或实际客户端联调已通过。`codexTurnID` 的模型定义及供应商 adapter 不在本次指定的五文件差异范围内，不以本段代替完整链路审计。

**Windows：只部分满足不使用固定计时器的方向，其余未覆盖。** 当前 `adapters/codex.ts` 仍只有九个注册事件，不接受这三个观察事件，也没有将原生 `turn_id` 填到 `nativeTurnId`。协议层虽然允许 `nativeTurnId`，`SessionStore` 仍没有 Codex 当前回合记忆与上述门禁。直接注入旧回合的 `context_compact` 会被当前通用核心接受。Windows 通用压缩分支本身没有三秒恢复计时器，但由于完整原生观察路线缺失，不能据此宣称 D5 整体已实现。

## Windows 已有内容、缺口与前置条件

| 层面 | 本次核实的 Windows 现状 | 与当前 macOS 的差距 |
|---|---|---|
| 消息字段 | `core/protocol.ts` 150–163 行解析 `nativeBackgroundTask`；`core/types.ts` 保留 `backgroundTasks` | 字段存在不等于 Kimi 原生适配完成 |
| 状态保存 | `core/session-store.ts` 162–165 行按任务 ID 插入或直接替换整项事实 | 没有 macOS 已存在的状态优先级合并；迟到 running 可以覆盖 failed |
| 任务事件 | 没有将原生后台任务投影到 `session.events` 的专用逻辑 | 仅收到后台任务字段不会出现在活动日志或卡片事件中 |
| 失败展示 | 卡片、活动日志、详情均主要按 `isComplete` 选择成功标记 | D2–D4 未覆盖；需关联原生任务事实，不能从工具名称或结果文字猜测失败 |
| 持久化恢复 | 有通用历史保存、删除确认与恢复保护 | 没有 D1 对应的 Kimi 隐藏任务待保存缓存与清理路径，仍待实现 |
| 原生接入 | 本次读取的 `adapters/registry.ts` 只注册 Claude、Codex、Cursor、Gemini | 没有 Kimi adapter 注册，不能把通用字段解析宣称为 Kimi 已接通 |
| Codex 回合观察 | 协议载体包含 `nativeTurnId`，但 adapter 没有提取 `turn_id`，核心没有保存当前 Codex 回合 | D5 的事件注册、身份传播和门禁仍待跟进；无固定计时器不等于原生压缩链路完成 |

这里的“状态优先级合并”“任务投影”“原生 Kimi 接入”是 **冻结基线本来就需要对齐的前置能力**，不是这五个文件今天新增加的全部功能。macOS 的 `backgroundTaskEventID`、`backgroundTaskStatuses`、`synchronizeKimiCodeBackgroundTasks` 在冻结副本中已经存在。

当前 macOS 使用专用后台任务身份生成稳定事件 UUID，并让该投影事件的 `toolCallId` 保持为空；它不占用模型工具调用 ID 的命名空间。Windows 后续需要保留这种隔离，不能仅以工具名 `Subagent` 或字符串前缀把两种身份混在一起。

## 本次执行检查及证据边界

对当前 Windows `SessionStore` 直接注入一条合成 `kimi_code.Notification`，其中 `nativeBackgroundTask={id: "task-1", kind: "agent", status: "failed"}`；然后再注入同 ID 的 `running`。没有启动 bridge、Windows GUI 或真实 Kimi。

结果：

```json
{
  "syntheticOnly": true,
  "failed": { "accepted": true, "taskStatus": "failed", "eventCount": 0 },
  "laterRunning": { "accepted": true, "taskStatus": "running", "eventCount": 0 }
}
```

这确认了当前核心是保存并替换后台任务字段，而不是完整执行 macOS 的后台任务合并和事件投影。源码中的卡片、活动日志和详情渲染条件也未读取原生后台任务状态。本次没有新增测试文件、没有重跑 macOS 全量测试，也没有作原生客户端验收结论。

另一次纯 TypeScript 检查：给 `normalizeCodexHook` 输入带 `turn_id` 的 `UserPromptSubmit`，输出没有 `nativeTurnId`；三个新增观察事件均被 adapter 拒绝。绕过 adapter 直接给核心注入旧回合 `PreCompact`，核心接受并将会话设为 compacting。结果为：

```json
{
  "syntheticOnly": true,
  "nativeTurnIdMapped": null,
  "adapter": [
    { "event": "Interrupt", "accepted": false },
    { "event": "PreCompact", "accepted": false },
    { "event": "PostCompact", "accepted": false }
  ],
  "wrongTurnDirectCore": { "accepted": true, "status": "compacting" }
}
```

相关 Windows 采样版本：

| 文件 | SHA-256 |
|---|---|
| `windows/src/core/session-store.ts` | `30105b1a141e4c02b08b1209124738c5da0cb2b1c658664b303b4e9e69d9373c` |
| `windows/src/core/types.ts` | `865bc7a654637ddbdc7956351a5512e1a88105cf9dd1a2522c33c77a111872cf` |
| `windows/src/core/protocol.ts` | `ab34f2f0b399db8e96a0e16481d0270a939821d5aa530b5b2f5b07ede78293be` |
| `windows/src/ui/index.ts` | `7ec055291e8d9c8a79521c4daf193b37362a76e3b03076f4a5d601adfdb1f66c` |
| `windows/src/adapters/registry.ts` | `cf170261850b51abcedf73164796510539831bd3701db6dabbf42aa0268a1a51` |
| `windows/src/adapters/codex.ts` | `7d60bc9851d7390f7541cbba55f28e8812a2b6041f7500b44918185bca7e91ca` |
| `windows/src/main.ts` | `cd537f4ae1f0d40a9702cf349537b9a4f20f3d1deeb968e2cf2ec0690b0ad269` |

## 跟进验收项

1. 接入 Kimi 后，分别对 `completed`、`failed`、`timed_out`、`killed`、`lost`、`unconfirmed` 验证卡片、全局日志和详情：失败不能出现成功勾号或成功完成效果；未知/失联不能被当作失败或成功。
2. 同一会话的同一后台任务必须只有一个稳定投影事件；另一个会话的同名任务、以及模型工具调用同名 ID，不能相互覆盖。
3. 以原生事件顺序和重放 fixture 验证状态合并，至少覆盖失败后迟到 running，不能只测试最后一条消息覆盖前一条。
4. 对隐藏历史模拟后台事实保存失败，再删除历史、接收同 ID 新活动：旧待保存事实和对应标记不能进入新记录；无 Kimi 缓存的其他保存失败标记不得被误清除。
5. 历史存在时保留待保存事实并可重试；历史查询报错时保留缓存并报告失败，不能按“查无记录”清除。
6. 对 Codex 补齐回合 ID 传播后，分别验证当前回合、旧回合、缺失 ID、未知会话、历史重放以及正在审批的会话；只有已知当前回合且无保护状态的观察可以生效。压缩超过三秒仍应保持等待原生事实。

本审计没有修改 [`macos-parity.md`](macos-parity.md) 的冻结状态，也没有把任何未实现项改成完成；上述增量作为独立跟进记录保留。
