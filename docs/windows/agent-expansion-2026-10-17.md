# Windows Agent 接入扩展与引导

用户已授权按“更多 Agent、自动接入、真实交互”优先推进，沿用现有 Tauri/Rust/TypeScript 架构。保留已有双岛联动等未提交工作；开始时的差异与文件列表另存 `.build/agent-parity-before-2026-10-17.*`。

## 本批目标

1. 新增 OpenCode、Qwen Code、CodeBuddy Code CLI、Factory Droid、Node 版 Kimi Code。按各自协议处理，不把同名字段或通用展示当作适配。
2. OpenCode 使用官方 SDK 的实例内 transport 回传权限、单选/多选、多题结果；Qwen 实现已有明确合同的 PermissionRequest。其他新增客户端按已证接口先观察；不强行把 PreToolUse 变成人工审批。
3. Kimi 接入原生后台任务账本、乱序结果、未知父关系、孤立状态持久化及重启恢复；权限观察不生成本地可执行批准按钮。
4. 设置页自动发现固定客户端入口，区分“发现程序”“配置写入”“收到事件”。Codex 只读查询 hook 信任；不自动授权、跳过原客户端确认或执行真实用户任务。
5. OpenCode JS、Kimi TOML 与现有 JSON 配置分别安全安装。只修改自有项，先审阅、校验版本并备份；外部编辑/路径不明确时拒绝覆盖。

## 实现选择

- 采用每客户端适配器 + 共享会话核心。直接转发 Claude 协议虽然少代码，但会混淆子任务、工具ID和停止语义，不适用。
- OpenCode 直接安装本地自动加载插件文件，无需改整个 opencode.json；Kimi 使用精确可认领的 TOML 末尾块，保留其余字节与注释。单纯导出配置片段难以完成本批自动接入目标。
- 沿用已有本地 bridge，而不另开公开 HTTP 监听；原生 SDK 的问题/权限请求在插件内保持原实例、目录和请求ID。
- 客户端配置、活动回执和信任分别建模。回执只记录元数据并绑定配置/资源指纹；配置或运行时变化、Codex信任撤销后不能继续显示旧连接证据。

## 验证门槛

- 适配器契约：字段和身份、同会话多个请求、子代理、非最终停止、未知结果、失效回退。
- 安装器：重复安装、用户自有条目、配置冲突、精确卸载、权限/链接/目录替换、备份和原子写入。
- 接入状态：真实子进程 JSON-RPC 握手、超时、UTF-8分片、错误正文隔离、Kimi Node/Python区分、活动指纹失效。
- 集成：打包后的hook子进程经隔离桥接产生正确DIMessage及原生回包；OpenCode实际SDK路由和多题不提交部分答案。
- 界面：新入口可审阅安装、信任状态可见、Kimi失败/未确认不显示成功、已有双岛联动不回退。
- 本机测试、Windows目标构建、Windows真实客户端三层分别记录；本批不将前两项称为第三项完成。

后续按能力逐批迁移其余路线；随后对齐统计、历史、声音、启动/更新及视觉设置。整体 Windows 功能对齐目标仍未完成。

## 已完成与验证结果

- 注册表从 7 扩至 12 个适配器；11 个可审阅配置入口，另有 WorkBuddy 导出。TRAE CN / TraeWork CN 仍共用一个配置入口。
- Qwen 权限和 OpenCode 原生权限/多题回传已实现。CodeBuddy、Droid、Kimi Node 按观察合同接入，不能描述为全面交互审批。
- Kimi 20 类事件接入生产 SessionStore；后台进程与子代理分别呈现。实际浏览器回归发现的“进程任务留在账本却不可见”已修复；失败显示红叉，失联/未确认显示问号。
- OpenCode 删除/归档改为观察结束，保留既有错误，不假造完成；关闭状态持久化防止重启后被迟到观察事件复活，新提示词可重新开始。
- 302 项 TypeScript、26 项浏览器、32 项 Rust 单元及 1 项真实子进程 IPC 通过。浏览器图为合成夹具截图；Rust 主机测试不是 Windows Named Pipe 验收。
- 官方 OpenCode 1.19.3 macOS arm64 二进制执行三场景：允许读取后真实工具返回随机夹具；拒绝后原生工具报拒绝且本回合停止；三题包含单选、多选、中文自定义文本，原生 SSE 收到完整二维 answers。42 条真实 hook 回执、5 次本地交互响应、6 条原端事件（3 个请求、3 个回复）；四份相关源文件哈希与当前工作树一致。
- 上述 OpenCode 使用隔离目录、本地固定模型、生成插件、实际 hook 子进程、注入 SDK 和生产 SessionStore；Rust bridge、桌面 UI 和 Windows 均未执行，真实外部模型未使用。报告见 `evidence/opencode-native-macos-2026-10-17.json`；SDK v1/v2 独立路由核对见 `evidence/opencode-sdk-1.19.3-2026-10-17.json`。

## 协议依据

- [Qwen 官方 hooks](https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/)：独立 PermissionRequest 与子代理身份，不把所有事件当成 Claude 回包。
- [CodeBuddy Code CLI 官方 hooks](https://www.codebuddy.ai/docs/cli/hooks)：Windows Git Bash 宿主，编码 PowerShell 启动器只作为其中执行的程序。
- [Factory Droid 官方 hooks](https://docs.factory.com/harness/hooks)：既有独立 hooks 文件与 settings 格式不同，选择变化纳入配置冲突检测。
- [OpenCode 官方 plugins](https://opencode.ai/docs/plugins/) 及 npm `@opencode-ai/sdk` 1.19.3：实例注入 transport、原始请求 ID、200/true 的明确确认。
- Kimi Node `@moonshot-ai/kimi-code` 2.1.1，固定源码提交 `f67e6398fb3210ad8ace970e2dfd5bcc984ed61f`；合成合同固定在 `windows/src/fixtures/companion/kimi-code-hooks.json`，不使用 Python CLI 的配置格式。

所有测试继续保持用户真实配置、信任和凭据不变。Windows 原生客户端加载、安装/升级/卸载、多屏/DPI/IME和配对 Mac 视觉验收仍待另一台电脑的实证。

## 独立复核修正

只读复核实际复现：Kimi/OpenCode 默认和自定义目录内容相同时，原活动身份未包含配置路径，可能将默认目录事件显示在另一个目录下。修复将 `realpath` 后的配置文件路径加入活动资源指纹；安装器的计划/revision 格式保持原样。新增两客户端双目录回归，保证相同内容不等于同一个接入。审查前未交付产物另存 `.build/agent-expansion-before-review-0.1.6/`，最终测试包重新构建。
