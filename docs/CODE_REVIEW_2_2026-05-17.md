# X Island 第二轮代码审查（2026-05-17）

本文档记录第二轮静态审查结论、优先级、修复策略与执行状态（与实现提交同步）。

## 范围

- Bridge / SessionManager / Socket / DIShared  
- SwiftUI / NotchWindow / 手势与快捷键  
- ZeroConfig / Quota / SSH / TerminalJump / AppUpdater / UpdateManager  
- ToolEvent / GitCheckpoint / VSCode 扩展 / UI Test Driver / Scripts  
- 本轮**未**做：拆分 `NotchContentView`、Sparkle、NSFileCoordinator 全量改造

## P0（崩溃 / 数据损坏 / 安全）

| ID | 问题 | 位置 | 修复状态 |
|----|------|------|----------|
| A1 | `open()` 锁文件失败时返回 `true`，误认为是单实例 | `AppDelegate.acquireSingleInstanceLock` | 已修：区分「重复实例」与「锁文件不可创建」；后者 Alert + 退出 |
| A2 | `writeJSON` 非原子；损坏 JSON 与缺失同样为 `nil`，可能整文件重写 | `ZeroConfigManager.readJSON` / `writeJSON` | 已修：原子写；损坏时备份 `.broken.<ts>.bak`，合并写入路径 `loadForMerge` 遇 `corrupt` 直接中止 |
| A3 | `AgentRegistry.meta` `fatalError` | `AgentRegistry.swift` | 已修：缺失时 `assertionFailure` + 安全回退 meta |
| A4 | DMG 安装无签名校验 | `AppUpdater.install` | 已修：挂载后对 `X Island.app` 执行 `codesign -v --deep --strict` |
| A5 | `handleToolComplete` 空 tool 错配未完成事件 | `SessionManager` | 已修：`tool` 非空才匹配 |

## P1（功能不可靠）

| ID | 问题 | 修复状态 |
|----|------|----------|
| B214 | SSH 隧道 `bash -c "ssh ... &"` PID 失控 | `SSHRemoteManager.startTunnel`：直接 `ssh -N` 前台进程；`stopTunnel`：按 pidfile `kill` |
| B3 | 远程隧道 socket 仅靠 label 可能碰撞 | `SSHRemoteServer`：`localTunnelSocket` 含 `id` 前缀 |
| B4–B6 | `URLSession` 无显式超时 | `QuotaTracker`、`AppUpdater.defaultDownloadFile` 使用自定义 configuration |
| B5 | 网络错误不调 `updateQuota` | Anthropic/GLM 等失败分支更新占位 `QuotaInfo` |
| B7 | `latestReleaseURL` 与 `releaseDataFromLatestRedirectURL` 校验 org 不一致 | 统一为 `Meteorkid/XIsland` |
| B8 | `TerminalJumpManager` `waitUntilExit` 无超时 | WezTerm/Kitty 路径加超时 `terminate` |
| B9 | Bridge `receiveResponse` 单次长阻塞 | 5s `SO_RCVTIMEO` 循环累积至 300s |
| B10–B11 | `accept`  tight loop；`bind` 静默失败 | `usleep` backoff；`diLog` + `Notification` 供 UI 使用 |
| B12 | `test.sh` M18 错误 `defaults` domain | `dev.xisland.app` |
| B13 | Subagent 回退到「同类型第一个会话」 | 移除 fallback，找不到 parent 即 return |
| B14 | `build.sh` 半成品 `.app` | 构建至 `X Island.app.tmp`，成功后 `mv` 替换最终 bundle |

## P2（性能 / 体验）

| ID | 说明 | 状态 |
|----|------|------|
| C1 | `DragGesture` minimumDistance 8 | `NotchContentView` |
| C2 | API Key Keychain debounce | `PreferencesView` |
| C3 | `QuotaTracker` Timer 上主 RunLoop | 移除 `nonisolated(unsafe)`，用 `@MainActor` 调度 |
| C4 | `AudioEngine.ensureEngine` 减少不必要 tearDown | 按 sampleRate/channel 比较 |
| C5 | `muteRules` 内存缓存 | `UserDefaults.didChange` 失效 |
| C6 | `L10n.effectiveLanguage` 缓存与回退链 | 实现 |
| C7–C8 | `SoundEvent.displayName`、`MatchField.displayName` 本地化 | 迁入 `L10n` |
| C9–C10 | `ToolEvent.parseTestResults` / `estimateLinesRead` | 启发式改进与上限 |
| C11–C12 | `GitCheckpointManager` stderr 与 stash ref | 实现 |
| C13–C14 | VS Code 扩展消息队列、`deactivate` 清理 timer | `extension.ts` |
| C15 | UI Test Driver 记录真实 App PID | `UITestScenarios.swift` |
| C16 | `AppDelegate` 问题快捷键 1–9 | 通用数字解析 |
| C17 | `install-git-hooks.sh` chmod 存在性检查 | 脚本 |

## 测试补强（批次 D）

已落地文件：

- `ToolEventTests.swift` — pytest/jest/go 解析与 `estimateLinesRead` 上限  
- `NotchShapeGeometryTests` / `ExpandedAutoCollapsePolicyTests` — 扩展边界与 guard 否定组合  
- `GitCheckpointManagerTests.swift` — 非 git 目录、`stashRef`  
- `SSHRemoteCommandTests.swift` — `sshTunnelArguments` 与 socket 唯一性  
- `SessionManagerToolMatchTests.swift` / `SessionManagerSubagentTests.swift`  
- `AppDelegateSingleInstanceTests.swift` — `SingleInstanceLock`  
- `ZeroConfigManagerCorruptionTests.swift` — `readJSONObject` 损坏备份  
- `UpdateManagerURLTests.swift` — `Meteorkid/XIsland` 重定向负载  
- `SocketServerAcceptTests.swift` — `accept` 失败退避常量  
- `AgentRegistryFallbackTests.swift` — registry 全覆盖

## 后续 backlog

- 拆分 `NotchContentView`  
- Sparkle / 公证链完整校验  
- Anthropic 配额探测避免真实 `messages` 扣费  
- `mirroredSessionSuffix` schema 化

## 验证

```bash
swift test
bash Scripts/build.sh
```

## 执行记录（2026-05-17）

- `swift test`：**222** 个测试，0 failure（本地 CLI）。
- `swift build -c release`：通过。
- `Package.swift`：`XIslandTests` 显式 `path: Tests/TowerIslandTests`，与目录一致。
- 风险备忘：DMG `codesign` 校验在用户环境依赖有效签名；若发布物未签名需改为白名单/跳过策略（见 backlog）。
