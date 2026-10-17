# Windows 跟进 macOS 2.0.1

## 基准与范围

2026-10-17 通过 GitHub 公开 latest 核对最新版本为 [v2.0.1](https://github.com/Meteorkid/XIsland/releases/tag/v2.0.1)，对应本地 `e335c5d`。实际接入行为提交为 `bf41f27`；同时迁移 `1845472` 中本轮复现的数据/展示差距。Git SSH fetch 被远端断开，未修改 Git 远程配置；公开发行页面与本地完整提交内容一致。

沿用 Windows Tauri/Rust/TypeScript 架构和原有安全安装器。两种选择中，本轮采用统一协调既有 status/plan/apply，避免复制一套配置写入器。状态判断保持纯 TypeScript；设置副窗口仅发动作和读取主窗口快照。改动前 tracked patch 与 untracked ZIP 保存到 `.build/mac-201-sync-before*`。已有 0.1.6 包、Mac 源码与 XNook 双岛联动保留。

## 对齐清单

| Mac 最近变化 | Windows 本轮实现 | 验证重点 |
| --- | --- | --- |
| 统一软件接入与授权 | 托盘直达、现有 Agents 独立设置页、7 类阶段、11 来源自动开关 | 不把已配置当已接入；关闭自动接入保留现有配置 |
| 启动与周期自动准备 | 仅主窗口启动/300 秒扫描；检测到程序且启用才调用原安装器 | 计划 revision、失败同输入不重写、成功后客户端重写可再修复 |
| 记住提醒并避免抢占 | 按阶段与配置指纹保存提醒；首次等待活动引导；关闭后记住最终检查结果 | 首次扫描前不误弹；真实审批待办期间延迟而不丢提醒 |
| Codex 信任生命周期 | 活动绑定 hooks/list 指纹；撤销持久失效；查询后重新校验配置和资源 | 撤销再授权无新事件不点绿、并发撤销、查询期间短任务 |
| 接收有效活动才接通 | hook 仅携带投递前身份；Rust 剥离元数据；主窗口状态机接受后确认 | 旧回合、来源冲突、重放、心跳和观察结束不生成接通证据 |
| WorkBuddy 自动准备 | 内容寻址目录、只读核对、复用未修改文件、打开目录 | 不写 WorkBuddy 市场/信任；编辑过的产物不覆盖 |
| Kiro V3 配置准备 | 2.31.0 V3 六事件观察适配和独立文件准备 | Stop 无答案不伪造成功，准备不等于加载，不接管审批 |
| 用量与历史修正 | 同原生任务跨观察实例按累计最大值聚合，时长取区间并集；历史按完成/中断时间 | 原始历史片段不合并删除，来源和 Unicode ID 不串任务 |
| 模型与完成提示 | 卡片/详情显示模型；核心接受最终回复后发临时声音通知 | partial/replay/旧消息不响，1800 ms 防抖，静音/勿扰和副窗口生效 |

## 实现边界

- 当前 Windows 自动配置来源仍为 11 个；WorkBuddy 与 Kiro 是独立观察文件准备，不把它们冒充已在原客户端安装或授权。
- Kiro 官网现在列出 Windows 11 PowerShell 安装路径，见 [安装文档](https://kiro.dev/docs/getting-started/installation/)、[hooks](https://kiro.dev/docs/hooks/)、[actions](https://kiro.dev/docs/hooks/actions/)。模板基线为 2.31.0 V3；未从程序存在推断该版本，未在 Windows 执行其 hook 宿主和加载流程。
- 真实用户的配置、凭据、信任在开发验证中不变；所有写配置回归使用临时目录或 API 替身。新增自动准备行为只在用户以后运行 Windows 程序时执行。
- Windows 原生安装、升级/卸载、真实 Agent、PowerShell、声音设备、多屏/DPI/IME仍待另一台电脑。跨编译与浏览器测试不能代替。
- 其余 Mac 31 条接入矩阵、GLM 跨客户端筛选、模型搜索、SSH、更新与完整声音包/静音规则未被本轮声称完成。

## 复跑入口

在 `windows` 目录执行 `npm run check`、`npm test`、`npx playwright test`、`npm run build` 和 `npm run build:hook`。Rust 主机测试为 `sh scripts/with-local-toolchain.sh cargo test --manifest-path src-tauri/Cargo.toml --all-targets`；Windows 目标检查额外使用 `cargo xwin check --target x86_64-pc-windows-msvc --all-targets`。

完整的官方 OpenCode 隔离联调可执行 `node scripts/test-opencode-native.mjs`，它使用 macOS 官方 CLI 与 localhost 固定模型，Rust transport/UI/Windows仍单独验收。新版构建与最终测试数量在本文件后续结果段及 `evidence/` 固定。

## 最终结果：Windows 0.1.7

- 383 项 TypeScript、32 项浏览器、34 项 Rust 单元及 1 项独立进程 IPC 通过；类型检查、前端/hook 构建、Windows MSVC 目标检查和 release/NSIS 构建通过。
- 实际独立解包的 hook 脚本再次执行官方 OpenCode 1.19.3 macOS 三场景，允许读取/拒绝读取/完整三题均通过。脚本哈希与安装器内字节一致；42 条回执、5 次响应、6 个原端请求/回复事件。模型仍是 localhost 固定服务，Rust/UI/Windows 本体未由此验证。
- 打包脚本复验沿用 `test-opencode-native.mjs`，仅将其中生成 hook 的 esbuild 调用替换为读取解包文件；专属复跑脚本保存在 `windows/.runtime/test-opencode-packaged-0.1.7.mjs`，哈希载于报告。普通源码复跑报告按应用版本保存，0.1.6 证据已保留。
- 修复独立复核发现的首扫前误弹窗、主窗口重载时旧连接快照、准备文件期间旧查询覆盖新目录/丢刷新；窗口异步失败均有反馈。
- 安装器独立解包核对 9 个文件及 x64 PE；158 个构建输入与当前源代码一致，ZIP 7 个条目通过 CRC 和 manifest 哈希。
- 测试包：`.build/XIsland-Windows-0.1.7-preview-test-kit.zip`，26453399 字节；SHA-256 `31c15590e182fba0766112d3b857157bfcc1bb02be1bf27bf37a9e3826d92588`。未签名、未提交、未推送、未发布。

机器摘要见 `evidence/macos-2.0.1-sync-2026-10-17.json`；安装器见 `evidence/installer-inspection-0.1.7.json`；实际脚本联调见 `evidence/opencode-native-packaged-hook-0.1.7.json`。
