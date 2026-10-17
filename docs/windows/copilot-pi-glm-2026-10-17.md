# Windows Copilot CLI、Pi 与模型筛选

## 目标与方案

用户授权“提交，然后继续补齐 Windows/Mac 功能并独立验证”。先将已验证的0.1.7提交为 `3bef203`，再完成本批；未推送或发布。

本批选择 Copilot CLI 和 Pi 的独立原生接口，加上 Mac 已有的 GLM 筛选/模型搜索。保留当前安全安装器和状态机结构：Copilot用独立JSON，Pi用自动发现的扩展文件；不把所有客户端套成Claude格式。Amp需要单独验证Bun插件宿主，暂留后续。GLM是模型筛选，不新增虚假的GLM客户端。

## 可验证目标

1. Copilot CLI：12类camelCase事件，固定`--hook`注入事件上下文；notification允许官方`hook_event_name: Notification`例外。Windows PowerShell命令为空输出、中性退出；权限/问答保留原端。
2. Copilot安装：默认`.copilot/hooks/xisland.json`，支持用户目录内COPILOT_HOME；保留用户字段和其他handlers，精确移除自有项，独立文件仅在全部自有内容移除后删除。
3. Pi：8类原生扩展事件，只有agent_settled判空闲；新会话/切换会话身份独立，model.id保留。默认`.pi/agent/extensions/xisland.ts`，支持用户目录内PI_CODING_AGENT_DIR；整个生成文件被编辑后拒绝覆盖。
4. 两个安装计划绑定配置内容、实际路径、Node与hook路径，过期计划不跨目录写入；主窗口实际接纳活动后才记录接通证据。
5. 模型筛选：按Mac的256 UTF-8字节和严格GLM名称规则判断；搜索加入模型名，保持客户端身份和已有状态筛选；匹配子会话不会因父项不匹配而消失，筛选后不出现不匹配子项。
6. 验证分层：适配器/安装器→实际打包hook子进程→浏览器→官方Pi CLI隔离场景→Windows交叉构建/独立解包。Windows实机保持独立待验。

## 已定位并修正的边界

- Copilot原生输入没有稳定toolCallId。若直接制造tool_start，状态机会错误配对并发同名工具。本批preToolUse只报告准备状态，postToolUse记录独立结果；回归先失败后修复。该处比Mac旧实现更保守。
- Pi初版计划只哈希文件内容，两个尚不存在的配置路径会共享revision。独立复核复现后，改为同时绑定路径和运行时，补跨目录/Node/hook资源切换回归。
- 同样复现并修复了已有 OpenCode/Kimi 的跨目录旧计划问题；四类自定义目录安装器的对外 revision 均绑定目标与运行时，内部文件身份与内容 CAS 保持原有检查。
- 静态检测可能不认识自定义客户端安装位置。仅本次协调器生命周期内、非未来的有效新活动可以覆盖未检测提示，仍经过配置、运行时及Codex信任检查；自动写入的检测门槛不降低。
- 模型筛选沿用过滤后的父子集合，循环父子关系保守退到顶层；不改变原始会话记录。筛选栏参与展开高度计算，空结果和多个客户端首屏可见。

## 合同来源与真实验证范围

- [GitHub Copilot CLI hooks](https://docs.github.com/en/copilot/reference/hooks-reference)：与VS Code Copilot协议分开，Windows载体为powershell，timeoutSec为秒。
- [Pi官方扩展API](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)、[配置目录](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md)、[Windows支持](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/windows.md)。固定核对当前官方 `@earendil-works/pi-coding-agent@1.3.0`，MIT，CLI为dist/bundle/cli.js，Node>=22.19.0。没有复制第三方源码或新增项目依赖。
- 官方Pi已在macOS隔离运行自动发现扩展、实际read工具、RPC new_session；仅使用localhost确定性模型，不覆盖HOME/CODEX_HOME，不继承真实凭据。配置/认证/信任/扩展目录由官方PI_CODING_AGENT_DIR与专用flags隔离。
- Pi官方CLI第二个RPC会话会重复发一次session_start；源码确认这是rebindSession行为，完整保留后不会重复创建会话。具体说明和复跑见 `evidence/pi-native-integration-2026-10-17.md`。
- Copilot CLI尚未执行真实客户端；Pi的Windows原生安装、PowerShell、Rust Named Pipe和桌面UI仍待另一台Windows电脑。本机真实CLI和临时Node桥不能替代Windows验收。

原有0.1.6/0.1.7产物及证据保留；本轮仅提交Windows子项目和对应文档，工作区同期Mac修改归其原任务。

## 最终验证与交付：0.1.8

- 455 项 TypeScript、36 项浏览器、34 项 Rust 单元及 1 项独立进程 IPC 通过；类型检查、前端/hook构建、Windows MSVC目标检查和NSIS构建通过。
- 实际安装器内hook CJS再次在官方Pi 1.3.0执行RPC双会话（4次本地模型请求、17条事件、两次read）并进入真实SessionStore；OpenCode 1.19.3允许/拒绝/三题3场景也通过。两份报告的脚本SHA与独立解包的同一个CJS完全一致。模型localhost、transport为Node替身，Windows/Rust/UI仍未因此验收。
- 安装器独立核对9个文件、Windows x64 PE及Node官方固定SHA。174个构建输入与当前源码一致，ZIP 7条目CRC和manifest哈希通过。
- 压缩包：`.build/XIsland-Windows-0.1.8-preview-test-kit.zip`，26452592字节，SHA-256 `7ef5d69302ac3229477e37c3ac023022b5282e99a9a2587e97d9e20d7be4bd40`。
- 机器摘要：`evidence/copilot-pi-glm-2026-10-17.json`；包内脚本原生证据：`evidence/pi-packaged-hook-0.1.8.json`、`evidence/opencode-native-packaged-hook-0.1.8.json`。

本批代码按用户本轮提交授权纳入Git，不推送或发布。Mac并行工作不在本批提交范围。其余Agent路线、静音规则/声音包、历史导入、SSH、配额和更新功能仍在后续清单；完整目标未完成。
