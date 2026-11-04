# A 类功能手工验收清单（约 6 分钟）

> 两种启动方式，按需要选：
> - **A. 部署 .app（推荐）**：双击启动，**系统通知也可测**。独立 bundle id `dev.xisland.app.debug`，不影响正式版的设置与授权。
> - **B. `swift run`（最快）**：无 bundle id，系统通知必然不生效，其余可测。
>
> 两者都只在 Debug 构建生效；Release 无法通过启动参数或环境变量获得免授权运行。

## 前置

1. **先退出正式版 X Island**（菜单栏 → 退出），避免单实例锁与岛切换通知互相干扰。
2. 选择一种方式启动：

```bash
# 方式 A：部署并启动（代码改动后加 --build 重新组装）
cd /Users/meteor/github/xisland
bash Scripts/package-debug-acceptance.sh --build
open "$HOME/Applications/X Island (Debug).app"

# 方式 B：直接跑（通知不可用）
swift run XIsland --acceptance-mode
```

## 0. 系统通知（仅方式 A，1.5 分钟）

1. 设置 → 通知与自动化 → 打开「发送系统通知」→ 系统弹授权框，选「允许」
2. 用 Claude Code 触发一次需要确认的命令，等通知弹出
3. 点通知上的 **Deny** → 终端里该请求应被拒绝（不是只把通知关掉）
4. 同一条通知再点一次 Deny → 第二次应无任何效果（防重放）
5. 回到设置，关闭「允许在通知里直接批准 / 拒绝」，重新触发一次 → 通知上应**没有** Allow/Deny，只有 Review

失败排查：`log show --last 3m --predicate 'process == "XIsland"' --style compact | tail -40`

## 1. 设置页可达（30 秒）

菜单栏图标 → 设置（或 ⌘,），左栏点「通知与自动化」。

- 通过：页面**可操作**（开关不是灰的），顶部没有「需要有效授权」提示
- 失败：整页灰色 → 方式 A 检查 Info.plist 的 `LSEnvironment`；方式 B 检查是否带了 `--acceptance-mode` 且没带 `--ui-test-mode`

## 2. 防休眠（1.5 分钟）

1. 模式选「有工作会话时」
2. 用 Claude Code 跑一个会产生会话的任务（或让已有会话保持运行）
3. 另开终端：

```bash
pmset -g assertions | grep -i "PreventUserIdleSystemSleep"
```

- 通过：出现包含 `X Island: active agent session` 的一行
- 4. 结束会话，等约 2 分钟再查 → 该行消失

排查：确认模式不是「关闭」；用 `pmset -g assertions` 全量输出搜 X Island。

## 3. 推送与诊断（1.5 分钟）

1. 「推送与 Webhook」→ 添加渠道 → 类型选 Webhook → 地址填 `https://httpbin.org/post` → 点「发送测试」
   - 通过：显示「测试成功 (200)」；断网时应显示失败，而不是假装成功
2. 地址改成 `not-a-url` → 测试 → 通过：提示配置无效
3. 「诊断导出」→ 导出到桌面 → 解压：
   - 通过：`manifest.txt` / `sessions.json` 里搜不到 `sk-`、邮箱、`/Users/你的用户名`
   - 通过：压缩包里没有渠道地址或附加标识

## 4. 不打扰与生命周期（1 分钟）

1. 静默目录填 `node_modules` → 用该目录下的会话触发完成 → 不应有提醒
2. 打开「30 分钟无活动自动隐藏」→ 观察列表；**待审批的会话不应消失**
3. 关闭这两个开关，恢复默认

## 收尾

退出验收实例（菜单栏 → 退出）。防休眠断言是进程级的，退出即释放。

通知权限以 `dev.xisland.app.debug` 身份注册，与正式版独立；不再需要时可在「系统设置 → 通知」里删除该条目。
