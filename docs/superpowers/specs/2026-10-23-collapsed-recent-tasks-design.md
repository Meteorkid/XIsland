# 收起态最近任务数量

日期：2026-10-23。用户希望减少同时显示的吉祥物，并能调节最近任务数量。

## 行为

- “设置 → 显示 → 收起态模块”新增“最近任务数量”，可选 1–5，默认 3。
- 优先保留有实际授权、问答或计划审核请求的任务，其余按 `lastActivityTime` 从新到旧选择；相同活动时间再按创建时间、会话 ID 稳定排序。
- 普通布局最多横排 N 个图标，剩余任务沿用 `+M` 汇总；8 个任务、N=3 时显示 3 个图标、`+5`，总计仍为 8。
- 刘海遮挡布局只轮换这 N 个候选，保留现有状态优先轮换时长；减少动态效果时展示候选中的第一项。
- 展开列表、筛选、活跃／总数、待处理请求和历史数据不受显示数量影响。
- 关闭图标时禁用数量选择，重新开启后保留原值；越界偏好夹到 1–5，缺省为 3。

## 实现

新增 `CollapsedTaskSelection` 作为纯展示选择，不修改 `SessionManager.visibleSessions` 或会话数组。两个收起布局共用选择结果。偏好 `collapsedRecentTaskLimit` 使用现有 `AppStorage` 机制即时更新并持久化。设置复用现有分段控件和说明样式，补齐现有五种语言。

选择最近活动时间能让刚恢复工作的旧任务重新进入候选。仅有旧等待状态、没有实际待处理对象的任务不会长期占用位置。五个图标上限沿用原布局容量，默认三个减少拥挤。

## 验证

- 排序：乱序输入、旧任务恢复活动、同时间稳定顺序。
- 边界：空列表、单项、多项、1/3/5、负值／零／过大偏好。
- 交互：三种实际待处理请求优先、多待处理任务仍不超限、完整列表及计数不变。
- 渲染：两个布局、减少动态效果、1/3/5、关闭图标与完整总计。
- 设置：原生分段控件改变偏好、重新打开保留值、关闭图标禁用但不清空值。

运行相关测试：

```sh
X_ISLAND_RENDER_COLLAPSED_PILL=1 \
X_ISLAND_RENDER_COLLAPSED_PILL_DIR=.build/collapsed-recent-2026-10-22/green \
swift test --filter 'CollapsedTaskSelectionTests|CollapsedRecentTaskRenderTests|CollapsedTaskPreferencesTests|CollapsedPillViewTests|NotchContentViewTests|InteractionContentTests|PreferencesViewTests'
```

测试使用隔离偏好与测试窗口，不写入正式 App 的设置、数据库或客户端信任。

## 当前结果

实现完成，尚未提交或安装。全量 1,456 项：1,443 通过、13 项按条件跳过、0 失败；Release 构建通过。原生分段控件验证了选择、重新打开保持、禁用保留和越界回显；隔离渲染检查了 1/3/5 个图标及完整总计。原始日志、截图与源码 hash 位于 `.build/collapsed-recent-2026-10-22/`。动态轮换时长沿用既有实现，本轮未单独重新验收动画时序。
