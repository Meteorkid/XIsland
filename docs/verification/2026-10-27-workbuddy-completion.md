# WorkBuddy 完成提醒与自动切回修复验收

日期：2026-10-27（Asia/Shanghai）。基线：XIsland v2.0.13，`2ee08c0`。本轮为未发布的本机候选，不改变版本号或正式发行。

## 原因与修复

真实 WorkBuddy 任务已经完成，但旧适配器把 `FinalStop/final_stop_reason=completed` 转为 `statusUpdate/idle`，未进入 `markCompleted`，因此没有完成时间、待查看标记和自动切回提醒。

本轮仅调整 macOS 桥接的成功映射为 `sessionEnd/completed`，复用现有完成保存、提醒队列、双岛交接与未查看展示。保留 `statusIsAssistantReply=false`，避免覆盖 Stop 已收到的正文或重复追加回复。同一聊天收到下一条用户提示后仍会恢复活动。

- Stop 仍为完成未确认；子代理通知和 SessionEnd 不关闭父任务。
- 取消和中断仍为空闲，失败仍为错误，未知原因不推断成功。
- 同一完成状态内重复事件不重复提醒，已查看后重复不重新变为未查看。
- 关闭提醒仍保存待查看结果；不新增审批、问答决定或客户端信任权限。
- 未改 Windows 适配器、授权模块、数据库结构和 XNook 源码。

## 原生合同依据

只读核对当前 WorkBuddy 5.9.2 安装资源：

- 文件：`/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/dist/codebuddy-lite-wb.mjs`
- SHA256：`29a2e96949fd85143f85c9fa31ae036657a15c351e847c7944b53a218c850a4d`
- 完成、中断、失败分支分别在字节偏移 `7680386`、`7677352`、`7696299` 排除 `meta.parentSessionId`；子代理走单独结束通知。
- FinalStop 唯一实际调用点 `7491745` 位于 Stop 处理尾部；成功 Stop 请求继续时不发 FinalStop。
- `agent_id` 是主任务也有的通用 storeId，不能凭它非空判定为子代理。`is_truncation_recovery=true` 也可能出现在恢复成功后的最后一次结束，不能一律屏蔽。
- 可选 `generation_id` 读取可变会话属性，不能据此宣称并发旧事件都有可靠回合归属。本轮没有增加基于时间或正文的猜测去重。

精确摘录和 hash 清单保存在 `.build/workbuddy-completion-20261027/contract/`。REA 分析超时，仅保留 partial Evidence；上述结论来自直接静态代码摘录，不将静态分析当作实机结果。

## 自动验证

先增加回归用例，旧代码产生 5 个预期断言失败：仍是 idle、缺少完成时间和未查看状态、提醒次数为 0。修复后：

| 检查 | 结果 |
| --- | --- |
| 首轮定向测试 | 93 项，0 失败 |
| 全量 XIsland XCTest | 1833 项，20 项按条件跳过，0 失败 |
| 授权核心测试 | 17 项，1 项按条件跳过，0 失败 |
| 发布构建与严格签名 | 通过 |
| 导出插件的 11 类命令与隔离 socket | Debug、Release 均通过；stdout 中性，无效载荷不阻断客户端 |
| WorkBuddy → 默认 AppDelegate 回调 → 80ms 提醒队列 | 显示请求一次、旧交接失效、未查看保留、重复不再呈现 |
| 临时磁盘历史 | 后台事务、重新打开、查看确认持久化、归档重复事件不重建均通过 |

复现命令：`swift test`；`python3 scripts/test-workbuddy-plugin.py --binary '.build/X Island.app/Contents/MacOS/di-bridge'`。测试只使用隔离偏好、临时历史和 socket。全量原始日志为 `.build/workbuddy-completion-20261027/full-tests.log`。

## 本机真实验收

先备份正式 App、偏好与 SQLite 一致性快照，再正常退出并安装候选。钥匙串读取确认由用户亲自完成，没有读取或记录密码。

1. 从 XIsland 设置切到 XNook，实际截图确认 XNook 岛显示，共享 `lastShown=xnook`。
2. WorkBuddy 新建具名任务 `XIsland提醒修复验收-20261027-B`，明确禁止文件、命令和工具操作，仅回复指定文本。真实界面显示完成；随后 XIsland 岛自动出现，显示该任务“已完成·未查看”。
3. SQLite 对应记录为 completed，完成时间非空、未查看为 1；共享显示权变为 xisland，attentionEpoch 更新。
4. 在历史页将该测试任务“标为已查看”，数据库未查看字段变为 0。
5. 再次切到 XNook，在同一聊天发送第二轮 `...-C`。客户端显示第二轮完成，XIsland 再次自动出现，保持同一会话 ID、产生更新的完成时间，重新显示未查看。

第二轮操作期间原生工具一次超时且当前窗口发生切换；重连后仅选择具名测试聊天，核实第二轮尚未提交才重新发送，没有停止其他任务。两轮均以真实客户端事件验收，没有向正式 socket 注入模拟事件。测试会话保留。

这证明正常主任务完成和同一聊天续问提醒已通过；真实压缩恢复、跨轮迟到乱序、嵌套代理和物理动画帧率不在本次通过范围。显式 replay 的单元测试只证明通用保护，不能宣称 WorkBuddy 原生总会提供 replay 标志。

## 安装与保留状态

- 本机 XIsland：2.0.13 修复候选，主程序 SHA256 `8d2fb3a7a0496d4c0402341f1df2ce3be15287d08efe3ff94a98e54900cefe60`。
- 桥接 SHA256：`3f358b68dfc97cfe06790f3ecdeb55045d4db2bbebe511ff086bfa9e4373e820`；稳定安装路径与包内一致。
- 授权 API 与公钥和官方 2.0.13 一致；没有改动试用或激活记录。
- XNook 原候选 SHA256 `6665313f5d1802527dcc78cbbcdec307d27facf8e940cb6ef4ebc845ce170d07` 保留，`showTaskInboxShortcut=false` 保留；未安装或改写另一聊天发布的 1.3.27。
- XIsland 自动收起开关开启、延迟 0、提醒开启均保留，最终显示 XIsland。
- SQLite integrity=ok，schema 一致，备份前所有已记录主键均保留。
- 163 个客户端配置/插件文件 hash 中 162 个一致；WorkBuddy 的 `plugins/known_marketplaces.json` 缓存发生变化，未手动编辑或回滚该缓存，不能声称所有客户端文件字节不变。

完整本机证据：`.build/workbuddy-completion-20261027/validation.json`，包括两轮前后快照、截图、原始日志、安装信息及 `before-native/` 正式版回退备份。本轮未提交、推送或发布。
