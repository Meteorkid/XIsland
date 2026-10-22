# X Island 2.0.4 安全审计报告

- 审计对象：`/Users/meteor/github/xisland`（X Island 2.0.4，Swift 6 / macOS 14+）
- 审计范围：`Sources/DIShared`、`Sources/DIBridge`、`Sources/DynamicIsland`（共 36,675 行 Swift）+ `Scripts/`
- 审计方法：源码静态审计 + 数据流可达性追踪（未做动态验证）
- 结论摘要：**1 个 P0、2 个 P1、3 个 P2**。P0 为远程可触发、影响全部安装用户的更新通道缺陷。

---

## P0 — 更新通道缺少签名者身份校验（远程 RCE）

**位置**
- `Sources/DynamicIsland/Managers/AppUpdater.swift:370-375`
- `Sources/DynamicIsland/Managers/AppUpdater.swift:501`（安装脚本内二次校验）
- `Sources/DynamicIsland/Managers/UpdateManager.swift:40-44`（dmgURL 取值）
- `Sources/DynamicIsland/Managers/UpdateManager.swift:249-263`（SHA256 提取）

**问题**

```swift
// AppUpdater.swift:372
_ = try runCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", mountedAppPath])
```

`codesign --verify` 只验证**签名自洽性**（资源封印与签名匹配），不验证**签名者是谁**。命令中没有 `-R`（指定要求）、没有 `TeamIdentifier` 比对、没有锚点约束。

README 明确写明应用未使用 Apple Developer 证书签名：

> Since the app is not signed with an Apple Developer certificate, macOS will block it on first launch.

即当前发布包为 **ad-hoc 签名**。ad-hoc 签名同样能通过 `codesign --verify --deep --strict`。攻击者用任意自签身份签署恶意 app，校验**照样通过**。

因此实际防线只剩一条：GitHub Release notes 里的 SHA256。而该 SHA256 与 DMG 同在 `Meteorkid/XIsland` 仓库下，由同一账号控制 —— 这是**同源校验，不是独立的第二道防线**。

另：`dmgURL` 直接取 API 返回的 `browser_download_url`，无 host 白名单。

**威胁模型**

| 前提 | 结果 |
|---|---|
| GitHub 账号失守 / PAT 泄露 / 恶意 PR 合入发布流程 | 全部在线用户静默升级到恶意版本，以用户权限执行任意代码 |
| 无本地立足点需求 | 与本地权限无关，普通用户账户即可被完全控制 |

**修复建议（按优先级）**

1. 用 Developer ID Application 证书签名正式发布包，并在校验中比对身份：
   ```swift
   let out = try runCommand("/usr/bin/codesign", ["-dv", "--verbose=4", mountedAppPath])
   // 解析 TeamIdentifier=XXXXXXXXXX，与硬编码值比对
   ```
   或更稳妥地使用 `SecStaticCodeCheckValidityWithErrors` + 自构造 requirement（`anchor apple generic` + `certificate leaf[subject.OU] = "TEAMID"`）。
2. 把 SHA256（或 manifest 签名）发布到**独立于 GitHub 仓库的信道**（独立域名 / 独立密钥签名的 manifest），实现真正的双因素。
3. `dmgURL` 增加 host 白名单：`github.com` 与 `objects.githubusercontent.com`，其他一律拒绝。
4. 当前 ad-hoc 状态下，至少在 UI 上明确标识"未验证发布者"，避免用户误以为已通过身份校验。

---

## P1-A — Unix socket 无对端认证（权限决策可劫持）

**位置**：`Sources/DynamicIsland/Managers/SocketServer.swift:27-76`、`111-158`

**现状**

`chmod(dir, 0o700)` + `fchmod(fd, 0o600)` 只能挡住**其他用户**。macOS 上同 UID 的任意进程均可连接：npm postinstall 脚本、恶意 VS Code 扩展、被 agent 执行的任意命令、用户误运行的二进制 —— 全部在信任边界内。

**可利用场景**

*场景 A：伪造权限请求（App 运行中）*
任意进程构造一条 `permission_request` 消息，`agentType` 填 `claude_code`，`permDescription` 填任意文本。灵动岛 UI 会把它渲染成"Claude Code 请求执行 X"。用户看到的是一个**没有来源标识、无法证伪**的审批界面。

*场景 B：抢占 socket 冒充服务端（App 未运行时）* — 危害显著更高

1. `ZeroConfigManager` 已把 `~/.xisland/bin/di-bridge` 写入 `~/.claude/settings.json` 等**全局**配置，App 退出后 hook 依然生效。
2. 攻击者进程在 App 未运行时创建 `~/.xisland/di.sock`（目录属主即用户，可写），监听并冒充服务端。
3. `di-bridge` 连接后发送 `permission_request`，攻击者立即回 `permission_response` + `approved: true`。
4. `di-bridge` 以退出码 0 / `decision: approve` 回写，`DIBridge.swift:120` 之后的输出使 Claude Code 放行该命令。
5. 结果：**Claude Code 的权限确认 UI 被完全绕过**，危险命令在用户无感知的情况下执行。

协议格式完全公开（`Sources/DIShared/Protocol.swift`），构造成本极低。

**修复建议**

1. 服务端用 `getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID/LOCAL_PEEREPID)` 取对端 PID/有效 UID，校验对端可执行文件路径为自家 `di-bridge` 且属主一致；不通过即 `close(fd)`。
2. `di-bridge` 侧反向校验服务端进程身份，避免连到冒充者。
3. App 退出时对 socket 目录加独占锁（`flock`），并在启动时检测残留 socket 的持有进程。
4. UI 上为每条权限请求标注来源进程 PID / 可执行路径，用户可核对。

---

## P1-B — SocketServer 无并发上限与读超时（本地 DoS）

**位置**：`Sources/DynamicIsland/Managers/SocketServer.swift:91-109`、`189-208`

```swift
let clientFD = accept(fd, nil, nil)
...
DispatchQueue.global(qos: .userInitiated).async { [weak self] in
    self?.handleClient(clientFD)
}
```

- 每连接派发一个 GCD 全局队列任务，`recv` 无 `SO_RCVTIMEO`，**永久阻塞**。
- 交互式请求（`permissionRequest` / `question` / `planReview`）持有的 fd 交给 `SocketResponseChannel`，用户不响应则 fd 永不释放（无 idle 超时）。
- `listen(fd, 16)` 之外没有任何并发连接数限制。

一个本地脚本开数百条"连上但不发数据"的连接即可耗尽文件描述符与 GCD 线程，导致悬浮面板卡死、事件接收中断。该面板位于屏幕顶部最显眼位置，可用性影响直接可见。

**修复建议**

1. 设置 `SO_RCVTIMEO`（如 5s）与整体连接处理超时。
2. 限制并发连接数（如 32），超限直接拒绝并 `close`。
3. `SocketResponseChannel` 增加 idle 超时，超时自动 `cancel()` + `close(fd)`。
4. 交互式连接改用有限大小的专用队列，不要用 `DispatchQueue.global`。

---

## P2-A — di-bridge 被篡改后不会被自动修复（持久化执行点）

**位置**：`Sources/DynamicIsland/Managers/ZeroConfigManager.swift:529-557`、`1028-1031`

```swift
shouldCopy = bundledMod > stableMod
```

只在 bundle 内二进制的 mtime **更新**时才覆盖 `~/.xisland/bin/di-bridge`。若攻击者替换了该文件（mtime 会变新），App 重启时 `bundledMod > stableMod` 为 false，**不会还原**。

而该文件已被注入 Claude Code / Codex / Cursor / Trae / Windsurf / Cline / Kiro 等的全局 hook 配置，每次工具调用、每次权限请求都会执行它 —— 一个可写位置即成为**所有 AI 编程代理的常驻执行点**。

`ensureDir` 未设置权限，`~/.xisland/bin` 使用默认 umask（通常 0755）。

**修复建议**

1. 启动时校验 `stable` 二进制的 SHA256，与 bundle 内二进制比对，不一致立即重建，不依赖 mtime。
2. `ensureDir` 显式设置 `0o700`。
3. 考虑将 di-bridge 安装为 App 内路径引用（`/Applications/X Island.app/Contents/MacOS/di-bridge`），减少可写副本。

---

## P2-B — 外部命令解析依赖 PATH

**位置**：`Sources/DynamicIsland/Managers/TerminalJumpManager.swift:553-556`、`591-593`、`757-759`

```swift
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["wezterm", "cli", "list", "--format", "json"]
```

`wezterm` / `kitty` / `code` / `cursor` / `windsurf` / `trae` 全部通过 `/usr/bin/env` 解析，`Process` 未设置 `environment`，继承 App 的 PATH。若 PATH 中包含用户可写目录（如 `~/.xisland/bin`、自定义 Homebrew 前缀），投放同名脚本即可劫持执行。

**修复建议**：显式设置 `process.environment`，传入受控的 PATH（`/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin`）；或解析绝对路径后校验属主与权限。

---

## P2-C — AppleScript 字符串插值未转义（当前调用链不可达）

**位置**：`Sources/DynamicIsland/Managers/TerminalJumpManager.swift:519-547`

```swift
if name of aSession contains "\(dir)" then
```

`dir` = `snap.workingDirectory`，**未做任何转义**，而该值直接来自 socket 消息的 `workingDir` 字段（`SessionManager.swift:1526`），无任何校验（不要求是绝对路径、不要求目录存在）。

对比同文件另外两处 —— `jumpToITermSession:362` 与 `jumpToTerminalWindow:389` 都做了 `\` 和 `"` 的转义 —— 说明开发者有转义意识，tmux 这条分支是遗漏。

**可达性分析（重要）**：该脚本仅在 `app == .iterm2` 时生成，而

- `termSessionId` 非空且 `app == .iterm2` 时，第 227 行 `jumpToITermSession`（有转义）会提前命中并 return；
- `termSessionId` 为空时，第 238 行 `if let tsid = ...` 不成立，tmux 分支不会被进入。

因此**当前版本该注入不可达**，属于代码缺陷而非可利用漏洞。但一旦跳转逻辑重构，即成为真实的任意 AppleScript / Shell 执行点。

**修复建议**：抽出统一的 `appleScriptQuoted()`，所有插值强制走该函数；同时对 `message.workingDir` 做"必须是已存在的绝对路径"校验后再入库。

---

## 已核查为安全 / 设计合理的部分

| 项 | 结论 |
|---|---|
| API Key 存储 | 存于 Keychain（`QuotaTracker.swift:212+`），`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，未落明文 |
| SSH 凭据 | 仅 `identityFile`，未存储密码；未发现 `StrictHostKeyChecking=no` 弱化配置 |
| 安装脚本 | `AppUpdater.makeInstallerScript` 用 `mktemp -d` 在同父目录做原子替换 + 失败回滚，路径均经 `shellQuoted()` 转义，无命令注入 |
| Git 检查点 | `Process` 参数数组传递，无 shell 注入 |
| 消息解码 | `DIProtocol.decode` 过滤帧边界，16 MB 上限，路径长度与临时目录有校验 |
| 测试模式隔离 | `X_ISLAND_TEST_RUNTIME_DIR` 校验必须位于临时目录内且长度 < 104 字节 |

## 附带观察（非安全项）

- `GitCheckpointManager.restoreCheckpoint`（`GitCheckpointManager.swift:32`）按 commit message 文本匹配 stash 条目后 `git stash pop stash@{i}`，多 stash 场景可能弹出错误条目。
- `UpdateManager.fetchLatestReleaseData:395` 将 URL 中的 tag 直接拼入 `api.github.com` URL，未做字符校验；host 固定为 github.com，实际影响有限。
- README 引导用户执行 `xattr -cr /Applications/X Island.app` 绕过 Gatekeeper，长期看会弱化用户的安全习惯；解决根因（P0 的正式签名）后可移除该段。

---

## 修复优先级建议

1. **P0 更新通道签名校验** —— 唯一会影响所有用户、且无需本地立足点的漏洞，应最先处理。
2. **P1-A socket 对端认证** —— 涉及 AI 代理权限系统被绕过，是本产品最核心的信任承诺。
3. **P1-B DoS 加固** —— 实现成本低（约 30 行），建议与 P1-A 一并提交。
4. **P2 三项** —— 属于深度防御，可在下个迭代处理。

---

## 修复实施记录（2026-10-23）

编译 `swift build` 通过，`swift test` 1461 个测试全绿（含新增 4 个）。

### P0 更新通道 —— 已修复（代码就位，待启用）

- `AppUpdater.expectedTeamIdentifier`：新增期望 Team ID 常量，当前为 `nil`。
- `AppUpdater.parseTeamIdentifier(from:)`：解析 `codesign -dv --verbose=4` 输出，`not set` 正确返回 nil。已用本机真实 ad-hoc 包实测，提取值为 `not set`。
- `AppUpdater.verifySignature(at:)`：先做 `codesign --verify` 自洽校验，再在配置了期望值时比对 Team ID。
- 安装脚本新增 `EXPECTED_TEAM` 守卫，非空时校验替换包的 Team ID，失败即 `exit 1` 触发既有回滚。脚本语法已用 `sh -n` 验证。
- `UpdateManager.ReleaseInfo.allowedDownloadHosts`：下载域收窄为 `github.com` 与 `objects.githubusercontent.com`，采用精确匹配（`github.com.evil.test` 无法绕过）。

**启用方式**：取得 Developer ID 证书后，把 `AppUpdater.expectedTeamIdentifier` 填为 Team ID 即可，无需改动其他代码。

### P1-A socket 对端认证 —— 已修复（含重要效力边界）

`SocketServer.peerIdentity(of:)` 通过 `getsockopt(SOL_LOCAL, LOCAL_PEERPID / LOCAL_PEEREUID)` 取对端 PID 与有效 UID；`evaluatePeer` 依次校验 UID 一致 → 测试模式放行 → 白名单路径 → 拒绝。

**实施中发现并修正的兼容性问题**：初版白名单只允许 `di-bridge` 与 `/usr/bin/ssh`，实测会打断绝大多数集成。原因是 `ZeroConfigManager` 的 `guardedCommand`（第 241 行）**只对 `PermissionRequest` 生成裸命令，其余事件一律拼接 `|| true`**；复合命令下 shell 不做 exec 优化，本地 peer 进程是 `/bin/sh` 而非 di-bridge。`ClineHookConfiguration` 的事件脚本（含 `printf` 尾行）同理。

因此白名单补充放行 `/bin/sh`、`/bin/bash`、`/bin/zsh`、`/usr/bin/env`。

**效力边界（必须知晓）**：同 UID 下无法做强认证 —— 攻击者可直接运行合法客户端或经 `/bin/sh -c` 绕过路径校验。当前措施的实际收益是：拦截跨用户连接、拦截未走既定调用链的进程、检测 di-bridge 被篡改（属主非本人或组/其他可写时拒绝）。

若需真正的强认证，需同步改造调用链：让 di-bridge 对非交互 hook 恒定 `exit 0`，并从 `ZeroConfigManager` 移除 `|| true`，使所有 hook 成为可 exec 的单命令。此项涉及全部集成的回归验证，建议单独立项。

### P1-B DoS 加固 —— 已修复

- 并发连接上限 32，超限立即关闭新连接。
- `SO_RCVTIMEO` 10 秒读超时。
- `SocketResponseChannel` 新增 600 秒 idle 超时，超时自动 cancel 并关闭 fd；连接配额在 channel 关闭时归还（含 deinit 兜底）。

### P2-A di-bridge 自愈 —— 已修复

`syncBundledFileIfNeeded` 改为比对 SHA256 而非 mtime；`ensureDir(_:permissions:)` 支持显式权限，并对已存在目录同样收紧（`createDirectory` 的 attributes 只在新建时生效）。`~/.xisland`、`~/.xisland/bin`、`~/.xisland/bin/lib` 均设为 0700。

### P2-B / P2-C 终端跳转 —— 已修复

- 新增 `controlledPATH`，所有 `Process` 显式设置 environment，不再继承进程 PATH。
- 新增 `appleScriptQuoted(_:)`，iTerm / Terminal / tmux 三处插值统一走该函数；tmux 分支的未转义注入点已消除（该路径当前调用链不可达，属预防性修复）。

### 测试改动

新增 `testDmgURLRejectsHostsOutsideTheAllowlist`（含 `github.com.evil.test` 后缀绕过用例）与 4 项签名校验测试。因白名单生效，测试 fixture 中的下载域由 `example.com` 改为白名单内域名；无关用途的 `example.com`（SSH host、本地 URL 校验语义）保持原样。

### 遗留项

1. `expectedTeamIdentifier` 未启用 —— 依赖 Developer ID 证书。
2. socket 强认证 —— 依赖调用链改造（见上）。
3. 构建脚本未加签名步骤（本次按决定暂不处理）。
