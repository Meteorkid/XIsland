# Codex 内部问答回复标题修复与验证

日期：2026-10-24。本文记录基于 2.0.8 的标题修复及发布前验证；2.0.9 的发行、公开安装包与本机安装验收单独记录。

## 问题与修复

Codex `UserPromptSubmit` 可携带 `<send_user_message_question_reply>` 包装及 JSON 问答列表。原桥接把整个包装作为 `prompt`，App 随后写入当前会话与历史，标题取第一行时显示内部标签。

- macOS 与 Windows 均提取 JSON 列表中的字符串 `answer`，多项答案按原顺序换行连接，保留有效包装后附加的正文。
- 仅识别开头的精确保留标签；普通文本、XML、代码围栏、行内标签说明及其他客户端保持原样。
- 空、损坏或结构不符的包装不产生标题；已有会话保留上一条有效提示，新会话回退到项目名。
- 桥接与 App 入站共用同一语义，兼容旧桥接仍发送原始包装的情况。新消息在创建会话、追加用户历史和保存前完成处理。
- 旧记录在活跃/历史标题投影中使用可读答案，原始 `prompt` 与聊天内容继续保留，不迁移表结构、不批量改写历史。
- 保留标签嵌套最多展开 8 层，输出再次归一化保持一致。仅由保留起始标签组成的答案按损坏包装处理为空；需要展示该标签的代码围栏或行内说明保持原样。

会话 ID、任务颜色/编号、原生事件、回合身份与生命周期规则均未改动。

## 验证结果

| 层次 | 结果 |
| --- | --- |
| macOS 定向回归 | 新增 14 项，全部通过；修复前首批 12 项产生 28 个失败断言，复现问题 |
| macOS 全量回归 | 1,570 项：1,553 通过、17 项按需测试跳过、0 失败 |
| Windows 定向回归 | 新增 12 项，全部通过；修复前首批 9 项中 8 项失败 |
| Windows 检查 | `npm run check`、615 项测试、`npm run build` 全部通过 |
| Release 构建 | 成功；显式跳过正式 bridge 安装、PATH 配置与 DMG 发布 |
| 隔离 App 链路 | 23 个合成原生 hook、25 个检查点通过，包含回复归一化、损坏回复保留原标题、数据库/用户历史核对及重启恢复 |
| 变更复核 | 独立只读审查和 `git diff --check` 通过 |

隔离链路实际运行编译后的 bridge 与 App，读取测试数据库和诊断文件验证结果；没有调用真实 Codex 任务、发送审批或改变客户端信任。Windows 检查在 macOS 上运行，不代表 Windows 实机验收。17 项跳过的是需显式启用的渲染、性能和长稳类测试，本次新增 14 项 macOS 回归均执行。

本机正式 App 与 bridge 仍匹配原 2.0.8 的 SHA256；本轮未部署，因此当前正在运行的正式版不会因源码修复立即变化。

## 复现命令与证据

```sh
swift test --filter CodexPromptNormalizationTests
swift test
# 在 windows/ 中执行：
npm run check
npm test
npm run build
# 返回仓库根目录，构建时避免更新正式 helper 或全局配置：
X_ISLAND_SKIP_BRIDGE_INSTALL=1 X_ISLAND_SKIP_PATH_CONFIGURE=1 X_ISLAND_BUILD_DMG=0 bash Scripts/build.sh
python3 Scripts/test-codex-lifecycle-app.py --app "$PWD/.build/X Island.app" --report "$PWD/.build/chat-title-fix-2026-10-24/codex-app.json"
```

- macOS 原始日志、隔离 App 报告、源码哈希与汇总：`.build/chat-title-fix-2026-10-24/`。
- Windows 原始红灯、定向、类型检查、全量与构建日志：`windows/.build/chat-title-fix-2026-10-24/`。
- 主要改动：`CodexPromptText.swift`、`DIBridge.swift`、`SessionManager.swift`、`AgentSession.swift`、`StoredSession.swift`；Windows 对应 `codex-prompt.ts`、`session-title.ts`、Codex adapter、store 和 UI 标题入口。
- 回归：`CodexPromptNormalizationTests.swift`、`windows/tests/codex-prompt.test.ts` 与 `Scripts/test-codex-lifecycle-app.py`。
