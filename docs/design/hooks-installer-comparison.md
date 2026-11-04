# Hooks 安装器逐行对比：coucou / CodeIsland / ping-island / MioIsland

> 对比日期：2026-11-03
> 目的：找出 X Island `DIBridge` 注入链路相对成熟实现的具体差距

## 〇、对比基线

| 项目 | Commit | 核心文件 | 行数 |
|---|---|---|---|
| coucou | `e9fc337`（2026-11-03） | `NotchBuddy/Sources/App/ClaudeSettingsFile.swift` | 145 |
| | | `NotchBuddy/Sources/App/HookServer.swift`（安装段 1567-1737） | 4286 |
| CodeIsland | `03c77e9`（2026-10-28） | `Sources/CodeIsland/ConfigInstaller.swift` | 4316 |
| | | `Sources/CodeIslandCore/ConfigPathIdentity.swift` | 104 |
| ping-island | `6c9bdfe`（2026-10-15） | `PingIsland/Services/Hooks/HookInstaller.swift` | 4618 |
| MioIsland | `e534d0ef`（2026-10-13） | `ClaudeIsland/Services/Hooks/HookInstaller.swift` | 295 |
| **X Island** | 本地 v2.0.15 | `Sources/DynamicIsland/Models/HookConfigurationFile.swift` | 200 |
| | | `Sources/DynamicIsland/Managers/ZeroConfigManager.swift` | ~1400 |

方法：只精读**写入路径**相关代码（不含事件解析、UI、UI 测试），共 4 个写入通道 + 4 个合并策略 + 4 个清理策略。

**许可证提示**：MioIsland 为 CC BY-NC 4.0，其代码**不可**复制进 X Island。本表中它的价值仅为"反面对照"。

---

## 一、核心结论

**四家在"写入别人拥有的配置文件"这件事上的严谨度排序：**

```
X Island（你）  >  coucou  >>  CodeIsland  >  ping-island  ≈  MioIsland
```

与直觉相反：**你的 `HookConfigurationFile` 是五份实现里最严谨的**——双重 CAS、inode/mtime/ctime 校验、`O_NOFOLLOW`、fsync、失败回滚，任一项单拎出来都比 coucou 更强。

你的真实短板不在"写入安全"，而在两处**产品工程能力**：

1. **JSONC 注释保不全** —— 每次重写 `settings.json` 都会丢用户注释（与 coucou / ping-island / MioIsland 同级，落后 CodeIsland）
2. **`contains("di-bridge")` 字符串匹配散落 14 处** —— 卸载/去重精度与四家同级，但集中重构的收益最高

另有两条你已经做对、且优于多数竞品，不要为了"对齐"而改掉：

- **未安装的 Agent 不会创建目录** —— 统一走 `IntegrationSetupDiscovery` 检测（CodeIsland 是每客户端分散 `fileExists`，可维护性更差）
- **幂等比对用语义而非文本** —— `NSDictionary.isEqual(to:)` 规避了 Swift 字典序随机导致的重写

---

## 二、15 维度对照表

图例：✅ 做对 ／ ⚠️ 有实现但有缺陷 ／ ❌ 未做

| # | 维度 | coucou | CodeIsland | ping-island | MioIsland | **X Island** |
|---|---|---|---|---|---|---|
| 1 | 写入原子性 | ✅ temp+`rename()` | ❌ `createFile` | ❌ `write(to:)` | ❌ `write(to:)` | ✅ temp+`rename()` |
| 2 | 并发冲突检测 | ✅ 字节 CAS | ⚠️ 仅比对内容 | ❌ | ❌ | ✅ **双重** CAS |
| 3 | 写前备份 | ✅ 明文 `.bak-时间戳` | ❌ | ❌ | ❌ | ⚠️ 隐藏 `.bak-UUID` |
| 4 | 失败回滚 | ✅ 抛错不写 | ❌ `try?` 吞错 | ❌ `try?` 吞错 | ❌ `try?` 吞错 | ✅ `defer` 清理 |
| 5 | 权限保持 | ✅ 沿用原 mode | ⚠️ 仅脚本 0700 | ❌ | ❌ | ✅ `fchmod` |
| 6 | fsync 落盘 | ❌ | ❌ | ❌ | ❌ | ✅ `synchronize()` |
| 7 | 符号链接 | ✅ 解析最终目标 | ✅✅ dangling/大小写/NFC | ❌ | ❌ | ✅ 链接身份绑定 |
| 8 | 类型异常防御 | ✅ 抛错不覆盖 | ⚠️ 部分 | ❌ 兜底空对象 | ❌ 兜底空对象 | ✅ 抛错 |
| 9 | JSONC 注释保留 | ❌ 丢弃 | ✅✅ `JSONMinimalEditor` | ❌ strip 后丢弃 | ❌ 丢弃 | ❌ 丢弃 |
| 10 | 幂等（不重写） | ❌ 每次重建 | ✅ `isSameJSONDocument` | ⚠️ `normalizedHookEntries` | ⚠️ `contains` 检查 | ✅ `NSDictionary` 比对 |
| 11 | 卸载精度 | ⚠️ `contains("nb-hook")` | ⚠️ `contains("codeisland")` | ⚠️ `islandManaged` | ⚠️ `contains("codeisland-state.py")` | ⚠️ `contains("di-bridge")` ×14 |
| 12 | 未装 CLI 不创建 | ✅ 仅 Claude | ✅✅ 逐客户端守卫 | ⚠️ | ❌ 无条件建 `~/.claude/hooks/` | ✅ `IntegrationSetupDiscovery` 统一检测 |
| 13 | 自检修复漂移 | ✅ `hooksNeedUpdate()` | ✅✅ `verifyAndRepair()` | ✅ `bridgeHealthStatus()` | ❌ | ✅ `repairHooksIfNeeded()` |
| 14 | 预览-确认 | ✅✅ preview→write | ❌ | ❌ | ❌ | ✅ 有 diff 预览 |
| 15 | 沙箱(App Store) | ✅✅ `NSOpenPanel`+版本号 | ❌ | ✅✅ 安全书签 bookmark | ❌ | ❌ |

---

## 三、逐维度详解

### 1. 原子写：只有 coucou 和你是对的

**coucou**（`ClaudeSettingsFile.swift:107-126`）注释写得很明确：

```swift
// Written beside the target and renamed over it: a crash or a full disk
// leaves the original intact rather than half a file.
let temp = target.deletingLastPathComponent()
    .appendingPathComponent("\(target.lastPathComponent).coucou-\(pid)")
guard fm.createFile(atPath: temp.path, contents: data, ...) else { throw .writeFailed(name) }
guard rename(temp.path, target.path) == 0 else { try? fm.removeItem(at: temp); throw .writeFailed(name) }
```

**CodeIsland 是假的原子**（`ConfigPathIdentity.swift:52-56`）：

```swift
public static func write(_ data: Data, to path: String, fileManager: FileManager = .default) -> Bool {
    let target = writeTarget(for: path)
    if fileManager.createFile(atPath: target, contents: data) { return true }   // O_CREAT|O_TRUNC，非原子
    return target != path && fileManager.createFile(atPath: path, contents: data)
}
```

注释写「the same atomic replace as before」，但 `createFile` 是截断原文件后写入。磁盘满或崩溃会留下**半截 settings.json**，下次读取即 JSON 解析失败 → 用户所有 Claude Code 配置失效。这是 CodeIsland 4316 行里最值得警惕的一处。

**ping-island**（`HookInstaller.swift:4450-4469`）更隐蔽：同一文件里 `writeData()` 用了 `.atomic`，但**写 JSON 配置的 `writeJSONObject()` 没用**：

```swift
// 4464: 写普通数据 —— 正确
try? data.write(to: url, options: .atomic)

// 4450: 写 settings.json —— 缺少 .atomic
if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: url)     // 少了一个 options
}
```

**MioIsland**（`HookInstaller.swift:104-109`）同样：`try? data.write(to: settingsURL)`。

### 2. 并发冲突检测：你的实现最强

coucou 的比较基准是**原始字节**（`expecting original: Data?`）：

```swift
guard current == original else { throw Failure.changed(name) }
```

你的是**文件身份 + 全字段时间戳**，并且校验两次（读入时、rename 前）：

```swift
// HookConfigurationFile.swift:99-107 —— 读入后确认未变
guard FileIdentity(opened) == FileIdentity(after), opened.st_size == after.st_size,
      opened.st_mtimespec == after.st_mtimespec,
      opened.st_ctimespec == after.st_ctimespec,
      try metadata(at: url).map(FileIdentity.init) == FileIdentity(after) else {
    throw ConfigurationError.configurationChanged(url.path)
}
// :157-160 —— 写入前再校验一次，缩小 TOCTOU 窗口
guard try RegularFile.read(at: temporary) == staged else { throw ... }
try snapshot.validate()
```

差别：coucou 的字节比对能发现内容变化，但**发现不了"内容相同、归属已变"**（另一进程用同样内容覆盖了文件）。inode 比对能发现。

CodeIsland 与 ping-island 都没有 CAS；MioIsland 没有。

### 3. 备份：你做了，但用户找不到

coucou 的备份是**给人看的**：`~/.claude/settings.json.bak-20261103-230045`。`freeBackupURL()` 还特意处理了"同一秒内安装+卸载"导致备份被覆盖的边界（重名追加 `-2`、`-3`）。

你的备份是 `.settings.json.xisland-{UUID}.bak` —— 隐藏文件、UUID 命名、成功后不删除。安全性等价，但**用户无法自行恢复**：出问题时要靠你的程序读，而不是靠用户 `mv` 回来。

这是可以立刻改的：改成 `settings.json.bak-{yyyyMMdd-HHmmss}` 并去掉前导点。

### 4. 类型异常：两家把"读不懂"当成"空"

这是最危险的模式。coucou 在文件头专门立了规矩（`ClaudeSettingsFile.swift:5-7`）：

```swift
// never start from an empty object when the file is there but unusable,
// always take a backup, and only ever write over the exact bytes the user was shown.
```

**MioIsland**（`HookInstaller.swift:49-53`）：

```swift
var json: [String: Any] = [:]
if let data = try? Data(contentsOf: settingsURL),
   let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    json = existing
}
// 解析失败 → json 保持 [:] → 后面 json["hooks"] = hooks → 整体覆盖写回
```

**后果**：用户的 `settings.json` 若含注释（JSONC）、尾逗号或任何语法错误，Claude Code 本身能容忍（宽松解析器），但 MioIsland 解析失败后会**用只含 hooks 的新对象覆盖整个文件**——`env` 里的 API key、`permissions`、`model`、`statusLine` 全部丢失。

**ping-island**（`HookInstaller.swift:1727-1731`）同样的 `var json: [String: Any] = [:]` 兜底，但有缓解：`HookConfigParser.parseJSONObject` 会先剥注释与尾逗号（`stripJSONComments` / `removeTrailingCommas`，第 29 / 102 行）。代价是重写后注释永久消失。

### 5. 幂等：为什么这一条不能省

CodeIsland 的注释记录了一个真实事故（`ConfigInstaller.swift:1737-1740`）：

```swift
// Runs on every launch: a file that already says this is left alone.
// The dictionaries we build serialize in a different key order in
// each process, so writing anyway rewrote every config on every launch.
if let originalText, isSameJSONDocument(originalText, merged) { return true }
```

**根因**：Swift `Dictionary` 遍历顺序**每进程随机**（per-process hash seed）。`[.sortedKeys]` 能固定输出，但嵌套结构某一层没排序时结果每次仍不同 → 每次启动判定"有变化" → 重写文件 → dotfiles 同步噪声、备份膨胀、Git 脏。

你的 `NSDictionary.isEqual(to:)` 做语义比对，规避了这个坑（比 CodeIsland 的文本比对更稳）。这一条你已经做对。

### 6. 未安装的 Agent：CodeIsland 做得最干净

CodeIsland 每个客户端都有存在性守卫：

```swift
// ConfigInstaller.swift:1763-1765（Kimi）
guard kimiPresenceDetected(fm: fm) else { return true }
// :1778-1781（Copilot）
guard fm.fileExists(atPath: NSHomeDirectory() + "/.copilot") else { return true }
// :1785-1790（Grok）
let rootDir = (cli.dirPath as NSString).deletingLastPathComponent
guard fm.fileExists(atPath: rootDir) else { return true }
```

**MioIsland 相反**（`HookInstaller.swift:31-34`）：

```swift
try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
// hooksDir = ~/.claude/hooks —— 无条件创建
```

没装 Claude Code 的 Mac 上也会凭空出现 `~/.claude/hooks/codeisland-state.py` 和一份 `settings.json`。用户卸载后发现残留，会认为是恶意软件。

危害在**卸载后**才显现：配置目录是被你的程序创建的，用户的清理工具不认，`~/.claude` 永远不会消失。

**你这一条是干净的**（`ZeroConfigManager.swift:25-29`）：

```swift
let detected = IntegrationSetupDiscovery.automaticAgents(in: discovered, requested: agents)
guard !detected.isEmpty else { return }
...
for agent in AgentType.allCases where detected.contains(agent) && isAutoConfigEnabled(for: agent) {
```

统一走 `IntegrationSetupDiscovery` 检测，比 CodeIsland 分散在每个 `installXxxHooks` 里各自 `fileExists` 更好维护——**这是你可以保留的架构优势，不要为了"对齐 CodeIsland"而拆散它。**

### 7. 卸载精度：四家全是字符串包含，包括你

| 项目 | 判定方式 | 误删风险 |
|---|---|---|
| coucou | `cmd.contains("nb-hook")` | 低（名字独特） |
| CodeIsland | `lower.contains("codeisland") \|\| legacyNames...` | 中 |
| ping-island | `islandManaged(entry)` | 低 |
| MioIsland | `cmd.contains("codeisland-state.py")` | 低 |
| **X Island** | `cmd.contains("di-bridge")` ×14 处 | 低，但**重复 14 次** |

coucou 的注释表现出了对这个问题的意识（`HookServer.swift:1700-1702`）：

```swift
// Remove only our own nb-hook entries, not whole groups that merely
// mention us: a user hook like ~/dev/coucou/scripts/lint.sh must survive.
```

但实现仍是 `contains("nb-hook")`——**注释与代码不一致**。真正精准的做法（四家都没做）是匹配**完整命令结构**而非子串：路径必须等于 `~/.xisland/di-bridge` 且参数落在已知集合内。

### 8. 沙箱：只有 coucou 和 ping-island 真做了

Mac App Store 版本无法直接读写 `~/.claude`（沙箱把 `homeDirectoryForCurrentUser` 重定向到容器）。两家解法不同：

- **coucou**：`NSOpenPanel` 让用户主动授权目录，并用 UserDefaults 记录 hook 脚本版本（`appStoreHookVersion`），沙箱内读不到 settings.json 就靠版本号判断是否需要更新。
- **ping-island**：安全作用域书签（security-scoped bookmark），`persistAppStoreHookDirectoryBookmark` 持久化授权，重启后由 `restoreAppStoreHookDirectoryAuthorizationIfAvailable` 恢复。

如果要上 App Store，这一块是**必须新写**的，四家里只有 ping-island 的 bookmark 方案可直接参考（Apache-2.0，可抄）。

---

## 四、三处可以立刻改的地方

按投入产出比排序：

### 1. 备份改成用户可见（10 分钟）

```swift
// HookConfigurationFile.swift:153
let recovery = directory.appendingPathComponent(
    ".\(url.lastPathComponent).xisland-\(UUID().uuidString).bak")
```

改为 `settings.json.bak-20261103-230045`（coucou 的 `freeBackupURL` 模式，含同秒去重）。

理由：备份的唯一价值是在你程序也跑不起来时还能救；UUID 隐藏文件名等于没有。

### 2. JSONC 注释保留（半天，收益最大）

现状：`JSONSerialization.data(withJSONObject:options:[.prettyPrinted, .sortedKeys])` 全量重写 → 注释与键序全丢。

两条路线：

- **A（推荐）**：抄 CodeIsland 的 `JSONMinimalEditor.setTopLevelValue` 思路——只替换 `hooks` 这一个顶层键的文本区间，其余字节原样保留。MIT 许可允许，且它只处理顶层键，逻辑量约 200 行。
- **B（更省事）**：写前检测原文件是否含注释（`//` 或 `/*` 且不在字符串内），含则**跳过自动安装并提示用户手动合并**，附 diff。

### 3. `contains("di-bridge")` 收敛为单一判定函数（1 小时）

现状：`ZeroConfigManager.swift` 里 14 处重复的 `contains("di-bridge")`，第 808 行还混入 `contains("codeisland-state.py")` 用于清理别人的遗留。

风险：改一次二进制名要改 14 处；漏一处就会"装了两份 hook"。

建议：

```swift
enum BridgeHookId {
    static let current = "di-bridge"
    static let legacy = ["codeisland-state.py", "ping-island-bridge"]
    /// 精确匹配：命令首个 token 的 basename 必须等于 current
    static func isOurs(_ command: String) -> Bool { ... }
}
```

---

## 五、不需要抄的部分

避免过度工程。以下四家做法**不建议**跟进：

| 做法 | 出处 | 不跟的理由 |
|---|---|---|
| 4316 行单文件 | CodeIsland | 30+ 客户端 + JSONC/YAML/TOML 三种格式混在一个 struct，编译与测试成本过高。你的「每客户端一个 Models 文件」更可维护 |
| 4618 行含手写 TOML 解析器 | ping-island | 只有 Codex 用 TOML，且 Codex 自己会重写该文件。用现成库，或只读不写 |
| `installIfNeeded()` 启动即装 | MioIsland | 无预览、无确认、无备份。你已有 preview→confirm 两段式，方向正确 |
| 无条件建配置目录 | MioIsland / ping-island | 见第 6 节 |

---

## 六、一句话总结

**你的写入内核已经超过四家；真正要补的是"对用户已有配置的尊重"——注释不要丢、目录不要凭空建、卸载不要靠字符串猜。**

前两条是产品信任问题，第三条是代码卫生问题。写入安全再强，只要有一次把用户的 `settings.json` 注释洗掉，信任就没了。
