# WorkBuddy 观察插件

本通道已核对 WorkBuddy 5.7.6 / 5.7.7 的固定运行资源；两版相关资源一致，因此沿用合同标识 `workbuddy_5_7_6`。该标识不代表任意后续版本都已兼容，静态资源核对也不等于真实客户端已验收。

WorkBuddy 使用独立来源、图标、应用定位与接收开关，不将 CodeBuddy CLI 事件当成 WorkBuddy 事件。它作为额外客户端单独记录；状态见[适配矩阵](agent-matrix.json)。

## 导出与加载

安装 X Island 后，导出到一个父目录已存在、目标尚不存在的绝对路径，例如：

```sh
"/Applications/X Island.app/Contents/MacOS/di-bridge" workbuddy-plugin "$HOME/Desktop/xisland-workbuddy-observer"
```

生成三个文件：`.codebuddy-plugin/marketplace.json`、`.codebuddy-plugin/plugin.json` 与 `hooks/hooks.json`。市场清单将插件来源指向当前目录 `./`，采用已核对的 WorkBuddy 内置插件目录约定；既有目录、文件和符号链接不会被覆盖。

导出目录不包含桥接程序，hook 命令引用本次桥接程序的绝对路径。移动应用、使用其他构建或更新后应重新核对命令与版本，路径变化时重新导出；不要使用已经删除或替换的开发构建路径。

在 WorkBuddy 插件管理页的“添加市场”入口选择整个导出目录，核对插件和 11 条观察命令，再按客户端流程完成启用与信任。2026-10-27 已在 5.9.2 的现有启用环境验证真实任务触发和完成提醒；新安装环境的首次导入与信任流程仍需单独验收，导出成功不代表已接入。

X Island 的“WorkBuddy 插件观察”开关只控制接收；导出命令不会安装、启用插件或修改 WorkBuddy 配置。卸载时应先在 WorkBuddy 中停用或移除该插件，再移除自己导出的目录。

## 事件与能力

观察 11 类事件：SessionStart、UserPromptSubmit、PreToolUse、PostToolUse、PostToolUseFailure、Stop、FinalStop、SessionEnd、SubagentStart、SubagentStop、Notification。

- PreToolUse 只表示准备调用；结果事件保留已有工具 ID，缺少 ID 时不伪造配对。
- Stop 提供回复预览并保留“完成未确认”；FinalStop 的 `completed` 标记本轮完成并进入待查看，提醒开启时自动显示 X Island。同一聊天继续提问会恢复活动，下一轮完成可再次提醒。`cancelled` / `interrupted` 保持空闲，`failed` 显示错误，未知原因不推断成功。
- SessionEnd 与 SubagentStop 不自动关闭父会话，嵌套代理的归属和结束行为仍需真实客户端确认。
- 当前没有注册 PermissionRequest，也不回传允许、拒绝或问答决定，原生权限与交互继续在 WorkBuddy 处理。

## 验证范围

`Scripts/test-workbuddy-plugin.py` 使用合成事件检查导出的三个文件、11 条观察命令、隔离 socket 往返、空 stdout、既有导出保护及无效载荷处理。部分合成事件也已进入隔离 X Island 验证界面和历史状态；这些测试执行的是桥接与 X Island，没有证明 WorkBuddy 已加载插件。

2.0.0 的测试结果保留在[历史验证摘要](release-verification-2.0.0.json)。首次导入与信任、嵌套代理及完整客户端交互仍列入[验收缺口](acceptance-gaps.md)；已启用环境中的两轮真实任务完成提醒见下方专项记录。

2026-10-27 对 WorkBuddy 5.9.2 的主任务 FinalStop 调用链及完成提醒修复另有[专项验证记录](../verification/2026-10-27-workbuddy-completion.md)。该记录区分自动测试与真实客户端验收，不代表所有嵌套代理、压缩恢复和并发回合已验证。

## 复制给 LLM

WorkBuddy 需要手动导入插件；Agent 可以导出和核对文件，但不能代替你在 WorkBuddy 里完成“添加市场”和信任。

```text
你是我的 macOS 配置助手。请为本机 X Island 导出 WorkBuddy 观察插件，并核对待导入内容。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 导出命令是 di-bridge workbuddy-plugin <目标绝对路径>，目标必须尚不存在且父目录存在。
- 固定核对基线是 WorkBuddy 5.7.6 / 5.7.7；当前版本或新安装环境的首次导入仍需单独验收。
- 插件只观察，不接管审批或问答。

执行：
1. 检查 WorkBuddy 版本和现有插件目录，选择一个不会被覆盖的新绝对路径，备份已有导出（若存在）。
2. 运行导出命令，确认生成 .codebuddy-plugin/marketplace.json、.codebuddy-plugin/plugin.json 和 hooks/hooks.json，且命令指向现有 di-bridge。
3. 检查 11 条观察命令和插件清单，输出目录树和关键 diff；不要修改 WorkBuddy 自己的配置。
4. 告诉我需要在 WorkBuddy 插件管理页的“添加市场”中选择整个导出目录，核对插件后启用并信任。
5. 我完成导入后，发一条只读任务，检查 X Island 是否出现会话和完成提醒。

边界：
- 不覆盖已有目录、文件或符号链接；导出成功不等于已安装或已接通。
- 不伪造审批、问答或取消；不自动启用插件。
- 完成后报告：导出目录、文件列表、核对结果、仍需我手动完成的导入/信任步骤和真实事件结果。
```
