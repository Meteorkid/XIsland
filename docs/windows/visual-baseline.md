# XIsland Windows 视觉与交互基准

审计日期：2026-10-13。源码基准：`90fdc0af202a86cabe94d59c6f1328314bf55cee` 的当前工作区；以下行号为审计时文件行号。本文只记录 macOS 已有实现与 Windows 验收目标，未运行 Windows 应用，也未完成跨平台截图比较。

## 证据边界

- **代码事实**：尺寸、颜色配方、状态分支、交互规则以当前源码为准。SwiftUI 的 `point` 在 Windows 首先映射到逻辑像素/DIP；不能把截图的物理像素直接当作逻辑尺寸。
- **截图观察**：本次查看了仓库内五张已有 PNG，只确认其中可见的外观；截图没有版本、系统缩放、主题配置与完整输入记录，不是当前源码的渲染验收证据。
- **Windows 验收目标**：本文最后的容差与场景是移植验证标准，不代表已通过，也不是 macOS 源码中的断言。
- 顶层当前入口是 `NotchContentView → SessionListView → PendingTaskCardView`。`PermissionApprovalView`、`QuestionAnswerView` 中仍有独立整页组件，但当前主面板不直接调用它们；不要把旧独立组件的布局当成当前用户界面。[NotchContentView.swift:743](../../Sources/DynamicIsland/Views/NotchContentView.swift#L743)

## 外形、尺寸与布局

| 项目 | 当前代码事实 | 依据 |
|---|---|---|
| 收起主条 | 默认宽 **261.34**，主条高 **38.77**；用户设置 `islandWidth/islandHeight > 0` 时覆盖。现行 `pillWidth` 不随会话数或刘海遮挡改变 | [IslandSizeCalculator.swift:5](../../Sources/DynamicIsland/Views/IslandSizeCalculator.swift#L5)、[同文件:13](../../Sources/DynamicIsland/Views/IslandSizeCalculator.swift#L13) |
| 收起 ticker | 默认开启。外形总高为 `主条高 + 18 + 4`，即 **60.77**；ticker 字号 10 medium、可用宽 `shapeWidth−28`，其 y 偏移实际是 `主条高−8` | [NotchContentView.swift:59](../../Sources/DynamicIsland/Views/NotchContentView.swift#L59)、[同文件:72](../../Sources/DynamicIsland/Views/NotchContentView.swift#L72)、[同文件:618](../../Sources/DynamicIsland/Views/NotchContentView.swift#L618) |
| 展开宽度 | 默认 **380**；权限、问答、计划审核与普通展开用相同面板宽度 | [NotchContentView.swift:59](../../Sources/DynamicIsland/Views/NotchContentView.swift#L59)、[IslandSizeCalculator.swift:33](../../Sources/DynamicIsland/Views/IslandSizeCalculator.swift#L33) |
| 展开高度 | `48 + min(N × 80 + 30, 620) + 16`；活动日志打开再加 **140**。N 是 visibleSessions 数，不是 DOM 卡片测量值。N=0/1/3 时分别为 94/174/334，基础上限 684。内容溢出靠列表滚动处理 | [IslandSizeCalculator.swift:40](../../Sources/DynamicIsland/Views/IslandSizeCalculator.swift#L40) |
| 顶边和圆角 | **所有状态顶角均为 0**，贴屏幕顶边；底角按展开进度从 17 到 22 插值。进度模型下限是 **32**，并非主条默认高 38.77；因此默认收起底角未必恰为 17 | [NotchShapeGeometry.swift:8](../../Sources/DynamicIsland/Models/NotchShapeGeometry.swift#L8)、[同文件:24](../../Sources/DynamicIsland/Models/NotchShapeGeometry.swift#L24) |
| 外壳描边/阴影 | 描边宽 **0.5**；悬停时描边透明度加 0.15。阴影半径 `10+10p`、y=`3+p`，透明度随 p 增加 0.02；p 为展开进度 | [NotchContentView.swift:396](../../Sources/DynamicIsland/Views/NotchContentView.swift#L396) |
| 工具栏 | 48 高的预算；左右内边距 16、上下 10。左侧声音/设置各 28×28、图标 13 semibold；右侧状态文字 10 medium、关闭触区 24×24 / 图标 16 | [NotchContentView.swift:858](../../Sources/DynamicIsland/Views/NotchContentView.swift#L858) |
| 普通会话列表 | 卡片间距 10、列表左右 12、上 8、下 12。卡片圆角 14，描边 0.5；内容左右 14，标题上边距 12 | [SessionListView.swift:48](../../Sources/DynamicIsland/Views/SessionListView.swift#L48)、[同文件:123](../../Sources/DynamicIsland/Views/SessionListView.swift#L123)、[同文件:229](../../Sources/DynamicIsland/Views/SessionListView.swift#L229) |
| 待处理卡片 | 内边距 12，纵向主间距 12，圆角 10、描边 0.5；同一会话可同时展示权限、问答、计划区域 | [PendingTaskCardView.swift:12](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L12) |
| 窗口外框 | 原生窗口与可见外壳不是同一个尺寸。展开容器有 8 的 padding，窗口额外向屏幕上方延伸 6；收起专用 resize 去掉左右 padding。不能据 `maxExpandedWidth=520/maxExpandedHeight=600` 两个常量推断实际可见尺寸 | [NotchWindow.swift:7](../../Sources/DynamicIsland/NotchWindow.swift#L7)、[同文件:259](../../Sources/DynamicIsland/NotchWindow.swift#L259)、[同文件:282](../../Sources/DynamicIsland/NotchWindow.swift#L282)、[同文件:496](../../Sources/DynamicIsland/NotchWindow.swift#L496) |

计算出的高度是代码目标值，仍须渲染确认 Agent Flow、长待办和 ticker 与窗口裁切的最终效果；不能把纯计算结果宣称为截图测量结果。

## 颜色与字体

颜色配方见 [IslandStyle.swift:7](../../Sources/DynamicIsland/Views/IslandStyle.swift#L7)。表中的灰度是源码值；十六进制只对明确的 RGB 数值按 8 位近似转换。`.primary/.secondary/.cyan` 等是系统语义色，不能从名称虚构精确 RGB。

| Token | 深色 | 浅色 |
|---|---|---|
| surface | 黑色 `#000000` | gray 0.965，约 `#F6F6F6` |
| card rest / hover | 白色 6% / 10% | gray 0.91 / 0.87，约 `#E8E8E8` / `#DEDEDE` |
| inset fill | 白色 6% | gray 0.89，约 `#E3E3E3` |
| code well | 白色 5% | gray 0.88，约 `#E0E0E0` |
| card stroke | 白色 8%，悬停 14% | gray 0.75，100% |
| shell stroke | 白色 14% | gray 0.75，100% |
| tertiary text | 白色 35% | 黑色 40% |
| divider | 白色 8% | gray 0.78，100% |
| shadow | 白色 4% 起 | 黑色 8% 起 |
| accent | `.cyan` | `.blue` |

默认主题是 **dark**；支持 dark/light/system，并持久化选择。system 模式观察系统外观，改变 `NSApp.appearance`，主窗口同步外观。[ThemeManager.swift:31](../../Sources/DynamicIsland/Managers/ThemeManager.swift#L31)、[同文件:50](../../Sources/DynamicIsland/Managers/ThemeManager.swift#L50)、[同文件:95](../../Sources/DynamicIsland/Managers/ThemeManager.swift#L95)、[AppDelegate.swift:258](../../Sources/DynamicIsland/AppDelegate.swift#L258)

Agent 品牌色与状态色分离：Claude RGB(0.85,0.45,0.25)，Codex (0.2,0.8,0.4)，Cursor (0.6,0.4,0.9)，Gemini (0.3,0.5,0.95)。状态 active=cyan、idle=green、thinking=purple、等待权限/回答/计划=orange、completed/观测不可用/完成未确认=gray、error=red、compacting=yellow。[AgentRegistry.swift:17](../../Sources/DynamicIsland/Models/AgentRegistry.swift#L17)、[AgentSession.swift:48](../../Sources/DynamicIsland/Models/AgentSession.swift#L48)

字体以系统字体为主，不指定固定字体家族。Windows 应先保持字号、字重、行高层次，再以实际渲染校准字面宽度；不能承诺系统字体栅格跨平台逐像素一致。

| 层次 | 代码设定 | 依据 |
|---|---|---|
| 普通会话标题 / 工作区 | 12 semibold / 10 regular；标题一行 | [SessionListView.swift:285](../../Sources/DynamicIsland/Views/SessionListView.swift#L285) |
| 用户摘要 / 当前工具 | 11 regular，最多两行 / 10 medium | [SessionListView.swift:138](../../Sources/DynamicIsland/Views/SessionListView.swift#L138) |
| 时间 | 9 medium，数值转场；内边距 6×2、圆角 4 | [SessionListView.swift:305](../../Sources/DynamicIsland/Views/SessionListView.swift#L305) |
| 收起计数 | 紧凑数字 10 semibold rounded、标签 9 medium；非紧凑 13/10；数字等宽 | [CollapsedPillView.swift:209](../../Sources/DynamicIsland/Views/CollapsedPillView.swift#L209) |
| 待办标题 / 路径 | 12 semibold、最多两行 / 10 regular、路径中间截断 | [PendingTaskCardView.swift:14](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L14) |
| 权限描述与详情 | 11 monospaced；路径预览 10 monospaced | [PendingTaskCardView.swift:69](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L69) |
| 问题 / 选项 / 决策按钮 | 12 regular / 11 medium / 11 semibold | [PendingTaskCardView.swift:146](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L146)、[同文件:312](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L312) |

图标应保留 XIsland 自己的表情轮廓和品牌/状态双重着色：收起 AgentIcon 为 22，普通卡片 24，待办 20；底板圆角 `size×0.3`，品牌色 20% 填充，状态色 60% / 1.5 边框。尺寸 >=20 默认展示 MascotView；不是直接放厂商 logo。[AgentIcon.swift:28](../../Sources/DynamicIsland/Views/Components/AgentIcon.swift#L28)、[CollapsedPillView.swift:96](../../Sources/DynamicIsland/Views/CollapsedPillView.swift#L96)

## 动效与节奏

默认动画强度和果冻强度均为 medium。[IslandAnimationIntensity.swift:8](../../Sources/DynamicIsland/Models/IslandAnimationIntensity.swift#L8)、[IslandJellyIntensity.swift:8](../../Sources/DynamicIsland/Models/IslandJellyIntensity.swift#L8)

| 动效 | low / medium / high，或默认值 | 代码依据 |
|---|---|---|
| 展开 spring response / damping | 0.28/0.92；**0.40/0.82**；0.50/0.74 | [NotchContentView.swift:251](../../Sources/DynamicIsland/Views/NotchContentView.swift#L251) |
| 收起 spring response / damping | 0.24/0.90；**0.35/0.80**；0.44/0.72 | [同文件:262](../../Sources/DynamicIsland/Views/NotchContentView.swift#L262) |
| 内容淡入淡出 | easeInOut 0.14 / **0.20** / 0.28 秒 | [同文件:273](../../Sources/DynamicIsland/Views/NotchContentView.swift#L273) |
| 展开起始延迟 / 内容揭示延迟 / 收起窗口完成延迟 | 0.02/0.08/0.28；**0.05/0.12/0.45**；0.07/0.16/0.55 秒 | [同文件:229](../../Sources/DynamicIsland/Views/NotchContentView.swift#L229) |
| medium 果冻缩放 | pop x=0.94/y=1.25；settle x=0.98/y=1.08；pop spring 0.5/0.3；0.15 秒后 settle spring 0.45/0.4 | [同文件:183](../../Sources/DynamicIsland/Views/NotchContentView.swift#L183)、[同文件:1093](../../Sources/DynamicIsland/Views/NotchContentView.swift#L1093) |
| 磁吸 | 距离 <80，水平方向最多 8；实际公式 `dx×(1−distance/80)×0.15`，展开/收起进行中为零 | [同文件:204](../../Sources/DynamicIsland/Views/NotchContentView.swift#L204) |
| 卡片 | hover easeInOut 0.15 秒；列表数量/分组 0.2 秒；进入从右、移出向左，合并透明度 | [SessionListView.swift:16](../../Sources/DynamicIsland/Views/SessionListView.swift#L16)、[同文件:86](../../Sources/DynamicIsland/Views/SessionListView.swift#L86)、[同文件:247](../../Sources/DynamicIsland/Views/SessionListView.swift#L247) |
| AgentIcon 光环 | active/thinking/compacting 才有，1.5 秒 easeInOut 往复；减少动态效果时关闭 | [AgentIcon.swift:24](../../Sources/DynamicIsland/Views/Components/AgentIcon.swift#L24) |
| 收起计数 | active / total 每 5 秒切换，预留字宽避免布局抖动；减少动态效果也保留低频数字刷新 | [CollapsedPillView.swift:36](../../Sources/DynamicIsland/Views/CollapsedPillView.swift#L36)、[同文件:188](../../Sources/DynamicIsland/Views/CollapsedPillView.swift#L188) |
| ticker | 默认速度 25 逻辑单位/秒；仅溢出可用宽 >4 时滚动；周期头停 1.2 秒，首轮额外 0.3 秒偏移 | [NotchContentView.swift:63](../../Sources/DynamicIsland/Views/NotchContentView.swift#L63)、[MarqueeText.swift:91](../../Sources/DynamicIsland/Views/MarqueeText.swift#L91) |

展开先扩大原生容器，再延迟启动外壳弹簧，最后显现内容；收起先动画外壳/内容，再延迟缩小原生窗口，防止中途裁切。内容不可见时关闭命中与无障碍可见性。[NotchContentView.swift:432](../../Sources/DynamicIsland/Views/NotchContentView.swift#L432)、[同文件:631](../../Sources/DynamicIsland/Views/NotchContentView.swift#L631)、[同文件:678](../../Sources/DynamicIsland/Views/NotchContentView.swift#L678)

`disableAnimations` 使过渡延迟为零；reduce motion 将离散状态过渡降为 low，并关闭持续动效/磁吸/果冻。不要把“减少动态效果”误实现为不更新状态。[NotchContentView.swift:42](../../Sources/DynamicIsland/Views/NotchContentView.swift#L42)、[同文件:171](../../Sources/DynamicIsland/Views/NotchContentView.swift#L171)、[同文件:1121](../../Sources/DynamicIsland/Views/NotchContentView.swift#L1121)

## 主要状态与操作

### 收起

- 默认走无物理刘海遮挡布局：按 visibleSessions 顺序展示最多 5 个 AgentIcon，溢出显示 `+N`，右侧为启用的计数、额度、安静时段与 bypass 标识；左右边距 14。真实刘海遮挡时才改用左右分区。[CollapsedPillView.swift:66](../../Sources/DynamicIsland/Views/CollapsedPillView.swift#L66)、[同文件:96](../../Sources/DynamicIsland/Views/CollapsedPillView.swift#L96)
- 点击展开；hover-to-expand 默认 false；精确滚动下滑展开默认 true、阈值 deltaY>2。刚收起后 0.65 秒禁止鼠标立即重开。智能抑制默认 true，已聚焦 Agent 终端时抑制 hover 展开。[AppDelegate.swift:104](../../Sources/DynamicIsland/AppDelegate.swift#L104)、[NotchWindow.swift:32](../../Sources/DynamicIsland/NotchWindow.swift#L32)、[NotchContentView.swift:1133](../../Sources/DynamicIsland/Views/NotchContentView.swift#L1133)

### 普通展开

- 工具栏 → Agent Flow 项目区域 → 待处理会话置顶 + 普通会话列表 → 可选活动日志 → 可选额度。普通卡片排除已经展示在待处理区域的会话，防止重复。[NotchContentView.swift:743](../../Sources/DynamicIsland/Views/NotchContentView.swift#L743)、[SessionListView.swift:48](../../Sources/DynamicIsland/Views/SessionListView.swift#L48)、[同文件:97](../../Sources/DynamicIsland/Views/SessionListView.swift#L97)
- Agent Flow 无阻塞时显示正向空状态，有阻塞时按项目展示可展开卡片；项目卡片圆角 10，内容区间距 6。[AgentFlowView.swift:26](../../Sources/DynamicIsland/Views/AgentFlowView.swift#L26)、[同文件:76](../../Sources/DynamicIsland/Views/AgentFlowView.swift#L76)、[同文件:147](../../Sources/DynamicIsland/Views/AgentFlowView.swift#L147)
- 会话卡片主区域跳转到所属终端/编辑器；摘要和子 Agent 展开是独立操作；hover 才显现移除按钮。点击跳转后保持面板打开。[SessionListView.swift:123](../../Sources/DynamicIsland/Views/SessionListView.swift#L123)、[同文件:197](../../Sources/DynamicIsland/Views/SessionListView.swift#L197)、[同文件:321](../../Sources/DynamicIsland/Views/SessionListView.swift#L321)、[NotchContentView.swift:760](../../Sources/DynamicIsland/Views/NotchContentView.swift#L760)
- 普通展开默认无操作 10 秒收起；hover 展开/空面板的离开规则使用 0.5 秒设置。**存在受保护交互时不自动收起**。[NotchContentView.swift:51](../../Sources/DynamicIsland/Views/NotchContentView.swift#L51)、[同文件:1008](../../Sources/DynamicIsland/Views/NotchContentView.swift#L1008)、[同文件:1160](../../Sources/DynamicIsland/Views/NotchContentView.swift#L1160)

### 权限、问答、计划审核

- 三类交互状态仍共用 SessionListView；不再替换成单独整页。在专用交互状态隐藏 Agent Flow 区域，有阻塞时工具栏可返回总览。[NotchContentView.swift:747](../../Sources/DynamicIsland/Views/NotchContentView.swift#L747)、[同文件:906](../../Sources/DynamicIsland/Views/NotchContentView.swift#L906)
- 权限：橙色标题，工具名称、三行等宽描述、路径中截断；展开详情为 200 高双向滚动区，含完整描述/路径/diff；红色拒绝和绿色允许等宽并排，最小高 32、圆角 6、色填充 22%。[PendingTaskCardView.swift:69](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L69)、[同文件:312](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L312)
- 问答：蓝色标题，问题区域最大高 100；单选选项间距 6、最小高 30、圆角 6、选项区最大 200；允许自由回答时附输入框；多选使用选择集加明确发送按钮。空/不可回答载荷显示不可用说明与跳转入口。[PendingTaskCardView.swift:146](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L146)、[MultipleQuestionInputView.swift:11](../../Sources/DynamicIsland/Views/MultipleQuestionInputView.swift#L11)、[CustomQuestionInputView.swift:11](../../Sources/DynamicIsland/Views/CustomQuestionInputView.swift#L11)
- 计划：紫色标题，收起预览五行；展开 Markdown 区高 200；反馈输入两到四行，红/绿决策按钮。每项请求按 request ID 保存展开/草稿，切换会话不得串稿。[PendingTaskCardView.swift:216](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L216)
- 发送中、已发送、失败必须有反馈；不能在点击瞬间伪装成成功。不可提交时按钮禁用且 50% 透明，失败提供回原 Agent 入口。[PendingTaskCardView.swift:312](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L312)、[同文件:334](../../Sources/DynamicIsland/Views/PendingTaskCardView.swift#L334)

### 设置与历史

- 设置是**独立 760×520 窗口**，使用系统 windowBackgroundColor；不是浮岛里的大弹出菜单。顶部八项横排：通用、显示、集成、Agents、声音、历史、统计、关于。按钮 72×44，图标 16、标签 10；主体滚动区域左右 24、上下 18。[PreferencesView.swift:5](../../Sources/DynamicIsland/Views/PreferencesView.swift#L5)、[同文件:108](../../Sources/DynamicIsland/Views/PreferencesView.swift#L108)、[同文件:146](../../Sources/DynamicIsland/Views/PreferencesView.swift#L146)
- 历史入口是设置的 History pane：保存错误与重试、保留天数 7/14/30/90/永不、空状态或会话行、单项删除、批量导出、清空。会话标题 13 medium；Agent、时长、结束/观测终止时间 11。[PreferencesView.swift:864](../../Sources/DynamicIsland/Views/PreferencesView.swift#L864)、[同文件:891](../../Sources/DynamicIsland/Views/PreferencesView.swift#L891)
- `ChatHistoryView` 定义了用户右/Agent 左的气泡布局（正文 11、圆角 10、用户最多三行/Agent 十行），但本次检索 `Sources` 未发现其构造调用；不可据这个文件宣称当前主界面已有可打开的完整聊天历史面板。[ChatHistoryView.swift:11](../../Sources/DynamicIsland/Views/ChatHistoryView.swift#L11)

## 焦点、显示器与窗口行为

- macOS 使用无边框、透明、nonactivating NSPanel，level=`statusBar+1`，可成为 key、不可成为 main；窗口本身没有系统阴影。悬停通知展示不应主动抢走用户当前输入焦点，输入框应可显式获得键盘焦点。[NotchWindow.swift:95](../../Sources/DynamicIsland/NotchWindow.swift#L95)、[同文件:672](../../Sources/DynamicIsland/NotchWindow.swift#L672)
- 默认跟随鼠标所在显示器，0.5 秒检测一次。拖动时不自动重排；横向拖动超过 4 才算拖动，保持顶部贴边，记录水平中心、钳制到屏幕内。[NotchWindow.swift:133](../../Sources/DynamicIsland/NotchWindow.swift#L133)、[同文件:500](../../Sources/DynamicIsland/NotchWindow.swift#L500)
- 权限/问答/计划到来时选择**当前前台应用窗口所在屏幕**并 pin；优先前台窗口重叠屏幕、其次主屏、最后鼠标屏。等待回答期间 resize/鼠标移动不得把岛拽到另一块屏幕；收起完成才解除 pin。[NotchWindow.swift:353](../../Sources/DynamicIsland/NotchWindow.swift#L353)、[同文件:586](../../Sources/DynamicIsland/NotchWindow.swift#L586)、[同文件:311](../../Sources/DynamicIsland/NotchWindow.swift#L311)、[AppDelegate.swift:257](../../Sources/DynamicIsland/AppDelegate.swift#L257)
- `showOnAllSpaces` 默认 true；`hideInFullscreen` 默认 false。全屏隐藏是用户配置，不能把 Windows 的始终隐藏当成还原；显示器连接/断开后需重定位、继续保证位置有效。[NotchWindow.swift:185](../../Sources/DynamicIsland/NotchWindow.swift#L185)、[同文件:481](../../Sources/DynamicIsland/NotchWindow.swift#L481)、[PreferencesView.swift:63](../../Sources/DynamicIsland/Views/PreferencesView.swift#L63)
- 设置窗口属于显式打开，会激活应用并成为 key；失去焦点不隐藏。该行为与浮岛自动弹出区分。[AppDelegate.swift:588](../../Sources/DynamicIsland/AppDelegate.swift#L588)
- Windows 的 DPI、任务栏、虚拟桌面、点击穿透和焦点 API 实现并不由 macOS 源码证明；需要原生 Windows 验收。不要仅用浏览器预览通过来替代这些行为证据。

## 已查看截图与差异

| 文件 | 图片物理尺寸 | 本次可见观察 | 对当前基准的限制 |
|---|---|---|---|
| [external-collapsed.png](../../Assets/screenshots/external-collapsed.png) | 600×80 | 黑色顶部条、四个彩色表情图标、底部圆角 | 没有当前默认计数/额度/ticker，不能作为当前完整收起布局 |
| [external-expanded.png](../../Assets/screenshots/external-expanded.png) | 920×440 | 黑色外壳、细灰描边、深灰卡片、音量/齿轮/关闭、彩色 Agent 标签 | 图中外壳顶部圆角明显；当前代码顶角为 0。底部截图被裁，不能测量完整面板高度 |
| [external-question.png](../../Assets/screenshots/external-question.png) | 920×500 | 蓝色 Question 标签、深灰长选项行、明亮正文、Cmd 数字提示 | 是独立问答页；当前入口已经改为待办卡片内联置顶，不能照搬页面结构/快捷键标记 |
| [notch-expanded.png](../../Assets/screenshots/notch-expanded.png) | 1120×470 | 三张会话卡片、品牌色表情、工作区副标题和时间标签 | 顶部形状与当前代码同样有差异；未提供缩放倍率 |
| [notch-collapsed.png](../../Assets/screenshots/notch-collapsed.png) | 200×35 | 仅能看到菜单栏文字裁片 | 不能作为可辨识的当前收起外观证据 |

未在本次查看截图中确认浅色主题、当前内联权限/问答/计划、当前设置或历史界面。它们的基准目前来自源码，后续要用同一数据夹具生成新的 macOS 截图后再比较。

## Windows 高保真验收标准（待执行）

1. **建立成对快照**：固定同一会话夹具、语言、主题、尺寸设置、动画静止时刻；输出 macOS 与 Windows 同状态截图。记录 commit、分辨率、OS 缩放、应用 zoom、窗口边界。浏览器截图单独标记为前端预览。
2. **基础几何**：100% Windows 缩放时，以逻辑像素比对上述外壳/卡片/间距，关键边缘误差 ≤1 DIP；125/150/200% 不出现超出 1 物理像素的顶边缝、内容裁切、模糊图标或错位命中。字体抗锯齿单独记录，不混作布局偏差。
3. **完整状态集**：收起空态/1/5/6+ 会话，ticker 开关，展开空态/3/10 会话，Agent Flow 无阻塞/多项目，active/thinking/idle/compacting/error/completed/观测未确认；深色/浅色/跟随系统全部覆盖。
4. **交互卡片**：长命令/长路径/diff，单选/多选/自由回答，计划展开/反馈，多会话同时待办；sending/sent/failed，外部已处理；内容完整可读、可滚动，禁用态明确，草稿不串会话，请求不重复提交。
5. **动效**：录制展开/收起/hover 果冻/卡片过渡；默认节奏按上表调校，内容显现顺序和原生窗口 resize 顺序一致；连续开关不闪白、不提前裁切、不丢点击。reduce motion 无持续循环；disable animations 立即切换。
6. **真实窗口行为**：自动事件不夺取终端键盘焦点；点击输入框后可用中文输入法；手动设置正常获取焦点；透明区域不挡住别的窗口。不同 DPI 双屏、负坐标屏幕、拔屏、锁屏/唤醒、全屏开关、前台终端换屏都须实机记录。
7. **设置与历史**：760×520 内容层次、横向八项工具栏、滚动长设置、主题切换立即生效、历史空态/有记录/保存失败；持久化重启后恢复。尚未实现的集成能力应显示真实状态，不能用永远成功的装饰按钮充数。
8. **验收陈述**：分别汇报「源码参数已对齐」「前端固定夹具渲染已比较」「Windows 原生窗口已验证」「真实 Agent 往返已验证」。不得用其中一项代称其他三项。

本次完成的是静态代码与已有图片审计；以上八项 Windows 验收均未在本审计中执行。

## Windows 前端首轮实现记录

同日完成 `windows/src/ui/` 的前端实现，并在 macOS 主机的真实 Chrome 浏览器运行 `npx playwright test --config playwright.config.ts`：**8 项通过**。覆盖收起/展开尺寸、搜索与主题、权限允许、中文自由回答、计划详情/反馈、多选、发送失败、重复触发、等待平台确认、IME 组合输入期间状态更新，以及 IME 期间断连后阻止失效请求发送。`npm run check` 与 `npm run build` 也通过。测试源为 [ui.spec.ts](../../windows/tests/ui.spec.ts)，未连接真实 Agent。

最终前端截图已实际打开查看：

- [收起深色](evidence/ui-collapsed-dark.png)、[展开深色](evidence/ui-expanded-dark.png)、[权限请求](evidence/ui-permission-dark.png)。
- [中文自定义回答](evidence/ui-question-chinese.png)、[计划反馈](evidence/ui-plan-feedback.png)、[多选回传失败](evidence/ui-multiple-response-failed.png)、[浅色设置](evidence/ui-settings-light.png)。

`ui-permission-before-qa.png` 与 `ui-plan-before-qa.png` 是修复前证据，不能作为最终界面展示。

首轮实现与 macOS 基准的明确差异：

1. 机械照搬单会话高度 174 会把审批按钮截在首屏之外，浏览器检查实际发现了这个问题。Windows 待办按内容计算所需高度，上限 620；空态最低 174；普通展开仍沿用会话数量公式。展开长计划后批准/修改按钮已在首屏可见。
2. 设置暂时把同一个宿主窗口调整为 760×520，返回时恢复灵动岛；尚未实现 macOS 的独立设置窗口。会话详情提供可读的活动与对话记录，是 Windows 新增可见入口，不能倒推 macOS 已有该入口。
3. 持续脉冲、ticker、渐变尺寸过渡和减少动态效果已实现；SwiftUI spring 的精准轨迹、磁吸和果冻仍需后续对照调校，当前 CSS 过渡不宣称等价。
4. 跟随显示器与全屏隐藏由 `IslandPlatform.capabilities` 决定是否可操作；未接入时开关禁用并标注未接入。集成页目前是连接规则说明，不是假装成功的 Hook 配置器。统计仅使用 Agent 已上报用量，不推算余额。
5. 系统语义色在 Windows CSS 使用独立近似值；目前验证了视觉层次与主题切换，尚未生成当前 macOS 夹具截图做成对像素差分。

上述结果证明浏览器前端行为；不证明 Windows 原生焦点、多屏/DPI、安装包、真实中文输入法候选窗口或真实 Agent 协议已验收。IME 测试是浏览器组合事件回归测试，并未操作 Windows 输入法。

## 2026-10-14：语言、动效与独立设置入口

本轮在原有 UI 上补齐可实际操作的设置；以下更新覆盖首轮记录中相应的“尚未实现”项，其余待验边界仍保留。

- **语言**：`i18n.ts` 集中维护中文、英语、日语、韩语、法语文案及动态计数模板；默认跟随系统，按浏览器语言列表匹配受支持语言，无匹配回落英语。切换立即生效并持久化，时间与数字使用当前 locale。Agent 提示、回答、命令和错误原文不做隐式翻译。
- **设置窗口路由**：主岛存在 `platform.openSettings` 时请求原生独立窗口，不改变主岛尺寸；`preferencesWindow` 使用固定 760×520 内容，关闭按钮和 Escape 请求关闭设置窗口。设置变化先等待平台保存成功，再更新本地状态。`applySettings` 只应用广播，不反向再次保存。历史删除/清空可回调给会话 owner；设置副本不处理审批快捷键、不重复播报新待办。
- **动效参数**：`motion.ts` 使用基准中的 low/medium/high response、damping、start/reveal/finish 延迟；通过阻尼振子采样形成 Web Animations keyframes。果冻采用 weak/medium/strong 的精确 x/y pop/settle 比例，150 ms 后进入 settle；磁吸使用 80 范围与最大 8 的约束以及相同的距离公式。
- **减少动态效果**：应用或系统减少动效时使用 low 的离散过渡，关闭持续脉冲/ticker、果冻和磁吸；“关闭所有动画”让尺寸与状态立即切换，状态数字仍更新。设置都经过枚举/数值校验并持久化。

验证：新增 **6 项设置/语言/动效纯逻辑测试**通过；累计 **15 项 Chrome 浏览器测试**通过，含五语言即时切换与刷新后恢复、系统日语匹配、原生设置路由替身、广播不回写、保存失败回退、实际 scale/translate 动画、减少动效、关闭动画和原有审批/IME回归。浏览器测试中的独立窗口路由使用平台替身；不代表已验证 Win32 窗口的实际生命周期。

已打开查看的新截图：[英语设置](evidence/ui-settings-english.png)、[英语展开面板](evidence/ui-expanded-english.png)、[日语设置](evidence/ui-settings-japanese.png)、[韩语设置](evidence/ui-settings-korean.png)、[法语设置](evidence/ui-settings-french.png)、[动效强度设置](evidence/ui-motion-settings.png)。固定 760×520 下各语言标签无越界，长设置内容由主体滚动。

剩余视觉证据边界：阻尼公式和参数已对齐，但未与 SwiftUI 当前真实帧序列进行时间轴对比，不能称为完全相同的 spring。原生窗口须检查 yPop 放大时底部是否被 WebView 容器裁切，并检查透明余量的点击穿透。磁吸只使用 WebView 能收到的指针坐标；跨原生窗口边界的可观察范围仍需 Windows 实机确认。翻译已人工编写并做布局检查，未经过五种语言各自的母语审校。
