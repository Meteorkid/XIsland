# Zed / JetBrains 外部 ACP Agent 接入

本通道只覆盖显式经包装器启动的外部 ACP Agent。请先按所选编辑器和 Agent 的实际版本检查配置并验证真实任务；项目契约测试不代表所有编辑器内置 AI 功能已兼容。

## 生成可审查配置

将一个已存在且能独立运行的自定义Agent条目存成JSON，例如：

```json
{"type":"custom","command":"/absolute/path/to/agent","args":["acp"],"env":{}}
```

Zed条目需要`type: custom`；JetBrains条目通常没有type，可保留原样。这里的command/args必须来自真实可用的Agent，不是让任意CLI自动变成ACP。

```sh
"/Applications/X Island.app/Contents/MacOS/di-bridge" acp-config --host zed --source my-agent < agent-entry.json > wrapped-entry.json
# JetBrains 使用 --host jetbrains_ai
```

审查输出后，将它放入对应`agent_servers.my-agent`。Zed使用其实际settings.json，JetBrains使用实际`~/.jetbrains/acp.json`。不要把整个含注释settings文件直接送入此命令，不要覆盖其他Agent或MCP设置。命令本身不写文件、不读取账号或修改信任。

还原匹配的条目：

```sh
"/Applications/X Island.app/Contents/MacOS/di-bridge" acp-config --unwrap --host zed --source my-agent < wrapped-entry.json > restored-entry.json
```

## 使用与能力

原编辑器继续处理权限、拒绝、取消和输入表单；XIsland显示已验证的会话、文本、工具及等待状态。配置写入不等于客户端已启用或全部AI功能兼容。未知协议字段和大载荷保持原样透传，观察失败不生成批准响应。

包装器按协商版本分别处理 ACP v1 / v2，不将 v2 提示接收确认当成完成。当前不覆盖内置 Zed Agent、普通 AI Assistant / 补全或全部 Junie 路径；实际客户端、大历史与完整交互仍待验收。验证层级见[公开摘要](release-verification-2.0.0.json)。

## 复制给 LLM

把下面整段发给能操作本机的 Agent。它会先要求你提供真实可用的外部 ACP Agent 命令，再生成包装条目；不会安装 Agent，也不会接管编辑器权限。

```text
你是我的 macOS 配置助手。请为本机 X Island 配置一个已经存在的外部 ACP Agent，用于 Zed 或 JetBrains 接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 我不是要你安装新的 ACP Agent；必须先向我索取一个已能独立运行的 command 和 args。
- 该通道只包装显式启动的外部 Agent；不覆盖编辑器内置 AI、普通补全或全部 Junie 路径。

执行：
1. 先向我确认：编辑器是 Zed 还是 JetBrains、Agent 的实际启动命令、稳定 source 名称、条目 JSON 路径。
2. 把该条目保存为临时 JSON，使用 di-bridge acp-config 生成候选：Zed 用 --host zed，JetBrains 用 --host jetbrains_ai；先输出到 /tmp 下的新文件，不要覆盖原配置。
3. 读取候选文件并与现有配置比较，向我展示将插入 agent_servers 的条目和 diff；我确认后再写入实际 settings.json 或 ~/.jetbrains/acp.json。
4. 保留其他 Agent、MCP 和注释；不修改认证、模型和内置 AI 配置。
5. 重启编辑器，在编辑器里选中该外部 Agent 并发一条只读任务；权限、拒绝和输入表单仍由编辑器处理。

边界：
- 不把任意 CLI 当作 ACP Agent；命令或协议不明确时停止。
- 不自动批准权限，不代替我在编辑器里确认信任。
- 完成后报告：生成的候选文件、写入位置、备份路径、编辑器加载结果和真实会话是否到达 X Island。
```
