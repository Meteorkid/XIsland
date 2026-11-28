# G7 运行时风险扫描

- 扫描日期：2026-11-28
- 扫描范围：`Sources/**/*.swift`，共 267 个 Swift 文件
- 扫描 token：`try!`、`as!`、`fatalError(`
- 扫描命令：`rg -n --glob '*.swift' 'try!|as!|fatalError\s*\(' Sources`

## 改动前结果

实际危险 token 共 5 处，另有 1 处仅为注释：

| 位置 | token | 判断 |
| --- | --- | --- |
| `Sources/DynamicIsland/Managers/SSHRemoteManager.swift` 24–27 行 | 4 个 `try!` | `NSRegularExpression` 初始化可抛错，静态属性初始化失败会直接终止进程；选为安全化路径 |
| `Sources/DynamicIsland/Managers/AXConversationFocus.swift` 253 行 | 1 个 `as!` | 紧邻的 `CFGetTypeID(value) == AXUIElementGetTypeID()` 已保证类型；Swift 不允许对 CF 类型使用 `as?`，`unsafeBitCast` 也不会更安全，保留 |
| `Sources/DynamicIsland/Models/AgentRegistry.swift` 330 行 | `fatalError` 仅出现在注释 | 说明此前已替换为兜底分支，无实际调用 |

## 本轮处置

`SSHInputValidator` 的四个静态正则从 `try!` 改为 `compilePattern()` 返回可选值；匹配函数在正则为 `nil` 时返回 `false`，所有校验路径随后抛出 `SSHValidationError`，即“编译失败就拒绝输入”，不再崩溃。四个正则属于同一个静态初始化路径，因此在本轮一并处理，没有扩展到其他模块。

新增回归测试：

- 非法正则返回 `nil`，`nil` 正则的匹配结果为 `false`。
- Host、User、RemotePath 拒绝 shell 元字符。
- 合法 Host、User、RemotePath 仍按原行为通过。

## 改动后结果

再扫描 `try!`、`as!`、`fatalError(`：只剩 `AXConversationFocus.swift` 中一处已有 CFTypeID 前置校验的 `as!`；`try!` 和实际 `fatalError` 调用均为 0。

## 验证结果

- `swift test --filter SSHRemoteCommandTests -j 2`：8 项执行、0 失败。
- `swift test -j 2`：`XIslandTests` 2222 项、20 跳过、0 失败，87.573 秒；`MeteorLicenseCoreTests` 31 项、1 跳过、0 失败；合计 2253 项、21 跳过、0 失败。
- `swift build -c release --product XIsland -j 2`：通过，65.05 秒。
- `python3 Scripts/check-docs.py`：通过，110 个 Markdown 文件。

## 自动化门禁

G9 新增 `Scripts/check-swift-safety.py`，把 `try!`、`fatalError(`、`as!` 扫描固化为本地门禁；已有 `as!` 使用同行 `swift-safety: allow` 标记并保留理由。负向测试见 `Scripts/test-check-swift-safety.py`。G10 已把安全门禁与负向测试接入 `.github/workflows/docs.yml`。

## 残余风险

- `AXConversationFocus` 的强制转换依赖 CoreFoundation 类型 ID 校验；若未来移除该 guard，需要同时重新评估。
- 静态正则若因未来编辑变成非法 pattern，SSH 校验会 fail-closed 拒绝所有操作。这是预期行为，错误信息仍为对应字段的 `invalidHost` / `invalidUser` / `invalidPath`。
