# X Island 伴端（iPhone / Apple Watch）

> 状态：协议层与 Mac 端发布器已接入并通过测试；iOS / watchOS 源码已通过
> `swiftc -typecheck` 双平台验证。**尚未在真机与真 Mac 之间跑通端到端**。

## 一、为什么手表不能直连 Mac

**watchOS 没有 MultipeerConnectivity。** 这不是实现偷懒，是平台事实：

```
Mac  ──MultipeerConnectivity(加密)──►  iPhone  ──WatchConnectivity──►  Watch
 │                                        │
 └── 完整快照 + 摘要                        └── 只转发摘要，命令原路返回
```

CodeIsland 也是这个结构。任何"手表直连 Mac"的方案都走不通。

## 二、分层

| 层 | 位置 | 职责 |
|---|---|---|
| 协议 | `Sources/CompanionShared/CompanionProtocol.swift` | 快照 / 摘要 / 命令 / 序号，macOS·iOS·watchOS 共用 |
| Mac 发布器 | `Sources/DynamicIsland/Managers/CompanionPublisher.swift` | 广播、接收命令、能力位校验 |
| iOS·Watch 连接 | `ios/Companion/CompanionConnection.swift` | Multipeer 客户端 |
| Watch 中转 | `ios/Companion/WatchRelay.swift` | WCSession 双端转发 |
| 界面 | `ios/Companion/CompanionRootView.swift`、`CompanionWatchView.swift` | 列表审批 / 单条审批 |

## 三、载荷设计

| 载荷 | 通道 | 大小 | 用途 |
|---|---|---|---|
| `CompanionSnapshot` | 局域网，可靠传输 | 未限制 | 完整会话列表 |
| `CompanionDigest` | 局域网不可靠 + WatchConnectivity | **≤ 512 字节** | 只带最紧急一条 + 计数 |
| `CompanionCommand` | 反向 | 极小 | 带 `sessionId` 的操作 |

三条设计决策及其原因：

1. **容错解码**：`CompanionPhase` 遇到未知值回退 `idle` 而不是抛错。抛错会让整份快照解码失败，
   在 watchOS 上表现为每次启动都因持久化的 application context 崩溃。
2. **摘要只在变化时发送**：避免 WatchConnectivity 与蓝牙的无效唤醒。
3. **命令必带 `sessionId`**：用户点的是他当时看到的那条，不是此刻队首那条。

## 四、必须做的工程配置

在 Xcode 里新建两个 target（本项目没有 `.xcodeproj`，SwiftPM 不能产出 app bundle）：

1. **iOS App**，名字如 `XIslandCompanion`，Bundle ID `dev.xisland.companion`
2. **Watch App**，勾选 "Watch App for Existing iOS App"

把 `ios/Companion/` 下的文件拖入对应 target：

| 文件 | iOS target | Watch target |
|---|---|---|
| `CompanionApp.swift` | ✅（`@main` 入口） | ❌ |
| `CompanionRootView.swift` | ✅ | ❌ |
| `CompanionConnection.swift` | ✅ | ❌ |
| `CompanionWatchApp.swift` | ❌ | ✅（`@main` 入口） |
| `CompanionWatchView.swift` | ❌ | ✅ |
| `WatchRelay.swift` | ✅ | ✅ |

`WatchRelay.swift` 两端都要：iOS 侧负责下发摘要与接收命令，Watch 侧负责读取与上报。
两个 `@main` 用 `#if os(iOS)` / `#if os(watchOS)` 隔离，因此同一份文件放进两个
target 也不会冲突——但更稳妥的做法是按上表分开归属。

`CompanionShared` 用 SwiftPM 本地包引用（File → Add Package Dependencies → Add Local）。

### Info.plist 必填（缺一个就连不上）

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>X Island 需要访问本地网络，以发现同一 Wi-Fi 下的 Mac。</string>
<key>NSBonjourServices</key>
<array>
    <string>_xisland-buddy._tcp</string>
    <string>_xisland-buddy._udp</string>
</array>
```

`_xisland-buddy` 必须与 `CompanionPublisher.serviceType` 完全一致。

### 能力开关

`CompanionPublisher` 默认**关闭**。启用前它不广播任何东西。
`allowsRemoteDecisions` 默认 `false`，此时手机端按钮置灰——只有 Mac 端显式允许，伴端才能批准。

## 五、已验证 / 未验证

**已验证：**

```
swift build --disable-sandbox                     → 0
swift test --filter CompanionProtocol             → 11 tests, 0 failures
xcrun --sdk iphonesimulator swiftc -typecheck …   → 0 errors
xcrun --sdk watchsimulator swiftc -typecheck …    → 0 errors
```

**未验证（需要真机）：**

- Mac ⇄ iPhone 的 Multipeer 配对与传输
- iPhone ⇄ Watch 的 applicationContext 实际送达时机
- 锁屏状态下 iOS 端能否保持连接（系统可能挂起后台 app）
- Live Activity / 表盘 complication（本轮未实现）

## 六、明显缺口

| 缺口 | 说明 |
|---|---|
| Live Activity | 需要 Widget Extension + ActivityKit，本轮未做 |
| 表盘 complication | 需要 WidgetKit extension，本轮未做 |
| 后台保活 | iOS 后台会挂断 Multipeer，需要配合推送或延长后台任务 |
| 配对确认 | 目前靠同名服务发现，没有设备级配对确认流程 |
| 多 Mac | 一个 iPhone 同时发现多台 Mac 时，当前会尝试全部邀请 |
