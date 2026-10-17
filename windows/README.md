# XIsland for Windows

这是 XIsland 的 Windows 客户端，采用 Tauri 2、Rust 和 TypeScript。目标是对齐 macOS 版的功能、外观与交互；当前源码为 **0.1.7 开发预览，已跟进 macOS 2.0.1 接入引导，完整功能对齐和 Windows 实机验收仍在进行**。

## 当前进度

- 已实现顶部收起/展开、多会话与子任务、内联权限/问答/计划、搜索筛选、活动与对话详情、历史、统计和导出。
- 已实现独立设置窗口、深浅/系统主题、中文/英文/日文/韩文/法文、动画强度、果冻/磁吸、减少动态效果、11 类 Mac 方波音效、逐事件声音开关和勿扰。
- Windows 原生层包括命名管道、单实例/托盘、不抢焦点的定位、水平拖动、显示器跟随、交互期间固定显示器及可选全屏隐藏。这些 API 已通过 Windows 目标编译，真实焦点、DPI、输入法和多屏效果仍需 Windows 验收。
- Claude、Codex、Cursor、Gemini 有专用 hook 入口和可审查的接入配置操作。**配置写入成功不等于该客户端已验收。** Gemini 当前只观察；Claude 多题/原生多选暂留给原客户端；其他工具能力见适配器测试与 `../docs/windows/`。
- Windsurf、TRAE CN / TraeWork CN 采用观察模式。国内版 TRAE 两款客户端共用一个配置入口；Windows 桥接通过父进程及公开产品信息分别标识 Trae CN / TraeWork CN；识别超时或信息不明时保留共享来源，不重复安装两套命令。TraeWork 0.2.2 官方 Windows 安装资源已核对，真实本地任务仍待实测，云端任务未接入。
- WorkBuddy 有独立观察适配和插件导出入口，覆盖 11 类事件；需要在 WorkBuddy 内安装并启用所导出的插件。
- 已加入 Qwen Code、CodeBuddy Code CLI、Factory Droid、OpenCode、Kimi Code Node；本次再加入 Kiro CLI V3，共 13 个适配器、11 个接入配置入口，另有 WorkBuddy/Kiro 文件准备。Qwen 支持权限回传；OpenCode 支持权限及单题/多题、多选回传；其余新增客户端提供观察能力。
- Agents 页分别显示发现程序、配置状态、Codex 原生 hook 信任和最近事件；配置或安装资源变化后旧回执失效。检测到客户端不代表已通过真实任务验收。
- 主窗口在启动及每 5 分钟检查已安装软件，自动准备已启用的接入；托盘“软件接入与授权”可查看待配置/待授权/等待活动/已接入。提醒按当前配置记忆，审批期间延迟；移除接入会先关闭自动准备。
- 有效活动必须经过会话状态机接纳；重放、心跳及已拒绝的旧回合不点亮连接状态。Codex 撤销信任会使旧活动失效，重新授权后仍需新任务事件。
- 累计统计按原生任务合并多个观察片段，历史按完成/中断时间排序；卡片与详情显示模型，最终回复完成音遵循去重、静音与勿扰设置。
- Kimi 后台任务保留原生身份与结果，支持乱序、重启恢复和历史投影；失败、失联、未确认不会显示成功勾。与 XNook 的双岛切换功能保留，需分别启动两个客户端登记。
- SSH、配额、自动更新、历史导入及完整 Mac 功能矩阵仍需继续对齐。

## 在 Windows 试用

使用提供的 x64 安装包。主程序需要 Windows 10/11 和 WebView2；安装器会按其配置处理缺失的 WebView2 运行时。0.1.1 包含隔离的 Node.js 24 LTS，不需要为 Agent hook 另外安装 Node，也不会修改全局 PATH；此前 0.1.0 预览仍需系统 Node.js。

1. 安装并启动 X Island。应用以顶部浮岛和系统托盘图标运行。
2. 点击浮岛展开，通过齿轮打开独立设置窗口。
3. 从托盘“软件接入与授权”或设置 Agents 页查看状态。已发现且启用自动接入的软件会自动准备受支持的配置；信任操作仍在原客户端完成。可以逐项关闭自动接入（保留已有配置），或查看计划后手动更新/移除。不要在有未完成审批的任务中间切换 hook 配置。
4. 用新建的临时测试项目启动相应 Agent，先验证状态，再验证权限或问题回传。
5. 运行测试包中的 `Test-XIsland.ps1`，将生成的诊断 JSON 与实际观察结果一起记录。诊断文件不包含运行时 token、提示词或原始 Agent 配置。

### TraeWork CN 与 WorkBuddy

- **TraeWork CN**：在 Agents 页使用“TRAE CN / TraeWork CN”入口。两者共用 `%USERPROFILE%\.trae-cn\hooks.json`，只安装一次；在原客户端确认启用和信任后，新建本地任务。设置成功不代表已触发，需观察真实事件。卸载这个共享入口会同时影响两款客户端。
- **WorkBuddy**：点击“导出 WorkBuddy 插件…”，在 WorkBuddy 的插件页面添加本地市场，选择显示的完整目录，再安装并启用 `xisland-workbuddy-observer`。生成目录位于 `%USERPROFILE%\XIsland-Plugins`；导出不会修改 WorkBuddy 配置或信任。若该版本不接受本地市场目录，请回传版本和错误提示。
- WorkBuddy 观察合同依据 5.7.6 / 5.7.7，并已核对 5.7.7 官方 Windows 包；本轮导出插件版本为 0.1.1。插件仅引用当前 XIsland 安装资源，移动/卸载 XIsland 后需要重新导出。升级旧插件时，先在 WorkBuddy 移除旧观察插件和旧本地市场，再导入新目录；卸载前也应完成移除。
- WorkBuddy 启动器对输入、子进程与输出分别限时，保持空 stdout 和中性退出；不使用可能进入模型上下文的异步控制输出。
- 两者均不替用户批准操作或回答问题；Stop 只表示准备停止，不能据此宣布整个任务成功。Windows 原生客户端验收尚未完成。

### 本批新增客户端

| 客户端 | 配置位置（相对用户目录） | 已实现能力 |
| --- | --- | --- |
| Qwen Code | `.qwen/settings.json` | 12 类事件、子代理分离、PermissionRequest 允许/拒绝；其他问答留在原客户端 |
| CodeBuddy Code CLI | `.codebuddy/settings.json` | 10 类观察事件；Windows 原客户端需要 Git Bash；与 WorkBuddy 分开接入 |
| Factory Droid | 优先已有 `.factory/hooks.json`，否则 `.factory/settings.json` | 9 类观察事件；保持独立 hooks 文件与 settings 嵌套格式的区别 |
| OpenCode | `.config/opencode/plugins/xisland.js` | 本地插件、原生 SDK 权限/完整多题答案回传、取消和原端解决同步 |
| Kimi Code Node | `.kimi-code/config.toml` | 20 类观察事件、后台任务账本；仅 `@moonshot-ai/kimi-code`，不适用于 Python Kimi CLI |

WorkBuddy 和 Kiro 会在检测到客户端后自动准备文件，内容相同就复用，手工修改过的文件会保留并提示。可从设置打开准备目录。WorkBuddy 仍需在原客户端导入市场并启用；Kiro 使用 CLI 2.31.0 V3 独立模板，核对实际版本后按目录 README 放入 `.kiro/hooks/`（或所用 `KIRO_HOME` 的 hooks 子目录），用 `kiro-cli chat --v3` 启动。Kiro 的 Windows 原生安装要求 Windows 11；不把 IDE、Classic 或 WSL 当成同一验收路线。准备文件成功不是加载证明。

OpenCode 的 `XDG_CONFIG_HOME`、Kimi 的 `KIMI_CODE_HOME` 可在用户目录内使用；外部位置会明确拒绝写入。安装器保留用户内容，提供计划、冲突检查、备份和精确卸载；自有插件或 TOML 块被手工修改时不会直接覆盖。升级后应在 Agents 页刷新并查看更新计划，以匹配当前安装资源。

OpenCode 官方客户端在 macOS 上的隔离测试与 Windows 真机验收分别记录。Windows 下仍需逐个核对原生加载、请求身份、响应结果及关闭应用后的回退行为。

当前安装包尚未签名。若系统阻止启动，请记录系统提示并反馈，不要更改整台电脑的安全设置。尚未在 Windows 上确认安装与卸载流程；不要把安装包生成成功当作安装验收。

## 从源码构建

Windows 构建需要 Node.js 20+、Rust MSVC 工具链、Visual Studio C++ Build Tools 和 Windows SDK。开发依赖仅安装到本目录。

```powershell
cd windows
npm ci
npm run check
npm test
npm run build
.\scripts\build-windows.ps1
```

安装包位于 `src-tauri/target/release/bundle/nsis/`。脚本会先构建原生 bridge、打包 hook，然后构建安装器。原生编译与测试失败时不会继续假装产物可用。

本机 UI 开发：

```sh
npm run dev
# 预览会话样例：http://127.0.0.1:1420/?fixture=sessions&expanded=1
# 预览审批样例：http://127.0.0.1:1420/?fixture=permission&expanded=1
npx playwright test --config playwright.config.ts
```

浏览器预览与真实数据完全隔离；带 `fixture` 的页面使用测试样例，不配置客户端，也不响应真实 Agent。

## 验证范围

```sh
npm run check
npm test
npm run build
npm run build:hook
cargo test --manifest-path src-tauri/Cargo.toml --all-targets
```

Rust 集成测试里有一个标为 ignored 的客户端 worker，它由主集成测试作为独立子进程显式运行；不能把它当成未执行的业务测试，也不能当成独立 Windows 客户端验证。

跨 Windows 编译使用项目构建目录中的独立工具链，辅助入口为 `scripts/with-local-toolchain.sh`。它不修改全局 PATH，亦不代表 Windows 运行通过。Windows 构建和浏览器结果分别记录在 `../docs/windows/evidence/`。

## 文件与恢复

- 真实 Windows 数据目录：`%LOCALAPPDATA%\XIsland`。历史、设置和运行时描述分开保存。
- Hook 配置由客户端各自的用户配置目录保存；写入前要求匹配已查看计划的 revision，并为原文件创建唯一备份。
- 删除历史以成功写盘为前提；失败保留内存记录。恢复历史不会假装旧进程仍在运行。
- 超时、断连、过期审批不会自动批准。应回原客户端确认任务当前状态。
- 开发测试设置 `XISLAND_TEST_MODE=1` 和位于系统临时目录下的独立 `XISLAND_RUNTIME_DIR`；禁止把真实用户目录作为测试运行时。

## 目标与材料

- [实施阶段和验收目标](../docs/windows/implementation-plan.md)
- [macOS 功能对照矩阵](../docs/windows/macos-parity.md)
- [视觉与交互基准](../docs/windows/visual-baseline.md)
- [协议与状态规则](../docs/windows/protocol-port.md)
- [可靠性复核](../docs/windows/reliability-review.md)

不自动提交 Git 或发布产物；完整目标继续保持进行中。
