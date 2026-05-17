# Changelog

## v1.5.0 (2026-05-17)

### 代码质量优化

- **SessionManager 重构**: 消除 `startSession`/`findOrCreateSession`/`findOrCreateSessionForInteraction` 三处重复的 session 查找/创建级联逻辑，提取统一的 optional chaining 模式
- **NotchContentView 拆分**: 提取 `IslandSizeCalculator` 统一高度/宽度计算逻辑（消除 3 处重复计算）
- **AudioEngine 非阻塞化**: `playFile` 和 `playToneSequence` 从 `Thread.sleep` 阻塞改为 `AVAudioPlayerNode` 回调，新音效事件不再被长音效阻塞
- **NotchWindow 性能优化**: `setFrame`/`setFrameDirect` 中缓存 `bestScreen()` 结果，仅在鼠标跨越屏幕边界时刷新

### 测试覆盖提升

- 新增 **L10n 测试** (10 个): 语言切换、availableLanguages、静态字符串完整性、参数化字符串
- 新增 **MuteRule 测试** (10 个): 正则匹配、禁用规则、空模式、无效正则、大小写不敏感、Codable 序列化
- 新增 **AgentSession 测试** (15 个): workspaceName、displayTitle、formattedDuration、isSubagent、TokenUsage 格式化
- 新增 **AudioEngine 测试** (12 个): 静音状态、音量持久化、事件开关、定时勿扰、静音规则 JSON 持久化
- 新增 **AgentType 测试** (10 个): from() 解析、fromBundleId、Meta 属性完整性、Registry 完整性、Codable
- 测试总数: 125 → 192 (+67)

## v1.4.0 (2026-05-16)

### 新增 Agent 支持

- **Aider**: 完整支持，通过索引信号文件接入
- **Kiro**: 完整支持，通过 Spec hook 接入
- **CodeBuddy**: 完整支持，通过配置 hook 接入
- **Droid (Factory)**: 基础支持

### 新功能

- **面板尺寸自定义**: 偏好设置中可调整面板宽度 (320-600px) 和最大高度 (320-700px)，步长 20px
- **定时勿扰 (Quiet Hours)**: 基于时间的自动静音，支持跨午夜区间 (如 22:00-07:00)，状态栏显示 moon 图标
- **右键上下文菜单**: 收起状态右键可快速静音/取消静音、打开偏好设置、退出；展开状态增加关闭所有会话选项
- **Session 回顾总结 (Recap)**: 已完成的 session 显示可展开/收起的 AI 生成摘要，最多 5 行
- **自定义静音规则 (Mute Rules)**: 基于正则表达式的静音规则，可按 Agent 类型、工具名或工作目录匹配事件
- **Bypass/自动模式**: 自动批准所有权限请求、问题回答和计划审查，状态栏显示闪电图标
- **Subagent 嵌套可视化**: 子 Agent session 左侧 2px 紫色竖线 + 24px 缩进，父卡片底部可展开/收起子 Agent 列表
- **L10n 多语言完善**: 所有新增 UI 字符串接入五语系统 (中/韩/日/法/英)，偏好设置中新增语言手动切换器
- **VS Code 扩展**: 支持从灵动岛直接跳转到 VS Code 终端标签页

### 修复与改进

- 修复 Kiro/Gemini/Droid/CodeBuddy 假 Hook 问题，全部实现真实 di-bridge 调用
- AgentType/AgentMeta 数据驱动注册表重构，消除 SessionManager 中的 switch 重复
- 内聚性重构：SessionManager 代码从 ~1200 行缩减，逻辑归位到 Manager/Model 方法中

### 技术变更

- `DIMessageType.recap` 新增 recap 消息类型
- `DIMessage.recapText` 字段
- `AgentSession.recapText`、`AgentSession.isSubagent`、`AgentSession.subagentIds`、`AgentSession.terminal`
- `AudioEngine.isMuted` 改为计算属性 (手动 mute || quiet hours)
- `AudioEngine.play(_:session:)` 新增 session 参数做静音规则匹配
- `SessionManager.bypassMode` 自动批准逻辑
- 新建 `MuteRule.swift` 数据模型
- 125 XCTest 测试全部通过，0 失败
