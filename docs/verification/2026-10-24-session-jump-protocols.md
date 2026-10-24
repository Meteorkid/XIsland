# 会话精确跳转协议核验（2026-10-24）

本记录来自本机已安装客户端的只读静态分析。目标是打开对应聊天或任务；激活应用、抬起窗口、打开工作目录不构成精确跳转。下列偏移均为打包 JavaScript 解码为 UTF-8 字符串后的字符偏移，不是文件字节偏移。

## 已安装产物

| 客户端 | 版本 / bundle ID | 检查路径及 SHA256 |
| --- | --- | --- |
| Codex（应用名 ChatGPT） | `26.1016.62342`，build `21477`；`com.openai.codex` | `/Applications/ChatGPT.app/Contents/Resources/app.asar`；`5b5cf52887cfd4de19cb5862155a8ef6cf58830c0a2fc592b72060cfcc3be869` |
| WorkBuddy | `5.9.0`；`com.tencent.workbuddy.mac` | `/Applications/WorkBuddy.app/Contents/Resources/app.asar`；`7c7eff24a60fa00f7c740cdfd3194631f2ced523ef60fea59abe26e27fc85940` |
| Cursor | `3.15.6`；`com.todesktop.230313mzl4w4u92` | `/Applications/Cursor.app/Contents/Resources/app/extensions/cursor-deeplink/dist/main.js`；`542e6f04e77b9af5222b2b066e56a62efd8e099995b32bd622e320716837c111` |

Cursor 的后续导航实现位于 `/Applications/Cursor.app/Contents/Resources/app/out/vs/workbench/workbench.glass.main.js`，SHA256 为 `812042a3e259f600853f6f1060fbf55ee59b3d0e74a384ac6f27ed7148d9071f`。

WorkBuddy 的 hook 身份实现位于 `/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/dist/codebuddy-lite-wb.mjs`，SHA256 为 `2924e098cd8a62d5cf7f1d2897b014664f95aa9cbe21b87a7e2ae6f15187dfc8`。

## 精确路由与身份映射

| 来源 | 路由模板 | 接受的现有身份 |
| --- | --- | --- |
| Codex desktop | `codex://threads/<UUID>`；协议另支持可选 `hostId` query | `codex-<UUID>` 去掉一次前缀；UUID 必须完整匹配 `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`（忽略大小写） |
| Cursor agent 聊天 | `cursor://anysphere.cursor-deeplink/agent?id=<encoded-native-ID>` | `cursor-<conversation_id>` 去掉一次前缀；ID 作为单个 query value 编码 |
| WorkBuddy 本地命令 hook | `workbuddy://chat/<encoded-native-ID>` | 严格解码 `workbuddy-<base64>`，结果必须为非空 UTF-8；将完整原生 ID 作为单个 path segment 编码 |

三类 ID 均应拒绝 NUL、控制字符和空白身份。不能把缺失原生身份时的稳定哈希、cwd、窗口标题或当前前台窗口号升级为原生聊天身份。Codex 的 `resolveSessionId` 允许 `--session`、`DI_SESSION_ID` 覆盖原生输入，因此前缀和 UUID 校验只能证明格式；原生身份来源仍须由调用链保证。

### Codex

ASAR 内 `.vite/build/src-CSKkIr_z.js` 偏移 `14908` 定义 UUID 约束；`Vt` 检查 `codex:`、host=`threads` 并提取 `conversationId`。`.vite/build/bootstrap-DCRTDDSX.js` 偏移 `531602` 将该输入解析为 `localConversation`。`.vite/build/main-JI9qDiXp.js` 偏移 `3703918` 使用同一 `conversationId` 导航聊天，并保留非 `local` 的 `hostId`。

`webview/assets/agent-activity-item-748850b17d3d.js` 也直接构造 `codex://threads/${encodeURIComponent(t.threadId)}`。现有桥接没有可靠的远程 `hostId` 字段，不能猜测远程主机；当前结论覆盖本地原生线程。

### WorkBuddy

`WorkBuddyHookAdapter` 将 hook 的 `session_id` 按 UTF-8 Base64 编成 `workbuddy-<base64>`，反解时应保留原始字符串，不替换为展示标题。

上述 CLI 文件偏移 `7450927` 的 `resolveHookSessionId(t)` 返回 `t.meta?.parentSessionId ?? t.id`；`UserPromptSubmit`、`SessionStart`、`Stop`、`FinalStop` 使用该身份。ASAR `main/server.js` 偏移 `1974023` 的 worker 参数包含 `--serve --session-id <conversationId>`；偏移 `1976430` 的预热激活同样传入 `sessionId: t.conversationId`。因此本地主聊天的 hook ID 与导航 ID 一致，子代理 hook 则归并到父会话。

ASAR `main/main-bootstrap.js` 偏移 `655296` 按 `conversationId` 匹配已打开聊天窗口，偏移 `656029` 将同一 session ID 编码到 `workbuddy://chat/`。`renderer/assets/msg-center-popup-utils-BErQebmC.js` 偏移 `26909` 将 `chat/<id>` 映射为 `/task/<id>`。

云端 ACP 存在 `conversationId` 与 runtime session ID 重绑定机制；本地命令 hook 的上述等价关系不能直接用于未核实的云端来源。项目适配器仍标注 `workbuddy_5_7_6`，本次仅静态复核 5.9.0 的相关身份与导航链路，不代表完整 hook 合同升级验收。

### Cursor

`extensions/cursor-deeplink/dist/main.js` 偏移 `810293` 将 `/agent` 转交 `cursor.openOrFocusGlassWindow`。Glass 主代码偏移 `45540886` 的 `handleAgentOpen` 读取 query `id` 并调用 `glass.openCloudAgentById`；偏移 `45357996` 的命令注册经 `q1f` 调用偏移 `32361369` 的 `JKs`。

`JKs` 先按原始 ID 读取已有 agent header，本地已有聊天可以直接返回；只有 cloud ID 才补加载。随后 `Ybi` 发送含同一 ID 的 `selectAgentRequested`。找不到目标时显示原生错误。命令名中的 `Cloud` 不等于仅支持云聊天。

Cursor 的 `conversation_id` 也可能来自 Cmd-K 或 tab completion，这类 ID 未必对应 agent header。即使格式合法，导航失败也不能再退回首个聊天或任意窗口。

## 宿主与父子会话

- 明确的真实终端宿主优先：Codex CLI 在 iTerm、Terminal 等终端中运行时，应使用该终端的精确 session/pane 身份，不能因 agent 类型为 Codex 就打开 desktop。
- 子任务有 `parentSessionId` 时，先找到父会话，再共同使用父会话的 ID、terminal 和 `termSessionId`。只替换 ID、继续使用子任务的宿主元数据会产生交叉归属。
- Codex `SubagentStart` / `SubagentStop` 桥接已经设置 `parentSessionId = sessionId`；`SessionManager` 按 `parentSessionId ?? sessionId` 定位父会话。现有字段足够，无须新增协议字段。
- `windowNumber` 当前来自应用在事件到达时的 focused/front window；它只能描述当时窗口，不能证明对应聊天或任务标签页。
- 尚未确证 VS Code Local 的 `copilot-local-<session_id>` 可用原生聊天 deep link。缺少可验证路由时应明确返回不可用。

## 验收边界

本次没有打开 deep link、点击客户端、发送消息、修改信任或客户端配置，也没有进行 GUI 跳转验收。系统接受 URL 仅能报告“精确路由已发出”，不能报告“已看到目标聊天”。需要后续分别核验多聊天、多窗口、子任务、目标关闭和 ID 不存在时的实际表现。

REA 静态分析记录为 `ev_9a93eaf6b03a760cc7bb2f531e8bf0b2129d9ec8f833ab051ba1e986f4fa11d0`。Codex 部分 unpacked native 文件与 ASAR 完整性声明不一致；分析以 `record-and-continue` 保留该限制。协议结论来自上述已检查的 JavaScript，未执行这些代码。
