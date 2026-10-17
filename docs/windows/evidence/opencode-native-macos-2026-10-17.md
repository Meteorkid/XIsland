# OpenCode 1.19.3 真实客户端隔离验收（macOS）

日期：2026-10-17。主机：macOS / Apple Silicon arm64。

本次通过官方 OpenCode CLI `serve` 的真实原生会话执行三组交互；模型是本机确定性 OpenAI 兼容服务。插件、hook、适配器、SDK 回传和 SessionStore 均执行项目真实代码。桌面 Rust 桥接、Windows Named Pipe、图形界面、Windows 客户端和真实模型供应商仍未由本次验证。

机器证据：[opencode-native-macos-2026-10-17.json](opencode-native-macos-2026-10-17.json)。脚本：[test-opencode-native.mjs](../../../windows/scripts/test-opencode-native.mjs)。

## 实际链路与判据

`OpenCode 原生工具 → 原生事件 → 实际生成插件 → Node 子进程 → 实际打包 hook/adapter → 临时 Node TCP 桥 → 实际 SessionStore → hook 响应 → 插件注入 SDK client → OpenCode 原生 replied 事件`。

临时桥接只替代桌面 transport，未导入或伪造 OpenCode 的 permission/question 事件，也未用 SDK 替身。脚本只经 HTTP 创建会话与发出 prompt；权限与问题的回复由生成插件调用原生注入 SDK。

| 场景 | 原生证据 | 工具执行结果 |
| --- | --- | --- |
| 批准 fixture 读取 | `permission.asked` 与同一 ID 的 `permission.replied: once` | 第二次本地模型请求包含本次随机生成的 fixture 内容 |
| 拒绝 fixture 读取 | `permission.asked` 与同一 ID 的 `permission.replied: reject` | 原生工具为 error，输出不含 fixture；当前回合停止 |
| 三行问题 | 一个 `question.asked`，岛端依序出现三个问题，一个同 ID 的 `question.replied` | 回答为 `[["dev"],["A","B","自定义😀"],["中文自由文本"]]`，后续模型请求收到完整工具结果 |

合计 5 次本地模型请求、5 次岛端交互响应。三个会话均保存用户 prompt，最后 pending 数均为 0，状态为 idle，无 `interaction.unavailable`。原生事件流独立于岛端 TCP 收据；通过条件要求两者一致，不能只以 Store 清空待办作为成功。

拒绝读取没有最终助手文本属于本版 OpenCode 默认行为。官方 [`session/processor.ts`](https://github.com/anomalyco/opencode/blob/v1.19.3/packages/opencode/src/session/processor.ts) 在 `continue_loop_on_deny` 未显式开启时停止当前循环。脚本核对原生工具拒绝结果，并要求没有第二次模型调用。

## 隔离依据

- [`core/global.ts`](https://github.com/anomalyco/opencode/blob/v1.19.3/packages/core/src/global.ts)：四个 XDG 变量控制 config/data/cache/state；`OPENCODE_TEST_HOME` 控制 OpenCode 自身 home。没有改写 `HOME` 或 `CODEX_HOME`。
- [`config/paths.ts`](https://github.com/anomalyco/opencode/blob/v1.19.3/packages/opencode/src/config/paths.ts)：禁用项目配置后仍检查 OpenCode home 的 `.opencode`，因此单独设置 `OPENCODE_CONFIG` 不足以隔离；本次 home、config、工作区均为临时目录。
- [`config/managed.ts`](https://github.com/anomalyco/opencode/blob/v1.19.3/packages/opencode/src/config/managed.ts)：以 `OPENCODE_TEST_MANAGED_CONFIG_DIR` 隔离系统配置；运行前检查 macOS 两个 managed plist 路径不存在，否则脚本停止。
- child 环境采用白名单，真实 API token、真实 provider 凭据、用户代理变量不继承；唯一启用的 provider 指向随机 localhost 端口，API key 是无效的固定 fixture 文本。服务只监听 loopback，OpenCode 服务密码为临时随机值且未写入报告。
- 禁用默认插件、Claude 兼容规则与技能、外部技能、LSP 下载、文件监听、模型目录抓取、自动更新。有效 `/config` 必须只包含本次 provider 和一个生成插件。
- 不能使用 `OPENCODE_PURE`，因为该开关会跳过待验证的外部插件，见官方 [`plugin/index.ts`](https://github.com/anomalyco/opencode/blob/v1.19.3/packages/opencode/src/plugin/index.ts)。临时配置目录提前提供 package-lock 与 node_modules，避免初始化 npm 安装；npm registry 也被指向 localhost 拒绝服务。
- 所有工具默认 deny，只有本次随机临时目录内的精确 `fixture.txt` 路径可 ask；桥接额外核对原生权限种类与精确路径。仅批准 `allow-read` 场景，`deny-read` 明确拒绝；其它权限一律拒绝并令验收失败。

未执行全局安装、真实项目修改、真实 Agent 配置变更、凭据/信任设置更改、提交、推送或发布。下载的第三方二进制和官方参考源码保存在 `/tmp/xisland-opencode-native-1.19.3`，未放入仓库。

## 固定分发与复跑

官方 npm 分发 `opencode-darwin-arm64@1.19.3`：

- [下载地址](https://registry.npmjs.org/opencode-darwin-arm64/-/opencode-darwin-arm64-1.19.3.tgz)
- tarball SHA-256：`6b0d3cf1f00f9df971702f96d812562e8b94ae870c5a74ca149d8e00b2187b32`
- npm SHA-512：`NmDF28jD8W7m9a/k4mc3rajEWftDemGecrzBJItzTWwN0Eu5WFSEFBocvmmasUr4nh8ei9Zl1pwRvv66R4dN6A==`
- 解压后二进制 SHA-256：`6d3e6458fce4b649edf974c19959d5dbfe1e7f255a503dcfc01215b24ad3ea5b`
- 上游许可：[MIT](https://github.com/anomalyco/opencode/blob/v1.19.3/LICENSE)。本仓库未引入第三方源码。

准备相同版本后，在已有本项目依赖的 macOS arm64 主机执行：

```sh
cd /Users/meteor/github/xisland/windows
node scripts/test-opencode-native.mjs \
  /tmp/xisland-opencode-native-1.19.3/package/bin/opencode \
  ../docs/windows/evidence/opencode-native-macos-2026-10-17.json
```

脚本执行前校验二进制 SHA-256 和 `--version`。输出 JSON 包括当前源码/生成插件/打包 hook/脚本哈希、原生事件、工具结果、Store 收据与完整三场景判据。临时目录保留供复核；其精确位置见 JSON `isolatedDirectory`。仅需清理该专属目录即可移除测试状态。

## 验收夹具修正记录

首轮的 `/var` 与 `/private/var` 路径差异使 OpenCode 将 fixture 判为外部路径，默认 deny 正确拦截；现以 `realpath` 统一。hook 的测试桥接路径最初未位于 child `TMPDIR`，也被既有测试隔离检查正确拒绝，现已移入其独立子目录。第二轮真实批准已通过，随后按官方拒绝停回合行为修正判据。

Store 已确认发送后，原生 `interaction.resolved` 的幂等通知可能返回 `Unmatched interaction resolution`；脚本将这类无待办的重复清理保留在证据中，不将其当作交互失败。其余 Store 事件均要求接受。上述修改仅限验收夹具，没有为通过测试修改产品插件、适配器或 SessionStore。
