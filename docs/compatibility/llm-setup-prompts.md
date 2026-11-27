# 复制给 LLM：接入配置提示库

更新日期：2026-11-27。

本页给每个客户端一段可直接复制给本机 LLM Agent 的提示，让 Agent 代你检查版本、合并 hooks 或插件、准备需要手动导入的文件，并完成基础验证。适用于 Claude Code、Codex、Cursor 等能读写本机文件的 Agent，不要求你手写配置文件。

已有单独接入指南的客户端，提示写在对应指南末尾；本页覆盖其余来源，以及停用来源的替代建议。所有提示都遵循同一条边界：**配置不等于接通，信任必须由你在原客户端确认，Agent 不得代你授权。**

## 使用方式

1. 在下面找到你实际使用的客户端，整段复制提示，不要只复制其中的命令。
2. 在能访问本机终端的 Agent 里执行，例如 Claude Code、Codex、Cursor Agent 或 Terminal 中的 Agent。
3. Agent 先检查、备份、打印 diff，再写入；遇到它无法确认的版本或格式，应停止而不是猜。
4. 写完后由你在原客户端完成“启用 / 信任 / 重载”，再发一条只读任务。
5. 只有 X Island 真正收到该客户端的事件，才算接通；配置文件存在不能作为接通证据。

## 通用边界

- 只改提示中列出的客户端配置；保留第三方 hooks、插件、MCP、模型、JSONC 注释和凭据。
- 不执行 `sudo`，不下载未知脚本，不写 API Key，不关闭客户端安全检查。
- 不自动批准权限、不自动回答问题、不伪造审批结果；需要客户端内确认时，列出步骤交给用户。
- 修改前备份到 `~/.xisland/backups/llm-setup-<时间>/`，并在完成后给出原文件与备份路径。
- 不把“文件已写入”“版本已检测”描述为“已接通”；只报告真实检查结果和仍待用户完成的步骤。

## Claude Code

适用：原生 `settings.json` hooks，支持权限、问答、计划审查和文件改动审批回传。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「Claude Code」接入，直接执行，不要只给建议。

已知：
- X Island 已安装在 /Applications/X Island.app，桥接程序是 $HOME/.xisland/bin/di-bridge。
- Claude Code 的目标配置是 $HOME/.claude/settings.json；如果设置了 CLAUDE_CONFIG_DIR，使用该目录下的 settings.json。
- 只合并 X Island 自己的 hooks 条目，命令应指向现有的 di-bridge，并使用 --agent claude_code。事件名与结构沿用当前 Claude Code 官方 hooks 合同，不要复制过时的第三方示例。

执行：
1. 检查 Claude Code 版本、配置路径和现有 hooks，备份目标文件。
2. 输出将要新增或替换的条目 diff；只替换 command 中包含 di-bridge 且来源为 claude_code 的条目，保留其他 hooks、MCP、权限、模型和注释。
3. 合并后校验 JSON 可解析，并确认 PermissionRequest 条目没有被 || true 吞掉退出码。
4. 重启 Claude Code，让我新建一个会话并发一条只读任务。
5. 检查 X Island 是否出现会话；如果 Claude Code 弹出 hooks 信任确认，停下来把需要我点击的步骤列出来。

边界：
- 不要自动批准任何工具权限，不要替我回答 AskUserQuestion，不要修改 Claude Code 的全局权限模式。
- 遇到配置格式、版本或事件合同不一致时停止，保留原文件并说明原因。
- 完成后报告：改动的文件、备份路径、JSON 校验结果、X Island 是否收到事件，以及仍需我手动确认的步骤。
```

## Codex

适用：原生 `hooks.json`，配置后需要在 Codex 的 Review hooks 中由用户单独信任。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「Codex」接入，直接执行。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- Codex 的目标配置是 $HOME/.codex/hooks.json；如果设置了 CODEX_HOME，使用该目录下的 hooks.json。
- 只合并 X Island 自己的条目，命令使用 --agent codex；不要复制无关的第三方 hooks，也不要改 config.toml 中与 hooks 无关的设置。

执行：
1. 检查 Codex 版本、配置路径和现有 hooks，备份目标文件。
2. 输出 diff 后合并；保留第三方 hooks 和其他配置，只替换 command 指向 di-bridge 且来源为 codex 的条目。
3. 校验 JSON 可解析，确认所有 X Island 条目的命令和超时字段完整。
4. 重启 Codex，然后停下来告诉我：需要在输入区 Composer 打开 Review hooks，只勾选 X Island 项，再点 Allow selected。
5. 我完成信任并发出只读任务后，检查 X Island 是否出现真实会话事件。

边界：
- 不要代替我点击 Allow selected，不要批量信任其他 hooks，不要修改 Codex 的 sandbox 或 approval 设置。
- 如果 hooks/list 仍显示 untrusted，只能报告状态，不能把它描述成已接入。
- 完成后报告：改动文件、备份路径、JSON 校验、Review hooks 中的状态，以及真实任务是否到达 X Island。
```

## Gemini CLI

适用：仅企业 Gemini Code Assist 或付费 API Key；个人版已于 2026-06-18 停止服务。

```text
你是我的 macOS 配置助手。请检查我是否仍在使用受支持的 Gemini CLI 场景，再决定是否配置 X Island。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- Gemini CLI 的目标配置是 $HOME/.gemini/settings.json，命令使用 --agent gemini_cli。
- 该入口只适用于企业 Gemini Code Assist 或付费 API Key；个人版已于 2026-06-18 停止服务。

执行：
1. 先确认我的 Gemini CLI 版本、认证方式和套餐；如果是个人版或无法确认，立即停止并说明应改用 Antigravity。
2. 备份 $HOME/.gemini/settings.json，读取现有 hooks。
3. 输出 diff，只合并 X Island 条目；保留其他 hooks、MCP、模型和认证配置。
4. 校验 JSON 后重启客户端，发一条只读任务，检查 X Island 是否收到事件。

边界：
- 不读取、复制或输出我的 API Key；不修改认证文件。
- 不把“配置已写入”当成“Gemini CLI 已加载”；如果客户端没有真实事件，报告待排查。
- 完成后报告：套餐判断、改动文件、备份路径、JSON 校验和真实事件结果。
```

## Antigravity

适用：App / CLI / IDE 共用 `~/.gemini/config/hooks.json` 的命名分组全局 hooks；只观察，不接管审批。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「Antigravity」接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- Antigravity App、CLI（agy）和 IDE 共用 $HOME/.gemini/config/hooks.json，文件按 hook 名称分组。
- 只合并 X Island 自己的命名分组，命令使用 --agent antigravity；不要改其他 hook 分组或 Gemini 的其他配置。

执行：
1. 备份 $HOME/.gemini/config/hooks.json，读取现有分组。
2. 输出 diff，只新增或替换 X Island 分组；保留所有第三方分组和注释。
3. 校验 JSON 后，分别确认我实际使用的形态（App、agy 或 IDE），并重启对应客户端。
4. 发一条只读任务，检查 X Island 是否出现会话。

边界：
- 该来源的前置工具事件只返回中性 allow，不接管岛上审批；不要添加 PermissionRequest 或伪造批准。
- 如果三种形态无法分别确认，按 App / CLI / IDE 列出各自待验证项，不要把其中一个的结果算给另外两个。
- 完成后报告：改动文件、备份路径、加载形态、真实事件结果和未覆盖的形态。
```

## Cursor

适用：Cursor 原生 hooks；`beforeShellExecution` 和 `beforeMCPExecution` 只消费 deny / ask，不伪造 allow。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「Cursor」接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- Cursor 的目标配置是 $HOME/.cursor/hooks.json，命令使用 --agent cursor。
- Cursor 的 shell / MCP 权限 hook 只消费 deny 和 ask；岛上只提供「拒绝」和「交回 Cursor 确认」，不能伪造批准。

执行：
1. 备份 $HOME/.cursor/hooks.json，读取现有 hooks。
2. 输出 diff，只合并 X Island 条目；保留其他 hooks、规则和配置。
3. 校验 JSON 后重启 Cursor，发一条只读任务，检查 X Island 是否出现会话。
4. 如果事件没有到达，检查 Cursor 版本、hooks 是否启用以及桥接路径，不要靠猜修改其他字段。

边界：
- 不要给 shell / MCP 权限增加 allow，不要修改 Cursor 原生审批设置，不要自动点确认。
- 不要声称文件读取、问答或计划审查已经接管，除非当前 Cursor 版本和合同已实际验证。
- 完成后报告：改动文件、备份路径、JSON 校验、X Island 会话状态和仍需在 Cursor 内确认的步骤。
```

## OpenCode

适用：OpenCode 专用本地插件；权限、单选、多选和自由文本通道按当前 SDK 合同工作。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「OpenCode」接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- OpenCode 的插件路径是 $HOME/.config/opencode/plugins/xisland.js；如果设置了 XDG_CONFIG_HOME，使用 $XDG_CONFIG_HOME/opencode/plugins/xisland.js。
- 插件只由 X Island 管理，不要改 OpenCode 的其他插件、模型或凭据。

执行：
1. 检查 OpenCode 版本和配置目录，备份已有插件文件（若存在）。
2. 生成或更新 X Island 插件文件；如果已有同名文件不是 X Island 生成的完整模板，保留并报告冲突，不要覆盖。
3. 让 OpenCode 重新加载插件或重启，发一条只读任务，检查 X Island 是否出现会话。
4. 如有权限或问答卡，确认它来自 OpenCode 原生请求，而不是插件伪造的状态。

边界：
- 不读取或写入 API Key；不修改其他插件的加载顺序。
- 不自动批准权限；交互决定仍在 OpenCode 内完成时，明确说明。
- 完成后报告：插件路径、是否覆盖、备份路径、重载方式、真实事件结果。
```

## Factory Droid

适用：原生 `hooks.json`，若不存在则回退 `settings.json`；只观察。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「Factory Droid」接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 优先使用 $HOME/.factory/hooks.json；如果该文件不存在且已有 $HOME/.factory/settings.json，可按 settings 回退结构合并。
- 命令使用 --agent droid；只观察，不接管审批。

执行：
1. 检查 Droid 版本、实际使用的配置文件和现有 hooks，备份目标文件。
2. 输出 diff，只合并 X Island 条目；保留其他 hooks 和设置。
3. 校验 JSON 后重启 Droid，发一条只读任务，检查 X Island 是否出现会话。

边界：
- 不要新建更高优先级的文件去遮蔽用户已有 hooks；两种结构无法判断时停止。
- 不伪造权限批准或问答结果；审批仍留在 Droid。
- 完成后报告：实际使用的配置路径、改动文件、备份路径、JSON 校验和真实事件结果。
```

## Qoder CN

适用：Qoder CN（原通义灵码）。不同版本和 IDE/CLI 入口的能力可能不同，先以 X Island 当前接入页显示的方式为准。

```text
你是我的 macOS 配置助手。请先检查本机 Qoder CN 的实际版本和接入能力，再为 X Island 配置可验证的部分。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- Qoder CN 原生 hooks 的可用性随版本和 IDE/CLI 入口变化；不要按旧文档强行写入未经确认的配置文件。
- 如果 X Island 当前接入页只显示进程观察，就只验证进程观察，不要伪造 hooks。

执行：
1. 检查 Qoder 版本、配置目录、官方 hooks 入口，以及 X Island 设置页对该来源的描述。
2. 如果确认支持原生 hooks，备份实际配置文件，输出 diff 后只合并 X Island 条目；命令使用 --agent qoder。
3. 如果不支持 hooks，停止配置，说明当前只能进程观察，并检查 X Island 是否能看到 Qoder 进程会话。
4. 发一条只读任务，记录真实到达 X Island 的事件或明确说明没有事件。

边界：
- 不根据“看起来像 Claude Code hooks”就套用 Claude 的配置格式。
- 不自动批准权限，不伪造问答或计划审查。
- 完成后报告：版本、实际接入方式、改动文件（如有）、备份路径和真实事件结果。
```

## VS Code Copilot

适用：VS Code Copilot Local hooks；Agent Host、Remote 和自定义数据目录不在同一入口。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「VS Code Copilot Local」接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- hooks 文件是 $HOME/.xisland/hooks/vscode-local.json，命令使用 --agent copilot --adapter vscode_local。
- VS Code 用户设置需要把该文件注册到 chat.hookFilesLocations；只改这个字段，保留 JSONC 注释和其他设置。
- 可能存在 Code、Code - Insiders 和命名 profile 的多份 settings.json；只处理实际存在的文件。

执行：
1. 枚举 VS Code 用户设置和 profile，备份相关文件与 hooks 文件。
2. 输出 diff：合并 hooks 文件，并在每个实际使用的 settings.json 中把 hooks 路径设为 true。
3. 校验 JSON/JSONC 后重载 VS Code 窗口，打开一个 Local 会话。
4. 发一条只读任务，检查 X Island 是否出现会话。

边界：
- 不把 Agent Host、Remote 或云端会话的结果算作 Local 接入。
- 不覆盖用户显式设为 false 的 chat.hookFilesLocations 条目；遇到这种配置停止并说明。
- 不自动批准权限；Local 审批仍留在 VS Code。
- 完成后报告：处理的 settings 文件、hooks 路径、备份路径、真实事件结果和未覆盖的 Host 形态。
```

## CodeBuddy Code

适用：CodeBuddy Code CLI 原生 `settings.json` hooks；WorkBuddy 是单独插件，不走此入口。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「CodeBuddy Code CLI」接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 目标配置是 $HOME/.codebuddy/settings.json，命令使用 --agent code_buddy。
- 只处理 CLI；不要修改 WorkBuddy 插件配置，也不要把两者事件混在一起。

执行：
1. 检查 CodeBuddy CLI 版本和配置路径，备份 settings.json。
2. 输出 diff，只合并 X Island hooks；保留其他 hooks、MCP、模型和权限设置。
3. 校验 JSON 后重启 CLI，发一条只读任务，检查 X Island 是否出现会话。

边界：
- 不自动批准权限，不伪造问答结果；审批仍留在 CodeBuddy。
- 不把 IDE 或 WorkBuddy 的事件当作 CLI 接入证据。
- 完成后报告：改动文件、备份路径、JSON 校验和真实事件结果。
```

## Qwen Code

适用：Qwen Code 原生 `settings.json` hooks；支持权限和计划审查合同，但仍以实际版本为准。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「Qwen Code」接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 目标配置是 $HOME/.qwen/settings.json，命令使用 --agent qwen。
- 只合并 X Island 条目；不要复制 Claude Code 的旧配置或改写 Qwen 的模型设置。

执行：
1. 检查 Qwen 版本、认证方式和现有 hooks，备份 settings.json。
2. 输出 diff，只合并 X Island hooks；保留其他 hooks、MCP、模型和权限设置。
3. 校验 JSON 后重启 Qwen，发一条只读任务，检查 X Island 是否出现会话。
4. 如出现 PermissionRequest 或计划审查卡，确认其合同与当前 Qwen 版本一致；不一致就保留卡片并报告。

边界：
- 不自动批准权限，不代替用户回答；不要伪造 updatedInput 或计划审查回传。
- 不读取或输出 API Key。
- 完成后报告：改动文件、备份路径、JSON 校验、真实事件结果和未验证的交互。
```

## Kimi Code CLI

适用：Kimi Code 的 Python / Node 两套运行时；配置路径和事件集不同，不能混用。

```text
你是我的 macOS 配置助手。请先确认本机 Kimi Code 的运行时，再为 X Island 配置观察 hooks。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 旧 Python 运行时使用 $HOME/.kimi/config.toml；Node 运行时使用 $HOME/.kimi-code/config.toml。
- 两套运行时的事件集和参数不同；不要在同一文件里混写两套 X Island 块。

执行：
1. 检查 kimi / kimi-code 的实际版本、启动方式和配置路径，判断运行时。
2. 备份对应 TOML，输出 diff，只在文件末尾追加 X Island 标记块；保留已有 hooks 和其他配置。
3. 校验 TOML 可解析，重启对应客户端，发一条只读任务，检查 X Island 是否出现会话。

边界：
- 不把 Python 配置复制到 Node 路径，反之亦然；版本无法判断时停止。
- 不接管审批或问答；Kimi 的交互仍在原客户端完成，观察失败不能阻塞任务。
- 完成后报告：运行时判断、配置路径、备份路径、TOML 校验和真实事件结果。
```

## Amp

适用：Amp 本地 Plugin API 插件；只观察，不接管工具许可。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「Amp」观察插件。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 插件路径是 $HOME/.config/amp/plugins/xisland.ts；如果设置了 XDG_CONFIG_HOME，使用 $XDG_CONFIG_HOME/amp/plugins/xisland.ts。
- 插件只观察，不订阅 tool.call 审批，不伪造允许决定。

执行：
1. 检查 Amp 版本和插件目录，备份已有同名文件。
2. 输出 diff 后写入 X Island 插件；已有同名文件不是 X Island 完整模板时保留并报告冲突。
3. 重启或重新加载 Amp，发一条只读任务，检查 X Island 是否出现会话。

边界：
- 不修改 Amp 的模型、凭据或其他插件；不添加权限决定逻辑。
- 不自动批准工具调用；审批仍留在 Amp。
- 完成后报告：插件路径、是否覆盖、备份路径、重载方式和真实事件结果。
```

## Pi

适用：Pi 原生 TypeScript extension；只观察。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「Pi」观察扩展。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 扩展路径是 $HOME/.pi/agent/extensions/xisland.ts。
- 扩展只观察，不接管权限或问答。

执行：
1. 检查 Pi 版本和扩展目录，备份已有同名文件。
2. 输出 diff 后写入 X Island 扩展；已有同名文件不是 X Island 完整模板时保留并报告冲突。
3. 重启 Pi，发一条只读任务，检查 X Island 是否出现会话。

边界：
- 不修改其他扩展、模型或凭据；不添加权限决定逻辑。
- 不把 agent_end 当成最终完成，沿用 Pi 的原生状态语义。
- 完成后报告：扩展路径、是否覆盖、备份路径、重载方式和真实事件结果。
```

## Devin Desktop / Devin CLI

适用：Devin 原生 hooks（沿用原 Windsurf 应用身份）；Windsurf 已停用，不再新建配置。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「Devin Desktop / Devin CLI」接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- Devin CLI 的目标配置是 $HOME/.config/devin/config.json，命令使用 --agent devin。
- 只合并 X Island 自己的 hooks；不要修改 Devin 的模型、凭据或其他设置。

执行：
1. 检查 Devin 形态和版本，备份目标配置。
2. 输出 diff，只合并 X Island hooks；保留第三方 hooks 和所有其他字段。
3. 校验 JSON 后重启对应客户端，发一条只读任务，检查 X Island 是否出现会话。

边界：
- 不把桌面端、CLI 和云端会话的结果互相代替；分别记录验证形态。
- 不伪造权限批准；未核实的能力只报告为观察。
- 完成后报告：验证形态、改动文件、备份路径、JSON 校验和真实事件结果。
```

## Tabnine

适用：仅旧版 Tabnine CLI 的 `settings.json`；6.x 是 OpenCode 分支，不走这条旧配置。

```text
你是我的 macOS 配置助手。请先确认 Tabnine CLI 的实际版本，再决定是否使用旧版接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 旧版 Tabnine CLI 的目标配置是 $HOME/.tabnine/agent/settings.json，命令使用 --agent tabnine。
- 6.x CLI 已改为 OpenCode 托管分支，不应继续写旧版 settings.json。

执行：
1. 检查 Tabnine 版本；如果是 6.x 或无法确认，停止并说明应改用 OpenCode 插件路线。
2. 如果是已核实的旧版，备份 settings.json，输出 diff，只合并 X Island hooks。
3. 校验 JSON 后重启 CLI，发一条只读任务，检查 X Island 是否出现会话。

边界：
- 不修改 Tabnine 的账号、模型或凭据；不把 6.x 的配置写成旧版格式。
- 不自动批准权限。
- 完成后报告：版本判断、改动文件、备份路径、JSON 校验和真实事件结果。
```

## Cline

适用：Cline VS Code 扩展的 `~/Documents/Cline/Hooks` 事件脚本；独立 CLI / SDK 另验。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「Cline VS Code 扩展」接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- Cline 的事件脚本目录是 $HOME/Documents/Cline/Hooks；每个事件一个脚本，命令使用 --agent cline。
- 只处理 Cline 扩展；VS Code Copilot Local、Roo/PearAI 和独立 CLI 不走同一目录。

执行：
1. 检查 Cline 版本、hooks 目录和已有脚本，备份目录内将被修改的文件。
2. 输出 diff 后安装或更新 Cline 事件脚本；已有同名文件不是 X Island 生成的内容时保留并报告冲突。
3. 重载 VS Code 窗口，在 Cline 中发一条只读任务，检查 X Island 是否出现会话。

边界：
- 不覆盖用户自定义脚本；不自动启用扩展或信任。
- 不自动批准权限；审批仍留在 Cline。
- 完成后报告：hooks 目录、改动文件、备份路径、重载方式和真实事件结果。
```

## GitHub Copilot CLI

适用：GitHub Copilot CLI 原生 JSON hooks；与 VS Code Copilot Local 是两套协议。

```text
你是我的 macOS 配置助手。请在本机为 X Island 配置「GitHub Copilot CLI」接入。

已知：
- X Island 已安装，桥接是 $HOME/.xisland/bin/di-bridge。
- 目标配置文件是 $HOME/.copilot/hooks/xisland.json；如果设置了 COPILOT_HOME，使用 $COPILOT_HOME/hooks/xisland.json。
- 命令使用 --agent copilot_cli；不要与 VS Code 的 vscode_local hooks 混在一起。

执行：
1. 检查 Copilot CLI 版本和配置路径，备份目标文件。
2. 输出 diff 后合并 X Island hooks；保留其他 hooks 和设置。
3. 校验 JSON 后重启 CLI，发一条只读任务，检查 X Island 是否出现会话。

边界：
- 不把 VS Code Copilot 的事件算作 CLI 接入；不伪造审批输入。
- 不自动批准权限；审批仍留在 Copilot CLI。
- 完成后报告：配置路径、改动文件、备份路径、JSON 校验和真实事件结果。
```

## 停用或已合并的来源

Hermes、Windsurf、Continue、Roo Code、Amazon Q CLI 不再提供新的接入配置。不要为它们新建 hooks；按下列规则改用继任入口，旧会话仍可在 X Island 历史中查看。

```text
你是我的 macOS 配置助手。我正在检查一个已停用或已合并的 X Island 来源，请不要为它新建 hooks 或插件。

规则：
- Hermes 不在当前支持的接入目录：不要为它新建 hooks 或 wrapper。
- Windsurf 已于 2026-06-02 更名为 Devin Desktop：改用 Devin 接入。
- Continue 已于 2026-06 被 Cursor 收购：改用 Cursor 接入。
- Roo Code 已于 2026-05-15 停运：改用 Cline 或 Kilo Code。
- Amazon Q CLI 已于 2025-11-17 更名为 Kiro CLI：改用 Kiro 接入。

请检查现有配置中是否还有指向这些旧来源的 X Island 条目；如有，先备份，再只移除可证明属于 X Island 的旧条目，不要删除第三方 hooks 或用户配置。完成后报告改动文件和仍需迁移的旧会话。
```

## 相关页面

- [接入总览与矩阵](README.md)
- [Trae hooks 配置指南](../integrations/trae-hooks.md)
- [Kilo Code 接入](kilo-setup.md)
- [Aider 与 Codewhale](aider-codewhale-usage.md)
- [Kiro CLI V3](kiro-setup.md)
- [WorkBuddy 观察插件](workbuddy-setup.md)
- [豆包工作连接器](doubao-work-setup.md)
- [Zed / JetBrains 外部 ACP Agent](acp-setup.md)
- [Cody Agent](cody-setup.md)
- [GLM 多客户端](glm-setup.md)
- [Approval graph MCP](approval-graph-mcp.md)
- [VS Code 伴生扩展](../../Sources/XIslandVSCode/README.md)
