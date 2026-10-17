# Windows XIsland 执行状态

## 2026-10-17 补充：0.1.8 Copilot CLI、Pi 与模型筛选

0.1.7既有工作已按用户授权提交为 `3bef203`。本轮新增 Copilot CLI 12事件观察和Pi 8事件原生扩展，连同发现/自动配置/有效活动回执；共15适配器、13自动配置入口，WorkBuddy/Kiro仍是独立文件准备。

GLM跨客户端筛选和模型搜索已实现，保留原客户端身份；修复过滤后父子会话漏显及空结果高度。自定义安装位置仅凭本次真实接受活动可补充发现证据，授权与运行时门槛保持。Copilot/Pi/OpenCode/Kimi的安装计划均绑定配置路径和运行时，跨目录旧确认被拒绝。

455项逻辑、36项浏览器、34项Rust单元和1项IPC通过。安装器实际hook在官方Pi双会话17事件和OpenCode三场景中复验通过（macOS、本地模拟模型、Node桥；Windows实机仍待验）。完整测试包 `.build/XIsland-Windows-0.1.8-preview-test-kit.zip`，SHA-256 `7ef5d69302ac3229477e37c3ac023022b5282e99a9a2587e97d9e20d7be4bd40`。未签名，未推送/发布，旧包保留。

详见 [本批范围与证据](copilot-pi-glm-2026-10-17.md)。

## 2026-10-17 补充：0.1.7 跟进 macOS 2.0.1

已跟进统一软件接入/授权、单一主窗口启动及周期准备、持久提醒、关闭/审批期间提醒策略、Codex 授权撤销与活动版本绑定。活动只在状态机接纳后确认；不再把桥接 ACK 当成接通证据。

新增 Kiro CLI 2.31.0 V3 六事件观察与文件准备，WorkBuddy/Kiro 均可复用未改产物并打开目录。共 13 适配器、11 个自动配置来源、2 个独立准备入口。统计跨观察实例去重，历史按结束时间排序，模型显示与最终回复完成音也已对齐。Kiro Windows 宿主加载与全部原生客户端仍待实机。

383 项 TypeScript、32 项浏览器、34 项 Rust 单元及 1 项独立进程 IPC 通过；Windows x64 安装器独立解包、源输入一致性和ZIP校验通过。安装器内实际 hook 在官方 OpenCode macOS 三场景再次通过（本地固定模型、Node TCP替身，无Windows/UI/Rust本体验收）。

完整测试包：`.build/XIsland-Windows-0.1.7-preview-test-kit.zip`，SHA-256 `31c15590e182fba0766112d3b857157bfcc1bb02be1bf27bf37a9e3826d92588`。未签名、未提交或发布；0.1.6 及其证据保留。详见 [Mac 更新对齐记录](macos-2.0.1-sync-2026-10-17.md)。

## 2026-10-17 补充：0.1.6 Agent 扩展预览

本批新增 Qwen Code、CodeBuddy Code CLI、Factory Droid、OpenCode、Kimi Code Node：共 12 个适配器、11 个配置入口，另有 WorkBuddy 插件导出。新增客户端发现、Codex 只读 hook 信任查询、绑定当前配置和资源的事件回执。Kimi 原生任务账本已接入生产会话与历史；失败/未确认分别呈现，不制造成功。保留已有 XNook 双岛联动。

Qwen 实现权限回传，OpenCode 实现权限和完整多题/多选回传；其余三个新增客户端为观察能力。OpenCode 官方 1.19.3 macOS arm64 客户端的允许读取、拒绝读取、三题回传均已实际执行通过，使用本地固定模型和临时 Node TCP 桥；不是 Windows/Rust/桌面交互验收。

本机 302 项 TypeScript、26 项浏览器、32 项 Rust 单元及 1 项独立进程 IPC 通过。Windows x64 MSVC release 和 NSIS 构建通过，独立解包核对 9 个文件；安装器 SHA-256：`d376e91647fe35fa9b5e2630d58c22e60087131db50e38cd94a3f350e6b84238`。完整测试包为 `.build/XIsland-Windows-0.1.6-preview-test-kit.zip`，仍未签名、未发布、未取得 Windows 实机反馈。

详细实现、协议依据和验证边界见 [本批记录](agent-expansion-2026-10-17.md) 与 [官方 OpenCode 复跑说明](evidence/opencode-native-macos-2026-10-17.md)。整体目标未完成；Windows 客户端加载/响应、多屏/IME/安装以及其余 Mac 功能仍需继续补齐。

## 2026-10-17 补充：0.1.4 双应用联动预览

已新增与 XNook Windows 0.1.0 的双向切换：当前用户目录协调、原生显示确认、实例租约、超时回滚、按钮/横向手势、托盘/单实例/全屏恢复门禁。两个新客户端需各启动一次登记路径，旧 0.1.3 不支持。协议见 `island-link-v1.md`。

0.1.4 x64 NSIS 安装器已生成并独立解包，构建输入与当前源码一致；安装器 SHA-256 为 `ca70227e3e32a5251e9da3f055d48274e439bb6f903f081c5d931bf55ce3c7a9`。配套完整测试包位于 XNook 仓库 `.build/XNook-XIsland-Windows-2026-10-17-preview-test-kit.zip`，包含两端安装器和验收说明。

本次 160 前端测试、22 Rust 单元及 1 集成测试通过，联动 12 组独立子进程故障回归通过；Windows 实机结果仍未取得。这次联动改动尚未提交或发布，不改变下面旧版本的历史记录和其待验项目。

---

更新：2026-10-15。完整目标尚未达成；Windows 基线已提交为 `660c91b`，未推送、未发布。Windows 实机反馈尚未收到。

## 历史完整测试包：0.1.3

- 完整压缩包：`.build/XIsland-Windows-0.1.3-preview-test-kit.zip`，约 25.1 MiB。SHA-256：`b8c2b231c9685958106bee16d5ec89f8ed592b029c84b5ce4b505633f40a8f3b`。
- 已修复 Windows 样例依赖 Mac 未提交文件的问题，九份合成样例固定到本子项目；全新临时目录中的 Git 暂存树类型检查、158 测试及前端构建通过。

- TraeWork CN 0.2.2、WorkBuddy 5.7.7 均取得官方 Windows 安装器并只读解包；不再以 Mac 资源代替 Windows 包证据。
- TRAE 共享配置保持一份。原生 bridge 在 250 ms 总等待内尝试区分 IDE / Work，并使用不同会话来源；未知、超时和历史重放不强行归属。三个仅观察来源均不能升级为交互审批。
- WorkBuddy Windows 厂商校验器通过本次插件 0.1.1 与本地市场结构。修正宿主 3 秒超时余量不足的问题：宿主 10 秒，内部各阶段有限等待，观察输出全部丢弃；未采用会污染上下文的 async 握手。
- 当前通过 158 项 TypeScript、31 项 Rust 单元、1 项独立进程 IPC、3 项相关浏览器场景，Windows 目标检查通过。Windows 真实进程来源识别、插件启用、任务触发与冷启动测量仍待验收。
- 详细证据和可复现步骤见 [Windows 客户端适配复核](client-adaptation-2026-10-15.md)。0.1.3 已完成独立解包与 ZIP 校验；旧 0.1.2 保留。

## 历史完整测试包：0.1.2

- `.build/XIsland-Windows-0.1.2-preview-test-kit.zip`：新增 WorkBuddy 独立 11 事件观察器与设置页插件导出；通过原客户端插件管理完成安装和启用，导出不冒充安装。
- TRAE CN / TraeWork CN 使用一个共享配置入口，避免同一个 `.trae-cn/hooks.json` 重复注册。TraeWork CN 的 0.2.2 公开安装资源已静态核对；当前不区分 IDE/Work 事件来源，Windows 本地任务仍待实机验证，云端未接入。
- 注册表为 7 个事件适配器，普通配置入口仍为 6 个，另有 WorkBuddy 插件导出；不是 8 套独立配置，也不是 7 个客户端全部验收通过。
- 本轮通过 157 项 TypeScript 测试、26 项 Rust 单元测试、1 项独立子进程 IPC 测试，以及 5 项相关浏览器场景（WorkBuddy 场景最终复核后再通过）。Windows MSVC release 构建及独立 NSIS 解包通过。
- 独立解包核对 7 个载荷文件与 x64 PE；安装器和源码构建输入一致。安装器 SHA-256：`3020b1cec6b432a2a27a9f80382df300b0ad826511669c1855cad59caec91df5`。
- [开源适配对照与设计](open-source-review-2026-10-15.md)固定五个项目提交，区分注册数、配置入口、实际能力和实机验证；未复制第三方源码。
- [静态依据](evidence/traework-workbuddy-static-2026-10-15.json)、[安装器解包](evidence/installer-inspection-0.1.2.json)、[最终测试包与内含 hook 进程检查](evidence/test-kit-0.1.2.json)。Windows 本体、真实 Agent 与完整 Mac 对齐仍未验收。

## 历史完整测试包：0.1.1

- `.build/XIsland-Windows-0.1.1-preview-test-kit.zip`，约 25 MiB，包含安装器、自检脚本、验收说明、README、许可证与 manifest。
- 隔离携带官方 Node.js 24.21.0；已核对官方 SHA-256 并独立解包确认，未全局安装或修改 PATH。
- 已加入六种接入 profile、11 类音效、Codex 回合增量、窗口轮询主线程调度修正。
- 构建输入快照与打包时源码/资源一致；解包文件、安装器和 zip 的哈希分别记录。
- 该包仍是开发预览。Kimi 完整接线、其余功能矩阵及 Windows 真实运行验收没有因此完成。
- 原 0.1.0 包保留，测试时应记录使用的具体版本。

## 已提供的可测试产物

- 完整测试压缩包：`.build/XIsland-Windows-0.1.0-preview-test-kit.zip`。
- 包含 x64 NSIS 安装器、只读 Windows 检查脚本、验收说明、README 和 manifest。
- 安装器 SHA-256：`8608f80bfc095941976194f968f4ec61deaac157e98aba2f6ea441fd784cbdbb`。
- 独立 7-Zip 解包已确认主程序、原生 bridge 与 hook 脚本存在。主程序是 Windows x64 GUI PE。安装器引导程序是正常的 NSIS 32 位 stub，不改变应用的 x64 架构。
- 安装器内 exe 与未打包 exe 仅差 Tauri 的三字节 `UNK → NSS` 包类型标记。二者哈希分别记录，不能混为同一文件。
- 此 0.1.0 包未经过 Windows 安装、运行或真实客户端验收，未签名。用户将转移到另一台 Windows 电脑测试。
- 当前工作树包含该包之后的改动。工作树文件哈希仅用于追踪，不能冒充旧包的精确构建源；后续包须新增构建输入快照。

## 阶段状态

| 阶段 | 当前证据 | 仍需完成 |
| --- | --- | --- |
| M0 基准 | 冻结 145 个源码/样例文件；功能、视觉、协议文档完成；有 Mac 后续增量审计 | 继续按增量审计跟进，不覆盖冻结清单 |
| M1 骨架 | 前端构建、本机 Rust 编译、Windows MSVC 目标检查和 Windows x64 可执行程序已成功 | Windows 真实启动证据 |
| M2 视觉交互 | 收起/展开、内联请求、历史、设置、五语言、动效；20 项浏览器检查已通过，后续新增音效/拖动 2 项也已通过 | 配对 Mac/Windows 实机截图、原生边缘裁切、动画帧序列和真实 IME |
| M3 通信 | 16 MiB 帧、token 校验、请求绑定、写回确认、断连取消；独立子进程 IPC 检查通过；多窗口数据事务回归通过 | Windows Named Pipe 实际往返及每客户端原生动作 |
| M4 系统能力 | 多屏几何/缩放/拖动/交互 pin/全屏策略已实现并通过 Windows 编译；14 项几何策略测试通过 | 真机焦点、任务栏/全屏、跨 DPI、透明区命中、快捷键/启动项、精确终端标签定位 |
| M5 数据与辅助 | 历史、筛选、导出、统计、独立设置、五语言、勿扰；11 类 Mac 内置音效已实现，源曲谱/PCM/音量测试通过 | 历史导入、保留策略、声音包、自定义静音规则、配额、SSH、更新等完整对齐 |
| M6 Agent | 0.1.8 包含 15 适配器、13 自动配置来源及 WorkBuddy/Kiro 文件准备；统一生命周期、Kimi账本、Pi原生观察、OpenCode/Qwen交互已实现 | 所有 Windows 真实客户端验收；其余适配器矩阵逐项实现与验收 |
| M7 发行 | x64 安装器生成，独立解包验证，完整 zip 与只读验收材料已提供 | Windows 安装/升级/卸载、恢复、签名决策和发行前复核 |
| M8 验收 | 检查单与报告格式已准备 | 用户 Windows 结果、真实 Agent、多屏/IME及资源测量全部仍待实证 |

## 当前已验证的边界

- 本机最新 Rust 结果为 31 项单元测试及 1 项真实子进程 IPC 测试；其中一个标记 ignored 的 worker 是由集成测试显式作为子进程运行。
- 多窗口真实 `main.ts` 编排回归覆盖 owner 重建、删除失败、保存串行、启动结束事件、删除期间事件重放及审批导致旧快照复活的问题。
- 11 类音效与当前 Mac 源码曲谱相等；PCM 为 44.1 kHz 方波，保留默认音量增益。修正同时间勿扰被错误解释为全天、复用音频引擎沿用旧 mixer 音量的问题。尚未确认 Windows 设备实际播放。
- Codex 新增 `Interrupt/PreCompact/PostCompact` 和 `turn_id` 关联；已见且被替代的回合不能用观察事件覆盖当前回合。压缩状态不靠三秒定时器伪造完成。新版协议仍未真实客户端联调。
- Windsurf/Trae CN 保持纯观察；没有把可选前置门禁称为完整权限接管。

## 后续顺序

1. 优先迁移其余有明确原生合同的 Agent 路线，并继续用真实客户端核验；Kimi Node 的本批接线已完成，Windows 原生加载/任务仍待实证。
2. 在另一台 Windows 电脑验收 0.1.6 的新增五种 Agent、WorkBuddy 插件加载与 TraeWork CN 本地来源识别，记录实际版本及共享配置行为。
3. 验证原生独立设置、数据同步、音效主窗口回传；补剩余系统功能与其他客户端。
4. 按 `macos-parity.md` 的 Wxx 清单逐项完成数据辅助功能；不以已有界面替代功能完成。
5. 结合用户 Windows 测试结果修复，再执行完整交付审计。没有真实结果时保持待验，不能标记目标完成。

最近并行代理多次遇到模型容量限制。已经由主代理接续完成 Codex 增量、音效、配置胶合与相应测试；容量失败本身不提供任何验证证据。
