# Kilo Code 接入

Kilo Code 是 Roo Code 停运后由社区延续的编程 Agent，2026 年重建为 OpenCode 内核，提供 VS Code 扩展（`kilocode.Kilo-Code`）和 CLI；2026-07-15 被 Anaconda 收购后产品与插件接口继续。它没有 shell hooks，但官方提供原生插件：同一份插件在 CLI 与 VS Code 扩展中都会加载。

X Island 的自动配置写入：

```text
~/.config/kilo/plugin/xisland.js
```

如果设置了 `XDG_CONFIG_HOME`，路径会随之改变为 `$XDG_CONFIG_HOME/kilo/plugin/xisland.js`。

## X Island 侧

1. 在 X Island 的接入设置里找到“Kilo Code”，点击配置。X Island 会写入 `xisland.js` 并安装本地桥接。
2. 完全退出并重启 Kilo CLI，或在 VS Code 里执行 “Developer: Reload Window”。
3. 开始一条 Kilo 任务，岛屿应在会话开始后显示 Kilo 的活动。

插件文件由 X Island 全量拥有；如果用户修改过它，X Island 在修复或卸载时会保留文件，不会覆盖用户内容。

## 能力与边界

- **只观察**：上报会话开始、用户提示、工具开始/完成、助手回复、会话空闲/错误/压缩、会话删除，以及“等待权限/等待回答”的状态。
- **不接管**：权限确认、问答、计划审阅和取消都留在 Kilo 内；插件不声明权限决定 hook，也不调用 `permission.reply`。
- **会话结束**：只有 Kilo 删除或归档会话时才发送 `session_end`；崩溃或直接关窗口不保证有结束事件，X Island 按空闲租约收敛。
- **覆盖范围**：CLI 与 VS Code 扩展共用插件；JetBrains 插件、`KILO_PURE=1`、企业策略禁用插件的环境不在覆盖内。
- **不推断完成**：助手文本或空闲状态不会被 X Island 当成“任务已成功完成”。

## 验证状态

- 插件源码、归属判定、路径转义与 JSON 帧契约已通过测试；生成文件经 `node --check` 解析。
- `di-bridge --agent kilo_code --adapter kilo_plugin` 的会话命名、工具事件和状态映射已通过契约测试。
- **尚未完成**：真实 Kilo CLI / VS Code 扩展加载插件、真实工具调用与权限提示的端到端验收。市场版本仅作静态核对，未在本机安装运行。

## 排错

- 插件未加载：确认 `~/.config/kilo/plugin/xisland.js` 存在，且没有设置 `KILO_PURE=1`；重启宿主而不是只新开一个会话。
- 有会话但没有工具：确认 Kilo 允许插件运行，并检查 Kilo 日志里是否有 `[XIsland] Kilo observer` 诊断。
- 权限状态出现但无法在岛上批准：这是预期行为，请回到 Kilo 完成确认。
