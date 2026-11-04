# 未来待办：需资金投入后启动（B 类）

> **状态：暂不实现。** 2026-11-04 用户决策：先把 A 类（系统通知、全局热键、推送、不打扰、生命周期、诊断导出、防休眠）做完；B 类等产生收入后再启动。
>
> 归类标准：凡需要付费账号 / 证书 / 真机 / 外部服务 / 新平台团队，或需要长周期人工验收的项，都放这里。**这不是"Someday"的托词，而是资金与设备的前置门槛**，见每项的「启动条件」。

## 一、直接需要花钱的项

| 编号 | 事项 | 为什么需要钱 | 启动条件 |
|---|---|---|---|
| B1 | Developer ID 签名 + 公证 + staple + EdDSA 更新签名 | Apple Developer Program 会员年费（约 ¥688/年，**以 Apple 官网当期价格为准**）；需生成 Developer ID 证书并配置 CI secrets | 购买会员 → 导入 P12 → 跑通 `docs/releases/signing-checklist.md` 全流程 → 验证 Gatekeeper 首启 |
| B3 | iOS 伴端深度（Live Activity / 锁屏 / StandBy / 表盘 complication / 配对确认 / 后台保活） | 真 iPhone + Apple Watch、Widget/ActivityKit extension、APNs 或推送服务；上架还需同 B1 的会员 | **先跑通现有 Mac ⇄ iPhone ⇄ Watch 真机链路**，再做配对确认，最后做 Live Activity |
| B7 | App Store 沙箱版本（`NSOpenPanel` + security-scoped bookmark） | 同 B1 会员；且沙箱下 hook 安装能力需重新设计 | B1 完成 + 确认沙箱版功能裁剪清单 |
| B4 | 远程 SSH 完整方案（远端自举 bridge + socket 转发 + 心跳自愈 + 用量回传） | 需要一台 Linux 主机做长期联调（自有机器或云主机月费） | 有稳定测试主机 + 明确远程开发用户占比 |
| B6 | Windows / Linux 客户端成熟度与安装包签名 | Windows 代码签名证书（按年付费）、CI 构建机时长、多发行格式维护 | 有 Windows 用户基数后再投入 |

## 二、主要成本是人工时间而非现金

| 编号 | 事项 | 现状 | 启动条件 |
|---|---|---|---|
| B2 | 客户端真实端到端验收 | 矩阵 31 项 `complete` 全为 `false`；`docs/compatibility/README.md:115` 明确「当前没有任何一项达到完整验收层级」 | **建议不要 31 项全铺**：先把 Claude Code + Codex 两项做到完整验收，其余按用户反馈排序 |
| B9 | UITests、覆盖率门禁、16 语言 | 224 个测试文件 / 1931 项通过、双 CI；无 UITests、无覆盖率门禁 | 有 CI 时间预算；新增文案目前只覆盖简中/英（见 A 类实现说明） |
| B8 | 外部主题 JSON / 插件 bundle / 插件市场 | 有内置主题选择器，无插件系统 | 有插件作者生态或明确需求；需先设计插件沙箱与签名 |

## 三、需要新平台团队才能持续维护

| 编号 | 事项 | 现状 | 启动条件 |
|---|---|---|---|
| B5 | Android / Wear OS 伴端 + 外网 E2EE 中继 | 无 `android/` 目录；伴端仅 macOS + iOS + watchOS 源码 | 有 Android 开发能力 + Google Play 账号 + Cloudflare Worker/域名；**对当前单人 macOS 工具定位价值最低** |

## 启动顺序建议（等资金到位后）

1. **B1 签名公证** —— 分发硬门槛，收益最直接，且与收入正相关（用户敢装才可能付费）。
2. **B2 两项完整验收** —— 让「支持 31 种客户端」这句宣称变得可验证。
3. **B3 真机链路 → 配对确认 → Live Activity** —— 严格按此顺序，跳过前两步会返工。
4. 其余按实际用户反馈排序，不要按竞品清单逐项追。

> 维持不变的前提：A 类新增能力默认全部关闭，B 类未启动期间不影响现有功能与测试。
