# Trae hooks 配置指南

Trae 通过全局 `hooks.json` 把会话事件交给 X Island。本文说明自动与手动两种配置方式，以及验证方法。

## 支持的发行版

| 发行版 | 全局配置路径 |
|---|---|
| Trae CN | `~/.trae-cn/hooks.json` |
| Trae（国际版） | `~/.trae/hooks.json` |

两版共用同一套 `version: 1` 协议与六个事件：SessionStart、UserPromptSubmit、PreToolUse、PostToolUse、Stop、Notification。

> 项目级配置是 `<项目>/.trae/hooks.json`，与全局配置互不影响。X Island 只写全局配置。

## 方式一：让 X Island 自动写入

1. 打开 X Island **设置 → 集成**
2. 找到 Trae，点「配置」
3. 若两个发行版都已安装，会分别写入各自的全局配置

写入内容形如：

```json
{
  "version": 1,
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "'$HOME/.xisland/bin/di-bridge' --agent trae --hook SessionStart --adapter trae_cn || true", "timeout": 5 } ] }
    ]
  }
}
```

其余五个事件结构相同，只替换 `--hook` 参数。

## 方式二：手动配置

在对应路径创建 `hooks.json`，把下面六个事件补齐（`$HOME` 替换为实际绝对路径）：

```json
{
  "version": 1,
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "'/Users/you/.xisland/bin/di-bridge' --agent trae --hook SessionStart --adapter trae_cn || true", "timeout": 5 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "'/Users/you/.xisland/bin/di-bridge' --agent trae --hook UserPromptSubmit --adapter trae_cn || true", "timeout": 5 } ] }
    ],
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "'/Users/you/.xisland/bin/di-bridge' --agent trae --hook PreToolUse --adapter trae_cn || true", "timeout": 5 } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "'/Users/you/.xisland/bin/di-bridge' --agent trae --hook PostToolUse --adapter trae_cn || true", "timeout": 5 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "'/Users/you/.xisland/bin/di-bridge' --agent trae --hook Stop --adapter trae_cn || true", "timeout": 5 } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "'/Users/you/.xisland/bin/di-bridge' --agent trae --hook Notification --adapter trae_cn || true", "timeout": 5 } ] }
    ]
  }
}
```

## 生效条件

配置写入不等于生效，还需要：

1. **在 Trae 设置里启用 Hooks**：设置 → Hooks，确认全局配置已列出且开关打开（首次需要阅读安全提示）
2. **完全退出并重启 Trae**：hooks 在客户端启动时加载，仅关闭窗口不够
3. Trae 版本需支持该功能。若设置里找不到 Hooks 入口，说明当前版本不支持，需升级

## 验证

**方式一：手动模拟**

```bash
echo '{"hook_event_name":"SessionStart","session_id":"test-1","cwd":"/tmp"}' \
  | ~/.xisland/bin/di-bridge --agent trae --hook SessionStart --adapter trae_cn
```

输出 `{}` 且退出码为 0，说明桥接正常。

**方式二：看 Trae 日志**

```bash
grep -r "di-bridge" "$HOME/Library/Application Support/Trae CN/logs" | tail
```

- 有记录 → hook 在调用
- 完全没有 → hook 未执行（未启用或版本不支持）

**方式三：面板**

在 Trae 里发一条消息，X Island 面板应出现该会话。

## 常见问题

**配置正确但面板没有会话**

按顺序检查：Trae 是否重启过；设置 → Hooks 是否启用；日志里有没有 `di-bridge`。

**面板里会话很快消失**

面板默认只显示「活跃窗口」（最近 24 小时有对话），可在设置里调整时间范围，或右键会话选择「保留在活跃列表」。

**旧版本残留多条配置**

旧格式（`beforeSubmitPrompt`、`afterAgentResponse` 等扁平事件）不会被新协议读取。X Island 在写入时会移除指向自身桥接的旧条目；也可直接删除 `hooks.json` 后重新配置。
