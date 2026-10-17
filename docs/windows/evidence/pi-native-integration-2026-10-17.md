# Pi 原生扩展验证（2026-10-17）

当前实现使用 Pi 的 `ExtensionAPI`，经官方 `@earendil-works/pi-coding-agent@1.3.0` 验证。此包为 MIT 许可，入口为 `dist/bundle/cli.js`，要求 Node >=22.19.0。官方源码只用于核对协议；未引入第三方源码或运行时依赖到仓库。

## 已完成的证据

- `tests/pi*.test.ts`：29 项通过，包括适配器、真实 Node 子进程、SessionStore 回放，以及 21 项独立安装器保护检查。
- `pi-native-client-2026-10-17.json`：macOS arm64 上使用 Node 24.5.0 启动官方 CLI，自动发现隔离 agent-dir 的 `extensions/xisland.ts`，经过两次本地模型请求，实际执行 `read` 工具，捕获全部 8 类事件并回放到真实 SessionStore。
- `pi-session-switch-2026-10-17.json`：通过官方 RPC `new_session` 创建第二个会话，四次本地模型请求、两次真实 `read`、17 条事件。两个会话均正确经历 active → idle → completed，模型 ID 保留。
- `pi-bundled-hook-2026-10-17.json`：上述双会话进一步执行当前 `src/hook.ts` 的打包 CJS，全部 17 条事件经临时 Node bridge 收集为实际 DIMessage，逐条校验并送入 SessionStore。每次 hook 均退出 0，stdout/stderr 均为空；测试 wrapper 只追加 `--test-bridge-script`，且 `XISLAND_TEST_MODE=1`。
- `npm run check` 通过。

原生 CLI 检查均使用 `127.0.0.1` 的确定性 OpenAI 兼容模拟服务，没有真实服务商请求。前两个报告使用捕获载荷的临时 hook；第三个报告实际执行指定 CJS，但 bridge 是 Node 替身。Windows 安装包的原生 Rust bridge → Named Pipe → UI 链路属于另外的验收层，`windowsRuntimeVerified` 仍为 `false`。

## 协议与生命周期

观察的事件为 `session_start`、`before_agent_start`、`agent_start`、`tool_execution_start`、`tool_execution_end`、`agent_end`、`agent_settled`、`session_shutdown`。`agent_end` 不代表空闲；仅在 `agent_settled` 且 `ctx.isIdle()` 时上报 idle。`session_shutdown` 关闭当前会话。所有 handler 都返回 `undefined`，不处理权限或问答决策。

Pi 1.3.0 的 `AgentSessionRuntime.newSession()`/`switchSession()` 在 `session_shutdown` 后销毁当前会话，再创建新运行时并重新绑定扩展。因此插件内的 `closed` 属于一次 factory 的有效生命周期。官方 RPC `new_session` 会额外调用一次 `rebindSession()`，实际可观察到第二个会话的重复 `session_start`；回放保留此事件，未产生第三个会话或丢失后续工具事件。

## 安装与隔离边界

默认路径为 `~/.pi/agent/extensions/xisland.ts`。安装器支持官方 `PI_CODING_AGENT_DIR`，目前仅允许用户目录内的绝对路径，拒绝相对路径和用户目录外位置。精确认领整个生成文件；编辑、追加、BOM、无效 UTF-8、链接或过大文件均拒绝覆盖。计划 revision 同时绑定配置路径、文件内容、Node 路径和 hook 路径；切换目录或运行时后必须重新审阅。写入另有身份复核、排他锁、同目录临时文件、原子替换和逐字节备份。

验证脚本不覆盖 `HOME`/`CODEX_HOME`。子进程环境采用白名单，设置临时 `PI_CODING_AGENT_DIR`、XDG、TMP 路径，并传入 `--offline --no-approve --no-context-files --no-mcp --no-skills --no-prompt-templates --no-themes --no-session`。没有继承真实认证环境变量。

隔离依据已核对官方发行包：`config.js:getAgentDir()` 优先使用 `PI_CODING_AGENT_DIR`；AuthStorage、models、settings 跟随该目录；`ProjectTrustStore` 使用 agent-dir 的 `trust.json`；PackageManager 的全局扩展及 npm/git 目录也位于 agent-dir；`noContextFiles` 将上下文文件列表设为空；SYSTEM/APPEND 只从 agent-dir 或获信任项目读取，而本次项目明确不信任。

## 重跑

先将官方发行包及其 `jiti@2.7.0` 依赖放入隔离临时目录。脚本不会自动下载、安装全局依赖或修改真实配置。

```sh
./node_modules/.bin/tsx --test tests/pi*.test.ts
./node_modules/.bin/tsx scripts/verify-pi-client.ts --cli /absolute/pi/dist/bundle/cli.js --node /absolute/node --report /absolute/pi-native-report.json
./node_modules/.bin/tsx scripts/verify-pi-client.ts --cli /absolute/pi/dist/bundle/cli.js --node /absolute/node --switch-session --report /absolute/pi-switch-report.json
./node_modules/.bin/tsx scripts/verify-pi-client.ts --cli /absolute/pi/dist/bundle/cli.js --node /absolute/node --switch-session --bundled-hook /absolute/extracted/xisland-hook.cjs --report /absolute/pi-bundled-report.json
```

官方参考：[扩展 API](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)、[配置路径](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md)、[Windows 支持](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/windows.md)、[会话运行时](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/agent-session-runtime.ts)、[RPC 模式](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/rpc/rpc-mode.ts)、[npm 1.3.0 元数据](https://registry.npmjs.org/@earendil-works/pi-coding-agent/1.3.0)。
