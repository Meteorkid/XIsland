中文 | [English](README.md)

<p align="center">
  <img src="Assets/app-icon.png" width="128" alt="X Island">
</p>

<h1 align="center">X Island</h1>

<p align="center">
  一款 macOS 灵动岛风格的 AI 编程助手控制塔。<br>
  在屏幕顶部的浮动面板中，统一监控 Claude Code、Cursor、Codex、OpenCode、Gemini CLI 等多个 AI Agent。
</p>

## 演示

<p align="center">
  <img src="Assets/demo.gif" width="560" alt="X Island 演示">
</p>

| 收起（刘海屏） | 收起（外接屏） | 展开状态 | 问题回答 |
|:---------:|:---------:|:-------:|:-------:|
| <img src="Assets/screenshots/notch-collapsed.png" width="220" alt="刘海屏收起"> | <img src="Assets/screenshots/external-collapsed.png" width="220" alt="外接屏收起"> | <img src="Assets/screenshots/notch-expanded.png" width="220" alt="展开状态"> | <img src="Assets/screenshots/notch-question.png" width="220" alt="问题回答"> |

## 功能介绍

X Island 以一个紧凑的药丸形状悬浮在屏幕顶部。当 AI Agent 工作时，它会实时显示状态。鼠标悬停即可展开，查看所有活跃会话的详细信息。

**核心功能：**

- **统一面板** — 在一个地方查看所有 AI 编程助手的状态，无论它们运行在哪个终端或 IDE 中
- **实时状态** — 状态指示灯（蓝色 = 工作中，绿色 = 已完成，橙色 = 等待输入，红色 = 出错）
- **权限审批** — 直接在灵动岛中批准或拒绝文件/命令权限，无需切换窗口
- **问题回答** — 在灵动岛中直接回答 Agent 提出的问题
- **计划审查** — 内联审查和批准 Agent 的执行计划
- **音效通知** — 8-bit 风格的音效提醒（可按事件类型单独配置）
- **多会话支持** — 同一 Agent 的多个对话窗口独立追踪
- **窗口跳转** — 点击会话卡片直接跳转到对应的终端标签页或 IDE 窗口（支持 iTerm2 标签级精确跳转）
- **水平拖动** — 可沿屏幕顶部左右拖动灵动岛位置
- **智能标题** — 显示首条用户提问作为标题，工作目录文件夹名作为副标题
- **多语言** — 支持简体中文、英文、韩文、日文、法文
- **配额追踪** — 查看 Kimi、DeepSeek、GLM API 的剩余额度
- **外接显示器** — 灵动岛自动跟随鼠标在屏幕间切换
- **流式思考展示** — Agent 推理时显示实时动画思考状态
- **活动日志** — 按时间线展示所有会话的工具调用记录
- **工具事件详情** — 每次工具调用的测试结果解析和行数统计
- **SSH 远程管理** — 在灵动岛中直接连接和监控远程服务器
- **面板尺寸自定义** — 可调整面板宽度和最大高度 (320–600/700 px)
- **定时勿扰** — 基于时间的自动静音，支持跨午夜时段
- **右键上下文菜单** — 快速访问静音、偏好设置、关闭所有会话、退出
- **Session 回顾** — 已完成的 session 显示可展开的 AI 生成摘要
- **自定义静音规则** — 基于正则表达式的静音规则，可匹配 Agent 类型、工具名或工作目录
- **Bypass/自动模式** — 自动批准所有权限、问题和计划审查
- **Subagent 嵌套可视化** — 子 Agent session 缩进显示，支持展开/收起
- **VS Code 扩展** — 从灵动岛直接跳转到终端标签页
- **语言手动切换** — 偏好设置中手动选择语言（自动检测 或 中/英/韩/日/法）

**支持的 AI Agent：**

| Agent | 接入方式 | 支持状态 |
|-------|---------|---------|
| Claude Code | 原生 hooks (settings.json) | 完整支持 |
| Cursor | Hooks API (hooks.json) | 完整支持 |
| Codex (OpenAI) | 原生 hooks | 完整支持 |
| Aider | 索引信号文件 | 完整支持 |
| OpenCode | JS 插件 | 完整支持 |
| GLM (智谱) | TOML hooks (config.toml) | 完整支持 |
| Kimi (月之暗面) | TOML hooks (config.toml) | 完整支持 |
| DeepSeek | TOML hooks (config.toml) | 完整支持 |
| Kiro | Spec hook | 完整支持 |
| CodeBuddy | 配置 hook | 完整支持 |
| Gemini CLI | 配置 hook | 基础支持 |
| Copilot (VS Code) | 配置 hook | 基础支持 |
| Droid (Factory) | 配置 hook | 基础支持 |

## 安装

### 方式一：下载 DMG 安装（推荐）

1. 前往 [Releases](https://github.com/Meteorkid/XIsland/releases) 下载最新的 `.dmg` 文件
2. 打开 DMG，将 **X Island** 拖入应用程序文件夹
3. 启动 X Island

> **macOS 安全提示：** 由于应用未经 Apple 开发者签名，首次打开时 macOS 会拦截。解除方法：
>
> ```bash
> xattr -cr /Applications/X\ Island.app
> ```
>
> 或者：**系统设置 → 隐私与安全性 → 下滑找到 X Island 的提示 → 点击「仍要打开」**

### CLI 升级

X Island 会安装一个配套命令行工具到 `~/.xisland/bin/xisland`。

如果这个目录已经加入 `PATH`，你可以直接通过 GitHub Releases 升级：

```bash
xisland upgrade
```

前提：
- 已安装并登录 `gh`
- X Island 已安装在 `/Applications/X Island.app`

如果提示找不到 `xisland`，可以把下面这行加入 shell 配置：

```bash
export PATH="$HOME/.xisland/bin:$PATH"
```

执行 `bash Scripts/build.sh` 后，也会根据你当前使用的 shell，提示应该把这行配置写到哪个文件里。

### 方式二：从源码构建

**环境要求：** macOS 14.0+、Swift 5.9+

```bash
git clone https://github.com/Meteorkid/XIsland.git
cd xisland
bash Scripts/build.sh
open ".build/X Island.app"
```

### Agent 配置

X Island 在首次启动时会**自动配置**所有已检测到的 Agent 的 hook。无需手动设置。

如需验证或手动配置：
- 打开 X Island 设置（齿轮图标或菜单栏）
- 进入 **Agents** 标签页
- 按需开启/关闭各 Agent

底层原理：安装一个轻量的 bridge 可执行文件（`di-bridge`）到 `~/.xisland/bin/`，并在各 Agent 的配置文件中注册 hook。
同一个目录下也会安装 `xisland` 命令，用于直接升级应用。

## 架构

```
┌─────────────────────────────────────────────────┐
│                X Island App                      │
│                                                  │
│   NotchWindow (NSPanel)                          │
│   ├── CollapsedPillView (状态指示)                │
│   └── 展开视图                                    │
│       ├── SessionListView (会话卡片)              │
│       ├── PermissionApprovalView (权限审批)        │
│       ├── QuestionAnswerView (问题回答)            │
│       └── PlanReviewView (计划审查)                │
│                                                  │
│   SessionManager ← Unix Socket ← di-bridge      │
│   AudioEngine (8-bit 音效合成)                    │
│   ZeroConfigManager (自动配置 Agent)              │
└─────────────────────────────────────────────────┘

Agent hook 触发 → di-bridge 编码消息 → Unix Socket → SessionManager
```

**核心组件：**

- **`XIsland`** — 主应用。SwiftUI 视图托管在 `NSPanel` 中，实现浮动灵动岛 UI
- **`DIBridge`** — 轻量 CLI 工具，由 Agent hook 调用。读取 stdin JSON，编码为 `DIMessage`，通过 Unix Socket 发送
- **`DIShared`** — 共享协议定义（`DIMessage`、Socket 配置）

## 项目结构

```
Sources/
├── DIShared/          # 共享协议与 Socket 配置
│   └── Protocol.swift
├── DIBridge/          # Bridge CLI 工具
│   └── DIBridge.swift
└── DynamicIsland/     # 主应用
    ├── XIslandApp.swift
    ├── AppDelegate.swift
    ├── NotchWindow.swift
    ├── Models/
    │   ├── AgentSession.swift
    │   ├── AgentType.swift
    │   ├── ToolEvent.swift
    │   ├── MuteRule.swift
    │   └── QuotaInfo.swift
    ├── Managers/
    │   ├── SessionManager.swift
    │   ├── AudioEngine.swift
    │   ├── SocketServer.swift
    │   ├── ZeroConfigManager.swift
    │   ├── TerminalJumpManager.swift
    │   ├── UpdateManager.swift
    │   ├── AppUpdater.swift
    │   ├── L10n.swift
    │   ├── QuotaTracker.swift
    │   └── SSHRemoteManager.swift
    └── Views/
        ├── NotchContentView.swift
        ├── CollapsedPillView.swift
        ├── SessionListView.swift
        ├── ExpandedSessionView.swift
        ├── AgentActivityView.swift
        ├── PermissionApprovalView.swift
        ├── QuestionAnswerView.swift
        ├── PlanReviewView.swift
        └── PreferencesView.swift

Sources/XIslandUITestDriver/     # UI 测试驱动与场景运行器
Tests/
├── TowerIslandTests/            # 125 个 Swift XCTest 测试
├── Fixtures/                    # 测试数据
└── TestUtilities/               # 共享测试辅助

Scripts/
├── build.sh           # Release 构建 + .app 打包
├── test-all.sh        # 全量测试 (Swift + CLI)
├── test.sh            # 集成测试套件
├── package-dmg.sh     # DMG 打包
└── xisland            # CLI 辅助脚本
```

## 测试

项目包含 Swift XCTest 和 bash 集成测试两套体系：

```bash
# Swift 测试（125 个测试，无需运行 app）
swift test

# 全量 bash 集成测试（需 app 正在运行）
bash Scripts/test-all.sh

# 运行指定模块
bash Scripts/test.sh M1 M15 M17
```

建议启用本地 git hook 强制此流程：

```bash
bash Scripts/install-git-hooks.sh
```

安装后，每次 `git commit` 会自动执行 `bash Scripts/test-all.sh`。

测试模块覆盖：消息编码、会话生命周期、Agent 身份隔离、权限/问题/计划流程、多会话支持、完成音效去重、可配置保留时长等。

## 设置选项

所有设置可在 X Island 设置面板中调整：

| 设置项 | 默认值 | 说明 |
|--------|-------|------|
| 语言 | 自动 | 手动选择语言（自动/中文/English/한국어/日本語/Français） |
| 自动模式 | 关闭 | 自动批准所有权限、问题和计划审查 |
| 自动收起延迟 | 3 秒 | 交互完成后面板保持展开的时间 |
| 完成会话显示 | 2 分钟 | 已完成的会话保留多久（10秒–5分钟或永不消失） |
| 智能抑制 | 开启 | Agent 终端聚焦时不自动展开 |
| 面板宽度 | 420px | 展开时的面板宽度（320–600，步长 20） |
| 面板最大高度 | 480px | 面板列表最大高度（320–700，步长 20） |
| 声音 | 开启 | 总声音开关 |
| 音量 | 1.0 | 音效音量滑动条 |
| 定时勿扰 | 关闭 | 基于时间的自动静音，可设置起止时间 |
| 静音规则 | 无 | 基于正则表达式的按事件静音规则 |
| 事件音效 | 按事件 | 可单独开关每种事件的音效 |

## 工作原理

1. **零配置启动**：启动时自动扫描已安装的 Agent，在其配置文件中注入轻量 hook
2. **Hook → Bridge → Socket**：Agent 事件触发（工具调用、权限请求、任务完成）时，hook 调用 `di-bridge`，通过 Unix Socket 发送结构化消息
3. **实时 UI**：主应用通过 `SocketServer` 接收消息，更新 `SessionManager`，SwiftUI 视图即时响应
4. **交互响应**：权限和问题场景下，bridge 进程保持存活等待用户响应，然后将结果写回 stdout 供 Agent 消费

## 许可证

MIT
