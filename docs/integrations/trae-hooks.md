# Trae hooks 配置指南

Trae 通过全局 `hooks.json` 把会话事件交给 X Island。本文说明自动与手动两种配置方式，以及验证方法。

## 支持的发行版

国内版与国际版的**全局** Hook 读取同一个文件：

| 类型 | 路径 | 生效范围 |
|---|---|---|
| 全局 Hook | `~/.trae-cn/hooks.json` | 本机所有工作区（国内版与国际版共用） |
| 项目 Hook | `<项目>/.trae/hooks.json` | 仅该项目/工作区 |

> `~/.trae/hooks.json` 看起来像"国际版全局配置"，但它实际是**项目级**路径——只有当那个目录本身作为工作区打开时才生效。不要把全局配置写在这里。

两版共用同一套 `version: 1` 协议与六个事件：SessionStart、UserPromptSubmit、PreToolUse、PostToolUse、Stop、Notification。

## 方式一：让 X Island 自动写入

1. 打开 X Island **设置 → 集成**
2. 找到 Trae，点「配置」
3. 写入的是两版共用的全局配置 `~/.trae-cn/hooks.json`，国内版与国际版都会读取它

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

## 复制给 LLM

```text
你是我的 macOS 配置助手。请为本机 Trae 配置 X Island 全局 hooks。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- Trae 国内版与国际版共用全局配置 $HOME/.trae-cn/hooks.json；$HOME/.trae/hooks.json 是项目级路径，不要写它。
- 需要六个事件：SessionStart、UserPromptSubmit、PreToolUse、PostToolUse、Stop、Notification，version 为 1。

执行：
1. 检查 Trae 版本和实际发行版，备份 $HOME/.trae-cn/hooks.json，读取现有 hooks。
2. 输出 diff，只合并 X Island 的六条命令（--agent trae --adapter trae_cn），保留第三方 hooks 和其他配置；移除指向 X Island 的旧扁平事件条目。
3. 校验 JSON 后，告诉我需要在 Trae 设置 → Hooks 中确认全局配置已列出并打开开关，然后完全退出并重启 Trae。
4. 重启后发一条只读任务，检查 X Island 面板是否出现会话；必要时查看 Trae 日志中的 di-bridge 调用。

边界：
- 不要把全局配置写到项目级 ~/.trae/hooks.json；国际版和 Solo 的结果不能直接算给 CN，反之亦然。
- 不自动批准权限，不代替我在 Trae 里启用 Hooks 或确认安全提示。
- 完成后报告：改动文件、备份、JSON 校验、Trae 是否重启、日志证据和真实会话结果。
```
