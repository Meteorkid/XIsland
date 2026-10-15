# Windows Agent 浮岛开源实现对照

核查日期：2026-10-15。读取公开仓库的固定提交，没有运行这些项目或复制第三方源码。项目自己的支持声明、源码中的入口和真实客户端验证是不同证据层。

## 实际适配范围

| 项目和固定提交 | 源码范围 | 与 XIsland 六个原接入的关系 |
| --- | --- | --- |
| [Nook](https://github.com/zubairbinshaukat/nook/tree/0ddaf035030428ceddcf3c5cd6ec9e999d39cdad) | Windows 有 Claude Code、Codex、Cursor 三条路径；Cursor 为状态观察 | 覆盖前三者；未找到 Gemini、Windsurf、Trae、TraeWork、WorkBuddy 专门适配 |
| [Vibe-Halo](https://github.com/DaliBerr/Vibe-Halo/tree/5ea820c861056616a6dc1c02ef5e72d4e7eea559) | 注册 19 个客户端，能力分层；文档只将 Codex、ZCode 列为维护者完成完整真实回传验证的客户端 | 包含 Claude、Codex、Cursor Agent、Gemini CLI；未注册 Windsurf、Trae、TraeWork、WorkBuddy。CodeBuddy 不能当作 WorkBuddy |
| [vibe-island](https://github.com/NetVar1337/vibe-island/tree/4c6897766828ef903f9dae886c8b2b1e912820eb) | 16 个安装分支，含 hooks、插件、配置写入等不同接入形态 | 包含 Claude、Codex、Cursor、Gemini、Windsurf 的代码路径；未找到 Trae、TraeWork、WorkBuddy。安装函数存在不证明客户端会消费它 |
| [windows-dynamic-island](https://github.com/HeyyCzer/windows-dynamic-island/tree/4d16ed6687ca6e80e41bdbc61816d29edbea3def) | Claude hooks/审批；Codex 读取本地 rollout 做状态和用量观察 | 两款；Codex 模块明确没有审批提示数据，因此不能视为审批接管 |
| [WinIsland](https://github.com/zHeuzy2/WinIsland/tree/4e0bb5e710481b94bd8469d04dd27427abd26905) | 媒体、计时、相机、通知与原生窗口 | 本次未找到这些编程 Agent 的专门适配器，适合借鉴窗口层 |

Vibe-Halo 的 19 个注册项为 Codex、ZCode、Qwen Code、Copilot CLI、Claude Code、CodeBuddy、Hermes、OpenCode、Kimi Code、Qoder、QoderWork、Gemini CLI、Antigravity、Cursor Agent、Kiro、CodeWhale、Pi、OpenClaw、Reasonix。不能把这份注册名单称为 19 个全部实机验收通过。

vibe-island 的 16 个安装分支为 Claude、Codex、Gemini、Cursor、OpenCode、Amp、Kimi、Kiro、Droid、Hermes、Cline、Pi CLI、Copilot、Windsurf、CodeBuddy、Qoder。其 Windsurf 安装器写入 `.windsurf/settings.json` 的 `vibe_island_hook` 自定义字段，并复用 Claude 脚本；本项目不能据此替换已核对的 Cascade 原生 hooks 配置。其 README 的“Full”不作为本项目的兼容性证据。

## 可借鉴机制及落点

| 来源 | 具体机制 | XIsland 的处理 |
| --- | --- | --- |
| Nook | 观察与等待人工决定分开处理；仅更新自己的配置条目 | 已有配置归属/备份/冲突检查；本轮 WorkBuddy 使用短观察超时和中性空输出，不阻断原生任务 |
| Vibe-Halo | 明确区分可审批、可回答、仅提醒；后端再次核对当前请求和截止时间 | 已有请求绑定/截止时间/响应确认；本轮插件卡片明确“观察模式”和“导出未安装”，不提供无协议依据的审批按钮 |
| vibe-island | 平台传输与共享会话逻辑分层，插件也是一级接入形态 | 沿用现有 Rust 传输与 TS 会话核心；将“可接收事件”的名单与“可直接修改配置”的名单分开，增加 WorkBuddy 插件导出 |
| windows-dynamic-island | 窗口命中、不抢焦点、全屏识别各有原生边界；Codex 只读数据源不伪装审批能力 | 窗口细节进入实机对照清单；本轮不增加私有配额访问或读取用户凭据 |
| WinIsland | 低级鼠标钩子与渲染线程分离；弹簧动画独立计算 | 作为后续透明命中/性能优化参考，当前没有为学习而改动已工作的窗口架构 |

没有采用同名工具共用任意协议、超时自动批准、写入未知客户端字段等做法。GPL/AGPL 项目只研究设计；没有将其源码复制进 XIsland。Nook 和 WinIsland 的 MIT 代码也没有直接引入。

## TraeWork CN / WorkBuddy 本轮设计

- TraeWork CN：本机公开应用包目录仍为 `TRAE SOLO CN.app`，0.2.2 的 `nameAlias` 与 `win32NameVersion` 明确为 `TraeWork CN`，数据目录为 `.trae-cn`。其公开 UI 资源包含同一全局/项目 hooks 路径，原生库含六事件与相应字段标记。结合官方国内版 hook 参考，扩展共享观察入口。保留单一 `trae_cn` 配置 profile 和 `trae` 会话来源；载荷没有已核实的产品身份，不能伪称区分 IDE/Work。`work-cn` 合同选择只允许观察，不启用前置决策。此证据不是 Windows 客户端运行证明。
- WorkBuddy：重验 5.7.7 的两份公开内置运行时，摘要与已审查的 5.7.6/5.7.7 合同一致。建立独立 `workbuddy` 适配器，11 个观察事件；PreToolUse 只表示准备、Stop 不终结、FinalStop 按已知原因更新、子代理结束不关闭父任务。通过 Windows 设置导出本地市场和插件，仅向新目录写入，不修改其配置或信任。
- 另一条可能路线是直接写 WorkBuddy 配置，但该桌面端的已核对入口是插件市场，故不套用 CodeBuddy CLI 设置路径。另一条路线是为 TraeWork 再写一套全局 hooks，但两款应用共享文件，会造成重复事件，故保留一个入口。
- 验收：纯适配/生命周期、导出不覆盖、真实 Node 子进程、原生导出摘要、界面“未安装”状态分别测试；最终加载和任务回传需要另一台 Windows 的真实客户端。云端任务未接入。

静态证据见 [公开资源摘要](evidence/traework-workbuddy-static-2026-10-15.json)。本轮不修改 macOS 源码或用户真实 Agent 配置，不安装第三方客户端，不自动提交或发布。

## 关键源码与官方资料

- [Nook Windows relay](https://github.com/zubairbinshaukat/nook/blob/0ddaf035030428ceddcf3c5cd6ec9e999d39cdad/windows/hook/src/main.rs)、[Cursor 状态边界](https://github.com/zubairbinshaukat/nook/blob/0ddaf035030428ceddcf3c5cd6ec9e999d39cdad/windows/src-tauri/src/cursor_hooks.rs)
- [Vibe-Halo 注册表](https://github.com/DaliBerr/Vibe-Halo/blob/5ea820c861056616a6dc1c02ef5e72d4e7eea559/src/agent-registry.js)、[支持与验证矩阵](https://github.com/DaliBerr/Vibe-Halo/blob/5ea820c861056616a6dc1c02ef5e72d4e7eea559/docs/GUIDE.md#client-support)、[决定校验](https://github.com/DaliBerr/Vibe-Halo/blob/5ea820c861056616a6dc1c02ef5e72d4e7eea559/src/decision-service.js)
- [vibe-island 安装器与脚本](https://github.com/NetVar1337/vibe-island/blob/4c6897766828ef903f9dae886c8b2b1e912820eb/src-tauri/src/hooks/mod.rs)
- [windows-dynamic-island 窗口层](https://github.com/HeyyCzer/windows-dynamic-island/blob/4d16ed6687ca6e80e41bdbc61816d29edbea3def/src-tauri/src/window.rs)、[Codex 数据范围](https://github.com/HeyyCzer/windows-dynamic-island/blob/4d16ed6687ca6e80e41bdbc61816d29edbea3def/src-tauri/src/providers/codex/mod.rs)
- [WinIsland 原生窗口](https://github.com/zHeuzy2/WinIsland/blob/4e0bb5e710481b94bd8469d04dd27427abd26905/WinIsland/Program.cs)
- [WorkBuddy 官方插件](https://www.codebuddy.cn/docs/workbuddy/Plugins)、[TRAE 国内版 hooks](https://docs.trae.cn/ide_hook-configuration-reference)、[TraeWork 融合升级说明](https://docs.trae.cn/work_traework-to-traecode-data-migration?lang=zh)
