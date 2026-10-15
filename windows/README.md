# XIsland for Windows

这是 XIsland 的 Windows 客户端，采用 Tauri 2、Rust 和 TypeScript。目标是对齐 macOS 版的功能、外观与交互；当前源码为 **0.1.2 开发预览，不是已经完成全部功能对齐的正式版**。

## 当前进度

- 已实现顶部收起/展开、多会话与子任务、内联权限/问答/计划、搜索筛选、活动与对话详情、历史、统计和导出。
- 已实现独立设置窗口、深浅/系统主题、中文/英文/日文/韩文/法文、动画强度、果冻/磁吸、减少动态效果、11 类 Mac 方波音效、逐事件声音开关和勿扰。
- Windows 原生层包括命名管道、单实例/托盘、不抢焦点的定位、水平拖动、显示器跟随、交互期间固定显示器及可选全屏隐藏。这些 API 已通过 Windows 目标编译，真实焦点、DPI、输入法和多屏效果仍需 Windows 验收。
- Claude、Codex、Cursor、Gemini 有专用 hook 入口和可审查的接入配置操作。**配置写入成功不等于该客户端已验收。** Gemini 当前只观察；Claude 多题/原生多选暂留给原客户端；其他工具能力见适配器测试与 `../docs/windows/`。
- Windsurf、TRAE CN / TraeWork CN 采用观察模式。国内版 TRAE 两款客户端共用一个配置入口；当前不区分事件究竟来自 IDE 还是 Work，不重复安装两套命令。TraeWork 的协议证据来自 0.2.2 公开安装资源，Windows 本地任务待实测，云端任务不在当前接入范围。
- WorkBuddy 新增独立观察适配和插件导出入口，覆盖 11 类事件；需要在 WorkBuddy 内安装并启用所导出的插件。完整目标矩阵、Kimi 原生观察接线、SSH、配额、自动更新、自定义静音规则等仍在后续阶段。

## 在 Windows 试用

使用提供的 x64 安装包。主程序需要 Windows 10/11 和 WebView2；安装器会按其配置处理缺失的 WebView2 运行时。0.1.1 包含隔离的 Node.js 24 LTS，不需要为 Agent hook 另外安装 Node，也不会修改全局 PATH；此前 0.1.0 预览仍需系统 Node.js。

1. 安装并启动 X Island。应用以顶部浮岛和系统托盘图标运行。
2. 点击浮岛展开，通过齿轮打开独立设置窗口。
3. 在 Agents 页选择客户端，先查看配置位置、增删数量、备份说明，再确认应用。不要在有未完成审批的任务中间切换 hook 配置。
4. 用新建的临时测试项目启动相应 Agent，先验证状态，再验证权限或问题回传。
5. 运行测试包中的 `Test-XIsland.ps1`，将生成的诊断 JSON 与实际观察结果一起记录。诊断文件不包含运行时 token、提示词或原始 Agent 配置。

### TraeWork CN 与 WorkBuddy

- **TraeWork CN**：在 Agents 页使用“TRAE CN / TraeWork CN”入口。两者共用 `%USERPROFILE%\.trae-cn\hooks.json`，只安装一次；在原客户端确认启用和信任后，新建本地任务。设置成功不代表已触发，需观察真实事件。卸载这个共享入口会同时影响两款客户端。
- **WorkBuddy**：点击“导出 WorkBuddy 插件…”，在 WorkBuddy 的插件页面添加本地市场，选择显示的完整目录，再安装并启用 `xisland-workbuddy-observer`。生成目录位于 `%USERPROFILE%\XIsland-Plugins`；导出不会修改 WorkBuddy 配置或信任。若该版本不接受本地市场目录，请回传版本和错误提示。
- WorkBuddy 观察合同依据 5.7.6 / 5.7.7。插件仅引用当前 XIsland 安装资源，移动/卸载 XIsland 后需要重新导出；卸载前应先在 WorkBuddy 停用并移除插件及本地市场。
- 两者均不替用户批准操作或回答问题；Stop 只表示准备停止，不能据此宣布整个任务成功。Windows 原生客户端验收尚未完成。

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
