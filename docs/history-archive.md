# 全历史 JSON 导出

设置中的全历史导出逐批遍历已持久化会话，不受历史列表分页或 1,000 条上限影响。导出完成后显示实际会话数和文件路径。它是历史数据导出，目前不提供导入功能，也不承诺恢复可运行会话。

## 版本 1 结构

顶层字段：

- `format`：固定为 `xisland.history`。
- `schemaVersion`：当前为 `1`。
- `exportedAt`：导出开始时间。
- `dateEncoding`：固定为 `secondsSince1970`；所有日期均为 Unix 秒数，保留 `Date` 的亚秒精度。
- `binaryEncoding`：固定为 `base64`。
- `sessions`：全部持久化会话记录。
- `sessionCount`：实际写入的会话数量，与 `sessions` 长度一致。

会话字段沿用 `StoredSession` 原字段名，包括 `sessionId`、`agentTypeRaw`、`statusRaw`、`startTime`、`completedAt`、`observationEndedAt`、`historyDate`、`sourceNamespace`、`sourceInstanceId`、`nativeTaskId`、`prompt`、`workingDirectory`、`terminal`、`recapText`、`inputTokens`、`outputTokens`、`totalTokens`、`estimatedCostUSD`、`model` 和 `kimiCodeApprovalObservationData`。未知的 Agent 或状态字符串按原值保留。

每条会话包含完整的 `toolEvents` 和 `chatMessages` 数组。工具事件保存 `eventId`、工具名称、完整输入/输出、时间、增删/读取行数、通过/失败/跳过测试数、`toolCallId`、`isComplete`、`completionUnconfirmed` 和 `nativeCompletionStatus`；聊天记录保存 `messageId`、时间、原始角色和完整文本。可选字段为 `nil` 时省略，空字符串和空数组仍按原值写入。关系的数组顺序遵循持久化关系，不额外推断原始执行顺序；时间和稳定 ID 一并保留。

`kimiCodeApprovalObservationData` 以 Base64 原样保留会话中已经持久化的 CLI 状态事实。它不含回调或授权通道。导出不会包含运行时 socket、审批 closure、可发送批准回复的连接或其他可复活的审批能力；独立于会话的内部审批 orphan 账本不在此会话导出范围中。

导出文件包含聊天文本、工具输入输出和本地路径等原始内容；这些内容可能含用户自己的敏感信息，因此临时文件和最终文件以仅当前用户可读写的权限创建。

## 写入与失败行为

先在目标所在目录创建独占临时文件，逐会话编码和写入；写入、同步和关闭均成功后，再通过同文件系统的原子重命名发布结果。已有普通可写文件可替换。目标为目录、符号链接或只读文件时拒绝导出；发布前复核目标身份与修改时间，避免覆盖导出过程中已经更换或更改的目标。

遍历、JSON 编码、写入或同步失败都会向界面返回错误，并清理临时文件。发布前不改动已有导出文件，也不会把半成品作为成功结果。导出只操作临时测试数据或用户选定的目标文件，不修改历史数据库。
