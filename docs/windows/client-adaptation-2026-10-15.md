# TraeWork CN / WorkBuddy Windows 接入复核

## 交付范围

Windows 基线已提交为 `660c91b`，不包含现有 macOS 未提交修改。本轮继续修正来源识别与 WorkBuddy 观察启动器，目标产物为 0.1.3。没有修改真实客户端配置、信任、登录或审批，没有推送或发布。

## 官方 Windows 包证据

- TraeWork CN 0.2.2：使用 [TRAE 官方支持提供的 Windows 下载](https://forum.trae.cn/t/topic/183651/12)，通过在项目构建目录编译的 innoextract 只读解包。实际 Windows `product.json` 明确为 `SOLO_CN / trae-solo-cn / TraeWork CN / ByteDance.TraeSoloCN`，共用 `.trae-cn`。原生 DLL 和 UI 资源中的六事件、输入字段及配置路径标记已记录；没有执行安装器或客户端。[固定产物与偏移](evidence/traework-windows-package-2026-10-15.json)
- WorkBuddy 5.7.7：从 [官方历史下载页](https://www.codebuddy.cn/docs/workbuddy/Download-History)取得 Windows x64 包。Windows 两份运行时与 Mac 的哈希不同，不能继续用 Mac 字节一致性替代 Windows 协议依据。[Windows 校验报告](evidence/workbuddy-windows-contract-2026-10-15.json)
- 提取 WorkBuddy 固定 Windows 包中的插件、市场、hooks 校验器和本地路径解析函数，在内存文件映射与模拟子进程上验证。当前插件 0.1.1、11 个事件、10 秒宿主时限、`source: "./"` 均通过。未运行整个厂商模块或客户端，没有向真实文件系统提供厂商配置访问。

## 本轮修改

### TraeWork 来源

继续只安装一套共享 hooks。Windows bridge 沿当前进程的父链查询可执行程序路径，再读取对应安装目录下的公开 `resources/app/product.json`；国内版 IDE 和 Work 分别进入 `trae_ide_cn`、`traework_cn` 会话空间，避免同名原生会话互相覆盖。

识别最多检查 16 层；检查父进程创建时间，拒绝明显复用的父 PID；产品 JSON 限制 256 KiB。整个识别在独立线程中进行，接收结果最多等待 250 ms。读取失败或超时保留原有共享 `trae` 来源，不把未知客户端认作 Work。该 bridge 是单事件进程，退出时由系统回收未完成的检测线程，不使用会在运行时退出阶段继续等待的 blocking task。

只归属六事件的观察消息；审批、回答、计划、历史重放及带独立来源元数据的消息不改名。核心同时拒绝 WorkBuddy 和两个新 TRAE 保留来源的交互请求，涵盖省略 agent 字段、已有会话和保留 ID 前缀。旧共享来源历史不迁移为某一具体产品；无法可靠推断旧记录来源。

### WorkBuddy 启动与失败路径

Windows 厂商执行器将同步 hook 超时返回为失败，可能阻断 UserPromptSubmit。原先 3 秒宿主时限不足以涵盖 PowerShell 冷启动和 2 秒桥接等待，现改为 10 秒，并在 XIsland 启动器内先行限制各阶段：

- 输入复制等待最多 1 秒；启动后的 Node 进程等待最多 4 秒；超时结束本次创建的子进程。
- 子进程结束与输出排空只做有限等待。stdout/stderr 排空至 Null，不把错误文本或决定写回客户端；正常及异常路径均中性退出。
- Node 的桥接等待仍为 2 秒。宿主极端冷启动、进程调度暂停等情况仍可能耗尽余量，不能在未实机测量前宣称永不触发宿主超时。

没有采用输出 `async:true` 的办法：固定 Windows 执行器会提前返回这段原始 stdout，聚合器没有保留 suppressOutput，SessionStart/UserPromptSubmit 后续可能把控制 JSON 加入上下文。该行为已使用提取的厂商函数和内存模拟子进程复现。配置级 async 字段也没有被该命令执行链传递，不能照搬其他客户端协议。

插件版本升为 0.1.1，导出说明要求从旧观察插件升级时先移除旧插件和旧本地市场，再导入新目录。导出仍不冒充安装或信任通过。

## 复现与验证边界

在 `windows/` 执行：

```sh
npm run check
npm test
sh scripts/with-local-toolchain.sh cargo test --manifest-path src-tauri/Cargo.toml
sh scripts/with-local-toolchain.sh cargo xwin check --manifest-path src-tauri/Cargo.toml --target x86_64-pc-windows-msvc --all-targets
node --import tsx scripts/verify-workbuddy-package.mjs /tmp/xisland-workbuddy-public-audit
```

最后一项需要固定官方安装器和解包目录，脚本先核对三个 SHA-256，资源变化立即停止；不下载、不执行厂商客户端。报告记录函数切片的起止标记、字节偏移与哈希，可复核隔离方式。

本轮通过 158 项 TypeScript 测试、31 项 Rust 单元测试、1 项独立子进程 IPC 测试、3 项相关浏览器场景及 Windows 目标检查。浏览器使用明确样例检验 IDE/Work 两个标签，不能作为 Windows 原生进程归属证据。

提交检查还发现预览依赖了 Mac 未提交的问答、交互和观察样例。现将 Windows 所需的九份合成样例固定到 `windows/src/fixtures/`，不修改原文件；来源与摘要见 [样例快照](evidence/fixture-baseline-2026-10-15.json)。构建输入不再扫描整个可变的 Mac 样例目录。另把 Git 暂存树导出到全新临时目录，用现有依赖运行类型检查、测试和前端构建，确保不依赖未暂存的 Mac 文件；结果见 [干净源码检查](evidence/clean-index-build-2026-10-15.json)。

剩余验收：真实 Windows PowerShell 启动/冷启动时间、进程父链及产品目录读取、本地市场安装启用、两款客户端实际事件、断连后的原生流程，以及多屏/IME等整体目标。当前没有连接用户另一台 Windows 电脑，因此这些项目仍未验证；不以本机检查代替。
