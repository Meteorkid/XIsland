# Windows 多窗口与持久化可靠性复核

日期：2026-10-14。范围：`windows/src/core/`、`windows/src/main.ts`、原生 `transport.rs`、`desktop.rs`、`desktop_sync.rs` 的串联。审查代理只新增回归测试与本文；生产修复由根代理完成。

## 复核结论

独立设置窗口的只读副本、请求通道隔离和历史删除确认方向正确。审查实际定位并复现了三个会影响状态真实性或历史记录的边界，修复后当前六项针对性回归全部通过。原生重载队列与旧请求取消是另行发现的生命周期风险，不能由这些 JavaScript 测试代替原生验收。

| 问题 | 具体触发与影响 | 当前修复状态 |
| --- | --- | --- |
| 主窗口重建后 revision 归零，设置窗口冻结 | 旧 owner 已发布较高 revision；主 WebView 重载后新 SessionStore 从 0 开始，旧 receiveSnapshot 持续拒绝新 owner 的快照，设置保留旧历史或待办 | 已加入 ownerInstanceId、独立 owner 代际和 retiredOwners；新 owner 可从较小 revision 接管，迟到旧 owner 不可回滚。对应回归通过 |
| 删除写盘失败后内存已经删除 | 旧流程先 dismiss/clearHistory 并发布空列表，再调用 save_history；磁盘失败只回错误，内存未恢复，造成列表与磁盘不一致 | 已改为 prepareHistoryRemoval → 持久化候选历史 → commitHistoryRemoval；写失败不提交内存删除。对应实际 main.ts 回归通过 |
| 删除期间 UI 裁决排入旧自动保存，使已删记录复活 | 删除写盘较慢时用户处理另一请求；UI 直接修改 store，旧订阅定时器提前序列化仍包含待删记录的快照，排在删除写入之后；删除 ACK 成功后旧快照可能重新写回 | 已在 ownerFrozen 期间抑制普通自动保存；自动保存实际执行时读取最新状态；事务完成后安排新保存。此问题曾在新增第六项测试中真实失败，修复后通过 |
| 主 WebView 重载期间丢失新事件 | queue.ready 一旦 true，旧实现不会在页面重载时改回 false；新页 load_history/注册监听的空窗中，emit_to 可能没有消费者但仍返回成功 | 当前源码已加入主窗口 PageLoadEvent::Started 处理，重新关闭 ready 并使 owner token 失效。原生生命周期验收待根代理补充 |
| 旧 owner 的保存或发布覆盖新 owner | 仅按窗口 label=main 授权无法区分同一 WebView 的前后两代脚本 | publish_snapshot 和 save_history 已绑定原生分配的 ownerToken；失效 owner 不可再覆盖快照/历史。静态接口已检查，原生重载回归待补 |
| 已交给旧前端的审批在重载后继续挂起 | 历史恢复会剥离 transportRequestId，旧 Bridge.pending 若继续保留，原客户端仍可能等待至 120 秒 TTL | 当前源码已在 ready 的主页面重载 Started 时调用 Bridge.cancel_all，不重新激活旧审批；结束通知沿既有 ended 路径回到前端。静态落地已看到，原生验证由根代理补证据 |

文件定位：

- [SessionStore](../../windows/src/core/session-store.ts)：`receiveSnapshot`、`prepareHistoryRemoval`、`commitHistoryRemoval`、`serializeHistory`。
- [前端入口](../../windows/src/main.ts)：`connectOwner`、`persist`、`mutateOwner`、启动时的 initial/live 合并。
- [原生多窗口同步](../../windows/src-tauri/src/desktop_sync.rs)：`register_owner`、`invalidate_owner`、`with_owner`、`publish_snapshot`、历史操作 ACK。
- [桌面生命周期](../../windows/src-tauri/src/desktop.rs)：`frontend_ready`、`save_history`、`on_page_load`、桥接事件队列。
- [原生传输](../../windows/src-tauri/src/transport.rs)：`Bridge.pending`、请求结束回调、单次响应回执。

## 实际执行的六项回归

测试文件：[multiwindow-regression.test.ts](../../windows/tests/multiwindow-regression.test.ts)。测试使用真实 SessionStore，并将当前 `main.ts` 转译后放入隔离 VM 执行；只替换 IPC、UI 挂载和计时器。没有复制待测保存编排，也没有通过跳过/TODO 隐藏失败。

1. 设置副本接受新 owner 的较小 revision，拒绝退役 owner 的迟到快照。
2. 删除写盘失败后，owner 与发布给设置窗口的记录仍保留，并向对应操作返回错误。
3. 两次删除写入串行执行，只有对应磁盘写完成后才确认对应 requestId。
4. frontend_ready 返回期间暂存的新 live 请求，不会被初始快照中的旧 ended 通道误失效。
5. 删除写盘期间收到的新业务事件，事务完成后仍被应用，且保留为活动会话。
6. 删除写盘期间用户处理另一审批，后续保存不会把已删除记录重新带回。

执行结果：

```text
npx tsx --test tests/multiwindow-regression.test.ts
tests 6
pass 6
fail 0
skipped 0
todo 0
```

该测试文件另以 ES2022 + Node 类型执行严格 TypeScript 编译通过。未因本次复核重跑整套前端、Swift 或 Cargo 测试。

## 已核对的安全边界与剩余证据

- 设置 store 使用 readOnly，receiveSnapshot 复制数据并剥离 transportRequestId；本地提交、直接删除和 apply 不能修改权威状态。原生 respond/cancel/save 仍检查主窗口身份。
- 历史操作由原生生成 requestId，通过 owner 返回 ACK；失败/超时必须保留可解释错误，不能把“事件已发出”视为删除成功。
- 原生传输成功回执仅在响应实际写入后完成；它不证明供应商已经执行批准的动作。正常成功关闭不应作为异常 ended 抢先覆盖前端成功确认。
- JavaScript VM 不能证明 Windows WebView 重载回调时机、Named Pipe 实际断连、页面崩溃重建、多进程文件竞争或真实设置窗口视觉行为。根代理需补充原生单元/进程往返和 Windows 实机证据。
- 重载时主动取消旧 pending 的方案应验证：旧客户端立即释放；旧按钮不可提交；ended 只影响原 transportRequestId；重载空窗中的新事件进入启动队列；旧 owner 的迟到保存被拒绝。

本文记录本轮复核结果，不表示完整 Windows 客户端或全部 Agent 已完成验收。
