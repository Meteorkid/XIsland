# 竞品 UI 设计借鉴报告 · Sapphire & TO-DO Panel

> 调研对象：`cshariq/Sapphire`（Swift/SwiftUI，AGPL-3.0）与 `xiaopu-ai/TO-DO-Panel`（Electron，MIT）
> 目的：为 X Island 2.0.4 提取可移植的 UI / 交互设计手法
> 方法：浅克隆源码 + 设计文档阅读，逐项对照 X Island 现状评估移植成本
> 日期：2026-10-23

---

## 0. 结论速览

两个项目与 X Island **同品类**（Mac 刘海/灵动岛），但走了两条完全不同的路：

| | Sapphire | TO-DO Panel | X Island |
|---|---|---|---|
| 技术栈 | Swift + SwiftUI + AppKit | Electron + 原生 DOM | Swift + SwiftUI |
| 定位 | 刘海「活动中心」（音乐/日历/文件架） | 刘海「工作台」（待办/剪贴/应用坞） | AI 代理状态岛 |
| 强项 | **几何形态 + 物理动效 + 触觉** | **设计令牌系统 + 交互微反馈** | 代理会话状态编排 |
| 最值得学 | 自定义 Shape 布尔并集、弹簧求解器、触觉反馈 | Motion System v2 令牌、距离感应 Dock、图标描边动效 | — |

**三条最高价值借鉴**（按性价比排序）：

1. **触觉反馈**（Sapphire）— X Island **完全没有**，实现成本约 60 行，对刘海这种"盲操作"界面收益极大
2. **设计令牌单一取值表**（TO-DO Panel）— X Island 动效参数散落在 `NotchContentView.swift` 的 switch 里，应抽成令牌
3. **图标/微交互反馈**（TO-DO Panel）— hover 描边呼吸 + 点击回弹，让界面"活"起来

---

## 1. Sapphire：几何与物理

### 1.1 自定义 NotchShape —— 路径布尔并集

`Sapphire/Notch/CustomNotchShape.swift`（453 行）是全场技术含量最高的文件。

**核心手法**：刘海不是圆角矩形，而是**多个子路径的并集**。

```swift
// 主轮廓 + 卫星气泡 + 连接颈部，三者做并集
var path = mainPath(in: rect)
path = path.union(Circle().path(in: bubble))
if let neck { path = path.union(neck) }
```

它处理了三种形态：
- **有物理刘海**：顶部肩部用 `addQuadCurve` 做硬件肩线，底部圆角做安全裁剪（`safeBottomRadius` 同时受宽高约束）
- **无刘海**：`notchlessPath` 用苹果连续圆角的 7 段贝塞尔系数（`0.63149399`、`1.52866483`）手工复刻 squircle
- **浮动岛**：卡片与胶囊之间用 `islandNeck` 生成"颈部"，颈部宽度随分离距离做 `pow(1-s, 1.6)` 收窄，形成液桥感

**对 X Island 的价值**：X Island 目前用 `UnevenRoundedRectangle`（`NotchContentView.swift:400`），四角半径独立但**无法表达颈部与卫星**。如果将来要做「折叠胶囊与面板之间的过渡」或「状态徽章从岛体伸出」，这套并集思路是唯一可行解。

**移植成本**：中高。需要重写 `body` 里的形状层，且 `animatableData` 只支持双参数插值——Sapphire 靠 `NotchMorphEngine` 自己驱动才绕开这个限制。

### 1.2 NotchMorphEngine —— 手写弹簧求解器

`NotchMorphEngine.swift`（786 行）不依赖 SwiftUI 动画系统，自己实现了：

- **固定步长弹簧积分**：`NotchMorphSpringStepper`，120Hz 步进，与显示刷新解耦
- **多段动画合成**：`NotchMorphChannel` 支持动画排队（`entries` 数组），新目标不打断旧动画而是"承接当前速度"继续（`relativeState` 取当前 position/velocity 作为新动画初值）
- **时序表烘焙**：`NotchMorphTimeline` 把弹簧采样成关键帧数组，交给 `CAKeyframeAnimation` 用 GPU 播放，避免逐帧 CPU 计算
- **自动判定结束**：`settleBound` 连续 60 步判定为静止才收尾，防止视觉上的微抖

**对 X Island 的价值**：X Island 用 SwiftUI 原生 `.spring(response:dampingFraction:)`（`NotchContentView.swift:255-273`），已经分 low/medium/high 三档。**当前不必替换**——原生弹簧对单段动画足够。但当出现「展开途中用户又点了收起」这类**动画打断**场景时，SwiftUI 的表现是重新从头开始，而 Sapphire 会承接速度。这是体验差距的真实来源。

**建议**：暂不移植引擎，但可借鉴**思路**——在 `NotchContentView` 的展开/收起路径上记录 `generation`（该文件已有 `jellyGeneration` 模式），打断时保留当前进度。

### 1.3 触觉反馈 —— X Island 完全缺失

`HapticFeedbackType.swift`：

```swift
public enum HapticFeedbackType {
    case veryWeak, weak, medium, strong
    var actuationID: Int32 {  // 1 / 1 / 15 / 5
    var intensity: Float {    // 0.15 / 0.3 / 0.75 / 1.0
}
public final class HapticManager {
    public func perform(_ type: HapticFeedbackType) {
        HTKMultitouchActuator.shared().actuateActuationID(type.actuationID, intensity: type.intensity)
    }
}
```

使用点：`Helpers.swift:141`、`CalendarWidgetView.swift:116/138`。

**这是 X Island 最明显的空白**——全项目搜索 `NSHapticFeedback` / `HTKMultitouch` **零命中**。

为什么对 X Island 特别重要：刘海是**视线之外**的区域，用户手在触控板上、眼在别处。权限审批这种关键操作（`PermissionApprovalView`）如果只有视觉反馈，用户容易错过。触觉是唯一能"穿透"注意力的通道。

**推荐落点**：
- 权限审批卡片弹出 → `medium`
- 展开/收起 → `weak`（确认手势被识别）
- 切换会话 → `veryWeak`（轻量导航感）
- 操作失败/拒绝 → `strong`

**实现注意**：`HTKMultitouchActuator` 是私有 API（Sapphire 通过 `@_silgen_name` 或动态加载调用），**上架 App Store 会被拒**。X Island 若走 GitHub 分发则可用；更稳妥的是 `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)`——这是公开 API，强度档位少但零风险。

### 1.4 指针门控 —— 省电技巧

`PointerTrackingGate.swift`：展开态动画期间**移除所有 NSTrackingArea**（存入 `parked`），动画结束再装回。避免窗口尺寸变化时系统反复重算 hover 区域。

**对 X Island 的价值**：X Island 的展开动画期间（`expandSpring` 0.4s）同样存在窗口 resize，`NotchWindow` 里有 `mouseTrackingTimer`。这个门控思路可以降低动画期间的 CPU 占用。

### 1.5 显示器变化去抖

`NotchDisplayRefreshPolicy.swift`：显示器热插拔后不立即响应，而是**连续读取直到稳定**（`stabilityInterval: 0.3`，最多 6 次），再规划窗口迁移（`plan(windowDisplays:targets:)` 算出 move/destroy/create）。

**对 X Island 的价值**：`NotchWindow` 有 `lastActiveScreenID`、`pinnedScreenID`、`cachedBestScreen` 等多屏状态，但没有"读取稳定后再决策"这一层。外接显示器切换时可能出现瞬时错屏。

---

## 2. TO-DO Panel：令牌与微交互

### 2.1 设计令牌单一取值表 —— 最可直接照搬

`renderer/styles.css:1-140` 的 `:root` 是一份完整的令牌表，**并配有一条铁律**：

> NEVER 硬编码颜色/字号/间距，必须用 §1 的 CSS 变量。

令牌分六类：

```css
/* 颜色 —— 纯单色体系，仅两类例外 */
--bg-base: #000000;  --surface-1: #111111;  --surface-2: #191919;  --surface-3: #252525;
--hairline: rgba(255,255,255,0.08);   --highlight-top: rgba(255,255,255,0.07);
--text-1: #F5F5F5; --text-2: #A1A1A1; --text-3: #707070; --text-4: #4A4A4A;
--p0:#FF5F57; --p1:#FF9352; --p2:#30D978; --p3:#438CFF;   /* 唯一功能色 */

/* 圆角 —— 语义化命名 */
--r-notch:10px; --r-panel:16px; --r-tile:18px; --r-squircle:12px; --r-input:10px; --r-pill:999px;

/* 间距 —— 严格 8pt */
--s-1:4px; --s-2:8px; --s-3:12px; --s-4:16px; --s-5:20px; --s-6:24px;

/* 字号 —— 11 档，覆盖 9px~19px */
--fs-micro:9px; --fs-caption:10.5px; --fs-small:11px; --fs-ui:12px;
--fs-body:13px; --fs-heading-3:15px; --fs-heading-2:17px; --fs-heading-1:19px;

/* 动效 —— Motion System v2 */
--ease:        cubic-bezier(0.25, 0.46, 0.45, 0.94);  /* 日常 hover */
--ease-out:    cubic-bezier(0.16, 1, 0.3, 1);          /* 入场/退场，expo-out */
--ease-spring: cubic-bezier(0.34, 1.1, 0.4, 1);        /* 胶囊滑动/勾选 */
--ease-soft:   cubic-bezier(0.4, 0, 0.2, 1);           /* 窗口变形，无过冲 */
--d-micro:100ms; --d-1:90ms; --d-fast:140ms; --d-base:180ms; --d-slow:260ms; --d-grand:340ms;
```

**两条设计原则值得单独记下**：

1. **曲线按用途分工**，不是随手挑：`--ease-soft` 专给窗口尺寸变形，因为**它无过冲**——有过冲的曲线会让窗口边缘短暂露出裁切痕迹。`--ease-spring` 有轻微回弹，只给胶囊滑动和勾选这种"有实体感"的元素。
2. **时长注释里写明参考基准**：`--d-micro:100ms /* 对齐 Linear 0.1s */`。这让后人知道数值不是拍的。

**对 X Island 的现状差距**：X Island 的动效参数**硬编码在 switch 分支里**：

```swift
// NotchContentView.swift:255-283
private static func expandSpring(for intensity: IslandAnimationIntensity) -> Animation {
    switch intensity {
    case .low:    return .spring(response: 0.28, dampingFraction: 0.92)
    case .medium: return .spring(response: 0.4,  dampingFraction: 0.82)
    case .high:   return .spring(response: 0.5,  dampingFraction: 0.74)
    }
}
```

这不算错（有强度分级已比多数项目好），但**缺少跨视图的统一令牌**：`AnimationEffects.swift` 里的 `spring(response: 0.35, dampingFraction: 0.7)`、`0.3/0.7`，`NotchContentView.swift:1139` 的 `0.5/0.3`、`0.45/0.4` 都是散落的魔数，彼此无关联。

**建议**：新建 `IslandMotionTokens.swift`，把弹簧、时长、缓动集中定义，各视图引用。这样调参时改一处、全局一致。

### 2.2 距离感应 Dock —— 连续而非二值

`renderer/app.js:2984-3008`：

```javascript
function bindDockSurface(surface, selector, maxScale = 1.14) {
  surface.addEventListener('pointermove', (event) => {
    frame = requestAnimationFrame(() => {
      surface.querySelectorAll(selector).forEach((item) => {
        const rect = item.getBoundingClientRect();
        const distance = Math.hypot(event.clientX - centerX, event.clientY - centerY);
        const radius = Math.max(72, Math.min(150, rect.width * 2.2));
        const strength = Math.max(0, 1 - distance / radius) ** 2;   // 平方衰减
        item.style.setProperty('--dock-scale', (1 + (maxScale - 1) * strength).toFixed(3));
        item.style.setProperty('--dock-lift', `${(-5 * strength).toFixed(2)}px`);
        item.style.setProperty('--dock-glow', strength.toFixed(3));
      });
    });
  });
}
```

**关键点**：`strength = (1 - distance/radius)²`。**平方衰减**让中心响应强、边缘迅速归零，比线性插值自然得多。且**相邻元素也会被抬升**（因为遍历的是全部 item），形成 macOS Dock 的连续隆起曲线——不是"悬停的那个变大"，而是"一片区域被顶起"。

配合 CSS：
```css
.window-app-mark {
  transform: translateY(var(--dock-lift,0)) scale(var(--dock-scale,1));
  transform-origin: center bottom;
  filter: drop-shadow(0 calc(10px * var(--dock-glow)) calc(14px * var(--dock-glow)) rgba(0,0,0,.55));
  transition: transform 180ms var(--ease-spring), filter 180ms var(--ease);
}
```

**对 X Island 的价值**：X Island 的 `CollapsedPillView` 有 `isHoveringPill`（二值），`SessionListView` 的卡片 hover 也是二值切换。若改成距离感应，多个会话卡片会形成连续起伏，视觉档次明显提升。

**注意**：需要 `pointermove` 级别的频率，且用了 `requestAnimationFrame` 合并。SwiftUI 里对应 `onContinuousHover`，但要**避免每帧触发 `@State` 写入**（会引发整棵树重算），应改用 `GeometryEffect` 或直接操作 CALayer 的 transform。

### 2.3 图标描边呼吸 —— 零成本的高级感

`renderer/icon-motion.js` + CSS：

```javascript
// 给所有交互元素内的 SVG 描边路径加 pathLength="1"
shape.setAttribute('pathLength', '1');
```
```css
.motion-icon.motion-active .lucide-motion [pathLength='1'] {
  animation: lucide-path-breathe 420ms var(--ease-out);
}
@keyframes lucide-path-breathe {
  0%   { stroke-dasharray: .1 .9; stroke-dashoffset: .22; }
  100% { stroke-dasharray: 1 0;  stroke-dashoffset: 0;   }
}
```

**原理**：`pathLength="1"` 把任意长度路径归一化为 1，于是 `stroke-dasharray` 可以用百分比表达——`.1 .9` 表示"画 10%、空 90%"，动画到 `1 0` 即完整绘制。**效果是图标被"重新画一遍"**，而不是简单的透明度/缩放变化。

点击反馈：
```css
.motion-icon.motion-tap .lucide-motion { animation: motion-icon-tap 340ms var(--ease-out); }
@keyframes motion-icon-tap { 0%{scale:1} 42%{scale:.76} 100%{scale:1} }
```

**对 X Island 的价值**：X Island 用 SF Symbols（`Image(systemName:)`），原生支持 `.symbolEffect()`。但**部署目标是 macOS 14**（`Package.swift:6`），可用范围需区分：

| 效果 | 可用性 | 对应 TO-DO Panel 的 |
|---|---|---|
| `.bounce` | macOS 14 ✓ | `motion-icon-tap` |
| `.pulse` | macOS 14 ✓ | 呼吸感 |
| `.variableColor` | macOS 14 ✓ | 描边流动（近似 breathe） |
| `.scale` | macOS 14 ✓ | 缩放反馈 |
| `.drawOn` / `.wiggle` | **需 macOS 15** ✗ | 精确的 `lucide-path-breathe` |

也就是说 **`.drawOn` 那条"图标被重新画一遍"的效果当前用不了**，除非把部署目标提到 macOS 15（会砍掉一批用户）。可行的近似是 `.variableColor`——它让图标各层依次变色，流动方向感类似，但视觉机理不同（变色 vs 描边生长）。

X Island 目前**已有一处** `.symbolEffect(.bounce, ...)`（`NotchContentView.swift:1290`，用于工具事件完成），但 `.pulse` / `.variableColor` 未使用，`phaseAnimator` / `keyframeAnimator` 也是零使用。

**推荐落点**（全部 macOS 14 可用）：
- `CollapsedPillView` 状态图标 hover → `.variableColor.iterative` 近似描边流动
- 工具完成 → 已用 `.bounce`，可叠加 `.pulse` 增强
- 会话状态切换 → `.variableColor` 表达"状态在流转"
- 权限待处理 → `.pulse` 做持续但克制的提示（比现有 `ActiveSessionGlow` 的边框呼吸更省 GPU）

### 2.4 入场级联 —— 内容不是"出现"，是"依次落定"

设计文档 §1.5：

> 进入任一 Tab，`.home-bento>*` 依次 `riseIn`（上浮 12px 淡入，stagger 30/78/126/174ms，`backwards` 填充以免与 hover transform 冲突）

**关键细节是 `backwards` 填充**——延迟期间元素保持动画起始态（透明+位移），而不是先显示再跳。少了这个，级联会闪烁。

以及**只动 transform/opacity**（合成层），不动 layout 属性：
> 一切动效只用 transform/opacity（合成层）+ 必要的 width/height 补间；禁止动其它 layout 属性。

**对 X Island 的价值**：`ExpandedSessionView` 展开时内容整体 `opacity` 淡入（`NotchContentView.swift:672` 的 `contentFade.delay(timing.contentRevealDelay)`）。可以升级为**会话卡片依次上浮**，让"面板打开"更像一个物理过程。

### 2.5 窗口零动画铁律 —— 一条踩坑经验

设计文档 §10.x 记了一条实测结论：

> **窗口零动画铁律**：主进程 `setBounds` 一律瞬时（系统动画 resize 持续重绘 web 内容必卡）。平滑感全在渲染层。

以及配套的**方向性规则**：
> 切 Tab = `morphToTab`：**放大先变窗、缩小后变窗**，补间永远发生在"窗口足够大"的一侧，不露裁切。

**对 X Island 的价值**：X Island 的 `NotchWindow` 大量使用 `setFrame`。这两条经验直接适用：
1. `setFrame` 不要包在 `NSAnimationContext` 里，改由 SwiftUI 内容层做动画
2. 展开时先扩大窗口再让内容入场；收起时先让内容退场再缩窗口——否则会露出裁切边缘

### 2.6 显隐的原子事务 —— 架构级借鉴

`docs/adr/0002-home-widget-gapless-layout.md` 是一份高质量 ADR。核心决策：

> 显隐操作使用**同步、幂等的原子事务**：基于最新状态生成候选、求解并验证、释放必要资源、提交内存与 DOM、持久化、派发事件。已满足的绝对请求无副作用；**动画不参与提交，也不允许在提交前等待**。

以及一条明确的拒绝理由：
> **先淡出旧布局，再异步提交新状态** —— 拒绝。快速切换时多个操作会基于同一旧状态计算并互相覆盖，镜子和录音还会多出一个资源竞态窗口。

**对 X Island 的价值**：`PreferencesView` 里的开关（主题、动效强度、折叠态内容模式等）是否也走"先动画后落盘"？如果是，快速连点会出现状态覆盖。应改为**状态先同步提交，动画只做视觉追认**。

---

## 3. 落地建议（按优先级）

| 优先级 | 项目 | 来源 | 落点 | 成本 |
|---|---|---|---|---|
| **P1** | 触觉反馈 | Sapphire | 权限审批/展开收起/会话切换 | 低（~60 行） |
| **P1** | 动效令牌集中化 | TO-DO Panel | 新建 `IslandMotionTokens.swift` | 低（纯重构） |
| **P2** | SF Symbols 动效（macOS 14 子集） | TO-DO Panel | 状态图标 hover/点击/完成 | 低（API 调用） |
| **P2** | 窗口零动画 + 方向性变窗 | TO-DO Panel | `NotchWindow.setFrame` 调用点 | 中 |
| **P3** | 距离感应 hover | TO-DO Panel | `SessionListView` 卡片 | 中 |
| **P3** | 入场级联 | TO-DO Panel | `ExpandedSessionView` | 中 |
| **P4** | 自定义 NotchShape 并集 | Sapphire | 若要做颈部/卫星形态 | 高 |
| **P4** | 弹簧求解器 | Sapphire | 若要做动画打断承接 | 高 |

---

## 3. 移植时的三个前提

两个参考项目与 X Island 的运行时差异，决定了哪些手法能直接搬、哪些要换实现。

**① TO-DO Panel 是 Web 渲染，CSS 能做的事 SwiftUI 不一定能**

`transform: translateY() scale()` 配合 CSS 变量做逐元素连续插值，在 Web 里是零成本（浏览器合成层）。SwiftUI 里等价操作如果写成 `@State` + `withAnimation`，`pointermove` 每帧都会触发视图树重算，反而卡顿。

正确做法是**绕开 SwiftUI 的状态更新**：用 `.geometryEffect` 或直接操作 `CALayer.transform`。这也是 Sapphire 在 `NotchMorphEngine` 里选择自己驱动 `CADisplayLink` + `CATransaction.setDisableActions(true)` 的原因——**它刻意不让 SwiftUI 介入动画循环**。

**② 时间基准不同**

TO-DO Panel 的 `--d-base: 180ms` 是 CSS transition 时长，对应的曲线是预设贝塞尔。X Island 用 SwiftUI 弹簧（`response` + `dampingFraction`），**response 是"周期"不是"时长"**——`response: 0.4` 的实际视觉时长约 0.6~0.8s（取决于阻尼）。所以两边的数值**不能直接对照换算**，只能对照"感觉"。

迁移时应该以 X Island 现有三档强度（low/medium/high）为骨架，把 TO-DO Panel 的**曲线用途分工**（哪个场景该无过冲、哪个该有回弹）搬过来，而不是搬数字。

**③ Sapphire 的私有 API 需要降级方案**

见 §4。它调用的 `HTKMultitouchActuator` 是未公开框架。

---

## 4. 一处需要说明的取舍

Sapphire 的 `HTKMultitouchActuator` 是**私有 API**，通过 `HTKMultitouch` 框架直接调用触觉执行器，能精确控制 `actuationID` 与 `intensity`。效果比公开 API 细腻得多，但：

- 无法上架 Mac App Store
- 系统更新可能失效（需容错降级）

X Island 目前走 GitHub 分发（README 明确 ad-hoc 签名），**技术上可用**。但建议：

```swift
// 优先公开 API，私有 API 作为可选增强
if NSHapticFeedbackManager.defaultPerformer.responds(to: ...) { ... }
```

先上公开 API 版本（零风险，强度档位少但够用），若后续确认分发渠道稳定再考虑增强。这属于产品决策，需要你定。

---

## 附：调研文件索引

**Sapphire**（`/tmp/xi-ref/sapphire`）
- `Sapphire/Notch/CustomNotchShape.swift` — 453 行，路径并集、连续圆角系数
- `Sapphire/Notch/NotchMorphEngine.swift` — 786 行，弹簧求解器、时序烘焙
- `Sapphire/Notch/NotchExpressiveMotion.swift` — 转场与 hover 微交互
- `Sapphire/Notch/HapticFeedbackType.swift` — 触觉封装
- `Sapphire/Notch/PointerTrackingGate.swift` — 追踪区域门控
- `Sapphire/Notch/NotchDisplayRefreshPolicy.swift` — 显示器变化去抖
- `Sapphire/Utilities/LiquidGlassView.swift` — 877 行，15 种材质映射

**TO-DO Panel**（`/tmp/xi-ref/todo-panel`）
- `renderer/styles.css` — 5385 行，令牌表在 1-140 行
- `renderer/effects.js` — 552 行，WebGL 着色器（音乐可视化）
- `renderer/icon-motion.js` — 47 行，图标描边动效
- `renderer/app.js:2984-3008` — 距离感应 Dock
- `docs/DASHBOARD-DESIGN.md` — 设计规格，§11 为当前有效版本
- `docs/adr/0002-home-widget-gapless-layout.md` — 原子事务 ADR
