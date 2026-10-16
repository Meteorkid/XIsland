# AI 工具接入与兼容性

本页说明 X Island 的 30 项原定接入目标与额外的 WorkBuddy，共 31 项。不同客户端的接口能力不同：有的可以回传审批或答案，有的只能显示状态。CLI、IDE、桌面端和同品牌插件分别核实，不能互相代替。

更新日期：2026-10-15。当前 31 项均有通过项目契约测试的基础路线（GLM 按实际客户端接入）；所有目标的完整验收均未完成。发行构建的具体测试结果以[公开验证摘要](release-verification-2.0.0.json)为准；机器可读状态见[适配矩阵](agent-matrix.json)。

## 如何接入

1. 安装 X Island，在集成设置中找到实际使用的客户端。
2. 原生 hooks 或插件来源按对应设置项配置；需要外部包装器的来源使用下方指南。
3. 配置生成、文件存在或接收开关开启，只能说明入口已准备；还需在原客户端完成必要的插件启用或信任，并运行实际任务确认事件进入 X Island。
4. 没有可靠应答接口的来源只观察状态，审批、问答和取消继续在原客户端完成。

已有配置、其他插件、凭据和信任设置不会被通用模板强制替换；无法确认版本或配置归属时应保留原文件并按指南检查。

## 接入路线

“基础已实现”表示存在通过项目契约测试的指定通道，仍有下表限制；“待补齐”表示尚未具备可按当前范围交付的完整基础路线。

| 客户端 | 接入方式 | 基础状态 | 已知范围与限制 |
| --- | --- | --- | --- |
| Claude Code | 原生 settings hooks | 基础已实现 | 2.1.234 的隔离真实读取、岛上拒绝写入已通过；完整审批、并发权限、子代理、TUI 和真实服务商待验 |
| Codex CLI / 桌面核心 | 原生 hooks.json | 基础已实现 | 12 类事件的项目契约已测；原生加载、工具和审批需在信任最终 hooks 后验证 |
| Gemini CLI | 原生 settings hooks | 基础已实现 | 已核对事件通道；通知本身不能作为原生批准依据，真实客户端仍待验 |
| Cursor | 原生 hooks | 基础已实现 | 9 类事件契约已测；具体版本、问答、完整审批与多 hooks 组合待验 |
| Trae / Trae CN / Solo | Trae CN 独立 hooks | 基础已实现 | 当前固定范围是 CN 协议；国际版和 Solo 不借用 CN 的验收结果 |
| OpenCode | 专用插件 / 实例 SDK | 基础已实现 | 审批及单选、多选、自由文本通道已实现；实际宿主 SDK 和完整计划交互待验 |
| Factory Droid | 原生 hooks.json / settings | 基础已实现 | 已核对观察事件；没有已核实的 PermissionRequest，前置通知不提供伪造审批 |
| Qoder CLI / IDE | 原生 settings hooks | 基础已实现 | 原生会话和子任务身份已处理；IDE、完整问答及真实版本待验 |
| VS Code Copilot | Local hooks | 基础已实现 | Local 8 类事件已接入；Agent Host、Remote、自定义数据目录及完整交互另验 |
| CodeBuddy Code | CLI 原生 settings hooks | 基础已实现 | CLI 10 类观察事件已测；完整权限协议、IDE 和 WorkBuddy 分别验证 |
| Qwen Code | 原生 settings hooks | 基础已实现 | 已核对权限协议与身份关联；完整问答和实际客户端待验 |
| Kimi Code CLI | Python / Node 独立 hooks | 基础已实现 | Node 2.1.1 的部分原生 ACP / Web API 场景通过；完整控制、回复、任务树和旧 Python 版本待验 |
| DeepSeek-TUI / Codewhale | 固定版本原生 hooks | 基础已实现 | 仅第三方 Codewhale 0.10.0 已核对的 14 类观察事件；旧版、实际客户端与交互待验 |
| Kiro CLI / IDE | 2.31.0 V3 独立配置显式导出 | 基础已实现 | 六类观察事件及配置合并/移除已测；真实CLI加载、审批、IDE和其他版本待验 |
| Amp | 专用 Plugin API | 基础已实现 | 4 类观察事件及模拟宿主通过；工具开始、审批和真实宿主待补验 |
| Pi | TypeScript extensions | 基础已实现 | 8 类观察事件及模拟宿主通过；实际宿主、版本和交互待验 |
| GLM 使用场景 | Claude Code / OpenCode / Cline / Pi 的模型元数据 | 基础已实现 | 保留客户端身份，显示、筛选和保存GLM模型；缺失字段不猜测，真实服务商与完整交互待验 |
| Aider | 显式进程包装器 + 通知 | 基础已实现 | 仅进程与通知观察；工具、轮次、原生交互和固定 0.86.2 实机待验 |
| Windsurf / Cascade | 原生 snake_case hooks | 基础已实现 | 按 trajectory_id 关联；前置 hook 阻断不等于原生批准 |
| Devin CLI | 原生 hooks | 基础已实现 | 本地协议已接入；云端会话、完整问答和真实版本另验 |
| Amazon Q CLI / IDE | qchat 1.19.7 包装器 | 基础已实现 | 仅选定旧 CLI 的进程观察；没有稳定调用 ID / 回复正文，不覆盖 IDE 或 Kiro |
| Tabnine CLI / IDE / 插件 | CLI JSON hooks | 基础已实现 | CLI 8 类观察事件已接入；IDE 与后继宿主插件另验 |
| Cody IDE / Agent | 显式 jsonrpc-stdio 包装器 | 基础已实现 | 仅可显式选择启动命令的 Agent 通道；普通 IDE 会话、工具、审批和用量待验 |
| Cline VS Code / SDK CLI | VS Code 事件脚本 | 基础已实现 | 扩展 6 类事件已接入；启用与信任、实际版本、独立 CLI / SDK 及完整交互待验 |
| Continue IDE / cn CLI | cn serve /state 限时观察 | 基础已实现 | 仅服务快照；轮询可能漏过短暂状态，普通 TUI / IDE 不在此通道范围 |
| GitHub Copilot CLI | 原生 JSON hooks | 基础已实现 | 12 类观察事件已接入；审批输入、并发 ID 和实际版本待验 |
| Roo Code | 任务事件观察扩展 | 基础已实现 | 固定 3.54.0 API；无安全审批应答，普通标签页、晚接入及多窗口来源待验 |
| PearAI | Roo fork 实验观察扩展 | 基础已实现 | 默认关闭；固定 fork 3.15.3，实际发行产物与宿主待验，不覆盖 Continue fork |
| Zed | 显式外部 ACP Agent 包装器 | 基础已实现 | 仅包装的外部 Agent，权限留在编辑器；内置 AI 和实际客户端待验 |
| JetBrains AI / Junie | 显式外部 ACP Agent 包装器 | 基础已实现 | 仅包装的外部 Agent，不代表内置 AI Assistant 或所有 Junie 路径已适配 |
| WorkBuddy（额外客户端） | 手动导出观察插件 | 基础已实现 | 5.7.6 / 5.7.7 固定资源已静态核对；真实插件加载、任务触发与完整交互待验 |

## 安装与使用指南

- [Aider 与 Codewhale](aider-codewhale-usage.md)
- [Zed / JetBrains 外部 ACP Agent](acp-setup.md)
- [Amazon Q 旧 CLI](amazonq-setup.md)
- [Cody Agent](cody-setup.md)
- [Continue 服务状态观察](continue-setup.md)
- [WorkBuddy 观察插件](workbuddy-setup.md)
- [Kiro CLI V3](kiro-setup.md)
- [GLM 多客户端](glm-setup.md)
- [Roo Code / PearAI 扩展](../../Sources/XIslandVSCode/README.md)

## 怎样理解验证结果

| 层级 | 能证明什么 | 不能单独证明什么 |
| --- | --- | --- |
| 协议与版本核查 | 对应版本存在这些字段、事件或配置入口 | 实际客户端已加载配置 |
| 契约与编译桥接测试 | 合成输入经真实桥接进程正确转换和返回 | 厂商客户端实际发出相同事件 |
| 隔离应用验证 | 消息进入实际 X Island，界面状态和历史记录按预期变化 | 真实服务商、客户端所有界面或完整业务流程 |
| 隔离真实客户端验证 | 固定客户端在指定场景实际执行了工具或事件 | 未覆盖分支、其他版本、真实服务商或全产品验收 |
| 完整验收 | 约定版本、形态及功能范围全部经过目标客户端验证 | 当前没有任何一项达到此层级 |

Claude 与 Kimi 已有部分隔离真实客户端证据，均使用本地模拟模型；具体构建、场景与限制记录在[公开摘要](release-verification-2.0.0.json)。历史构建的通过结果不会自动转算为 v2.0.0 安装包的测试结果。

需要继续验证的权限、恢复、任务归属、版本和运行环境见[验收缺口](acceptance-gaps.md)。所有 31 项 `complete` 仍为 `false`，基础接入完成率与完整验收完成率分别统计。
