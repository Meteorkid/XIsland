# Swift 测试基线（2026-11-28）

## Cycle 2 基线（G15，2026-11-28）

### 环境

- 仓库：`/Users/meteor/github/xisland`
- 分支：`codex/release-2.0.19`
- HEAD：`5cf31a0`（工程迭代 14/16）
- 主机：macOS 26.7.2（25G332），arm64
- Swift：Apple Swift 6.4.2（swiftlang-6.4.2.1.9）
- 命令：`swift test -j 2`
- 日志：`/tmp/xisland-g15-full.log`
- 开始：2026-11-28T15:10:16+0800
- 结束：2026-11-28T15:13:59+0800
- 墙钟耗时：223.08 秒；构建 1.78 秒；XCTest 执行 215.865 秒
- 进程时间：user 40.60 秒，sys 12.58 秒

### 结果

| 目标 | 执行 | 跳过 | 失败 | XCTest 耗时 |
|---|---:|---:|---:|---:|
| `XIslandTests` | 2223 | 20 | 0 | 215.833 秒 |
| `MeteorLicenseCoreTests` | 31 | 1 | 0 | 0.032 秒 |
| 合计 | 2254 | 21 | 0 | 215.865 秒（XCTest 汇总） |

退出码为 `0`，XCTest 汇总为 **0 failures（0 unexpected）**。Swift Testing 侧报告 0 个测试、0 个套件。

### 跳过清单

跳过项与下方 Cycle 1（G6）基线完全一致，共 21 项：`XIslandTests` 20 项、`MeteorLicenseCoreTests` 1 项。分类仍为 15 项显式开启的渲染/UI 快照、5 项按需性能/计时、1 项需要 `METEOR_LICENSE_FIXTURE_PATH` 的外部授权夹具。

### Flaky 与诊断输出

- 单次全量运行未观察到测试重试、用例失败或非零退出；没有可记录的 flaky 现象。
- `SwiftData.DefaultStore save failed ... Read Only` 等日志仍来自只读临时库和故障注入负向用例；对应用例均通过，不属于测试失败。

### 与 Cycle 1 基线的差异

相对 G6 基线，`XIslandTests` 从 2219 增至 2223（+4）：G7 新增 3 项 SSH 校验测试，G14 新增 1 项 socket 目录回退测试。`MeteorLicenseCoreTests` 保持 31 项、1 跳过、0 失败。跳过总数保持 21，执行总数从 2250 增至 2254。

## Cycle 1 基线（G6，2026-11-28，历史）

以下为 G6 原始基线，保留用于对照。

### 环境

- 仓库：`/Users/meteor/github/xisland`
- 分支：`codex/release-2.0.19`
- HEAD：`e33f2c5`（工程迭代 5/8）
- 主机：macOS 26.7.2（25G332），arm64
- Swift：Apple Swift 6.4.2（swiftlang-6.4.2.1.9）
- 命令：`swift test -j 2`
- 日志：`/tmp/xisland-g6-full.log`
- 开始：2026-11-28T06:15:28+0800
- 结束：2026-11-28T06:18:56+0800
- 墙钟耗时：208.54 秒；构建 1.94 秒；XCTest 执行 201.608 秒
- 进程时间：user 32.91 秒，sys 8.69 秒

### 结果

| 目标 | 执行 | 跳过 | 失败 | XCTest 耗时 |
|---|---:|---:|---:|---:|
| `XIslandTests` | 2219 | 20 | 0 | 201.608 秒 |
| `MeteorLicenseCoreTests` | 31 | 1 | 0 | 0.027 秒 |
| 合计 | 2250 | 21 | 0 | 201.608 秒（XCTest 汇总） |

退出码为 `0`，XCTest 汇总为 **0 failures（0 unexpected）**。Swift Testing 侧报告 0 个测试、0 个套件；当前包使用 XCTest。

### 跳过清单

#### `XIslandTests`（20 项）

| 用例 | 原因 |
|---|---|
| `ApprovalContextMapRenderTests.testRenderApprovalContextMapStates` | 需显式启用隔离审批图快照 |
| `BackgroundCheckpointPerformanceTests.testProductionCheckpointKeepsMainActorResponsive` | 需显式启用后台检查点性能基准 |
| `CodewhaleSubagentOutcomeTests.testRenderNativeOutcomeActivitiesAndSessionCard` | 需显式启用隔离子代理状态快照 |
| `CollapsedPillViewTests.testRenderCollapsedPillIconVisibilityMatrix` | 需显式启用隔离收起态图标快照 |
| `CollapsedRecentTaskRenderTests.testRecentLimitChangesRenderedIconsAndNotchUsesRecentTask` | 需显式启用隔离最近任务显示验证 |
| `CollapsedTaskPreferencesTests.testNativePickerPersistsSelectionAndRetainsItWhileIconsAreOff` | 需显式启用隔离最近任务设置控件验证 |
| `CustomQuestionRenderTests.testRenderCustomQuestionPanels` | 需显式启用隔离 UI 快照 |
| `GLMMultiClientTests.testRenderClientAndModelLabels` | 需显式启用模型标签渲染 |
| `HistoryLongRunTests.testContinuousHistoryLoad` | 需显式启动连续长稳负载 |
| `HistoryPerformanceBenchmarks.testHistoryOperationBaseline` | 按需运行历史性能基准 |
| `HistoryResponsivenessBenchmarks.testBackgroundHistoryKeepsMainActorAvailable` | 按需测量后台历史与主线程心跳 |
| `HistoryViewsRenderTests.testHistoryPaginationSearchAndFailureViews` | 需显式启用历史页面渲染 |
| `HoverPollingPolicyTests.testMeasureActualTimerCallbacksWhenRequested` | 需显式启用真实 Timer 回调计数 |
| `IntegrationSetupRenderTests.testRenderIntegrationSetupStates` | 需显式启用隔离软件接入界面快照 |
| `MascotRenderTests.testRenderClientFamiliesTasksAndStaticStates` | 需显式启用吉祥物造型与静态状态渲染 |
| `SecurityApprovalBoundaryTests.testRenderApprovalCommandAndFullInput` | 需显式启用隔离审批快照 |
| `SessionFinalityRenderTests.testRenderUnconfirmedSessionWithStaleToolActivity` | 需显式启用隔离会话完成状态快照 |
| `SoftwareLicenseControllerTests.testLicenseSettingsRenderInBothLanguages` | 需显式启用授权页面渲染 |
| `UnifiedAutoCollapsePreferencesTests.testNativeSliderAndStoredToggleKeepZeroDelayAcrossDisableAndReopen` | 需显式启用隔离统一收起设置控件验证 |
| `VSCodeSubagentFinalityTests.testRenderRunningUnconfirmedAndCompletedActivities` | 需显式启用隔离子代理状态视图快照 |

其中 15 项为需显式开启的渲染/UI 快照，5 项为按需运行的性能或计时测量。

#### `MeteorLicenseCoreTests`（1 项）

| 用例 | 原因 |
|---|---|
| `SoftwareLicenseTests.testExternalServerFixture` | 需要 `METEOR_LICENSE_FIXTURE_PATH` 才运行服务端到 Swift 的验证夹具 |

### Flaky 与诊断输出

- 单次全量运行未观察到测试重试、用例失败或非零退出；没有可记录的 flaky 现象。
- 日志中的 `SwiftData.DefaultStore save failed ... Read Only`、`[Persistence] Container setup failed`、`[SessionManager] Kimi approval observation could not be restored` 来自只读临时库和故障注入类负向用例；对应用例均通过，不属于测试失败。
- 全量运行没有修改运行时代码，只新增本基线文档。

### 与上一基线的差异

2.3.0 基线为 2,218 项 `XIslandTests`、20 项跳过、0 失败；本次为 2,219 项，增加的是工程迭代 G3 的非字符串 ACP `command` 回归测试。`MeteorLicenseCoreTests` 本次 31 项、1 项跳过，保持不变。
