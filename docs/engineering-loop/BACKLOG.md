# Engineering Loop Backlog

完成任务后把对应项改为 `[x]`，并在 `STATE.md` 写入结果。不要一次做多个。

## Cycle 2 — G9–G16（已完成）

### G9 — Swift 运行时安全 token 门禁（已完成）

- [x] 新增 `Scripts/check-swift-safety.py`：扫描 `Sources/**/*.swift` 的 `try!`、`fatalError(`、`as!`；支持 `--root` 和 `swift-safety: allow` 同行豁免。仓库正常路径通过 267 个 Swift 文件。
- [x] 新增 `Scripts/test-check-swift-safety.py`：覆盖干净文件、`try!`、`fatalError`、`as!`、豁免标记和仓库正常路径。测试通过。

### G10 — 接入安全门禁 CI（已完成）

- [x] 在 `.github/workflows/docs.yml` 增加安全门禁及负向测试步骤。已加入 `check-swift-safety.py` 和 `test-check-swift-safety.py` 两个步骤。
- [x] 本地运行两个脚本，确认 workflow 引用路径和命令正确。YAML 可解析，6 条 CI 命令全部在本地通过。

### G11 — 循环控制面校验器（已完成）

- [x] 新增 `Scripts/check-loop-state.py`：校验 `STATE.md` 必需字段、`status`、`completed_iterations` / `next_iteration` / `cycle_end_iteration` 的一致性。覆盖字段缺失/重复、非法状态、轮次越界、计数器不一致和完成态收敛规则。
- [x] 新增 `Scripts/test-check-loop-state.py`：覆盖正常状态、缺字段、非法状态、越界轮次、计数器不一致、完成状态和仓库正常路径。全部通过。

### G12 — 接入循环状态 CI（已完成）

- [x] 在 `.github/workflows/docs.yml` 增加循环状态校验及负向测试步骤。已加入 `check-loop-state.py` 和 `test-check-loop-state.py`。
- [x] 本地运行确认。YAML 可解析，8 条 CI 命令全部在本地通过。

### G13 — 统一质量门禁入口（已完成）

- [x] 新增 `Scripts/run-quality-gates.sh`：串联文档检查、文档负向测试、Swift 安全门禁、安全门禁负向测试、循环状态检查、循环状态负向测试、发布预检及发布预检负向测试；`--build` 可选触发 release build。
- [x] 对脚本做 `bash -n` 和一次无构建运行，确认任一失败会非零退出。新增 `Scripts/test-run-quality-gates.sh`，覆盖正常仓库、完整 fixture 以及末端发布预检失败的非零传播。

### G14 — 强制解包审计（第二轮）（已完成）

- [x] 在 `Sources/` 继续扫描其他强制解包 / 崩溃路径，只挑一个可证明可失败的路径安全化；没有可安全改动时记录原因。选中 `DISocketConfig.socketDir` 的 `preconditionFailure`：非法测试目录会直接终止进程，现改为回退到独立临时目录。
- [x] 任何代码改动必须有对应测试，禁止大范围重构。新增 `testSocketDirectoryFallbackKeepsIsolationForInvalidTestPath`，`AppTestConfigurationTests` 18 项通过；release build 通过。

### G15 — Cycle 2 测试基线刷新（已完成）

- [x] 运行完整 `swift test -j 2`，记录执行/跳过/失败和耗时。结果：`XIslandTests` 2223 项/20 跳过/0 失败，`MeteorLicenseCoreTests` 31 项/1 跳过/0 失败，合计 2254 项/21 跳过/0 失败，墙钟 223.08 秒。
- [x] 更新 `docs/engineering-loop/test-baseline.md`，保留旧基线并标注新结果。Cycle 2 基线与历史 G6 基线分区记录。

### G16 — Cycle 2 收口与质量报告（已完成）

- [x] 跑最终文档检查、目标测试和 release build。统一质量门禁通过；目标测试 26 项、0 失败；release build 2.96 秒。
- [x] 汇总 Cycle 2 提交、测试结果、未完成项和风险；把 `STATE.md` 的 `status` 设为 `complete`。质量报告为 `docs/engineering-loop/quality-report-cycle2.md`。

## Cycle 1 — G1–G8（已完成）

## G1 — 文档质量门禁（已完成）

- [x] 新增 `Scripts/check-docs.py`，检查 Markdown 围栏、仓库内相对链接、发行说明必需章节、VERSION/Cask 一致性和 LLM 提示覆盖。
- [x] 新增 `.github/workflows/docs.yml`，在 push / PR 上运行文档检查。

## G2 — 发布预检脚本（已完成）

- [x] 新增 `Scripts/preflight-release.sh`：只读检查 `VERSION`、Cask 版本、发行说明章节和 `SHA256SUMS.txt`；可选运行 `swift build -c release --product XIsland -j 2`。失败时非零退出，不发布、不修改文件。
- [x] 用一个故意不匹配的临时版本测试失败路径；确认正常版本通过。新增 `Scripts/test-preflight-release.sh` 覆盖版本不匹配和缺少 DMG 两条失败路径，并接入 `docs.yml`。

## G3 — ACP 配置强制转换硬化（已完成）

- [x] 检查 `Sources/DIShared/ACPCustomAgentConfiguration.swift` 的 `result["command"] as! String`；改为显式校验/安全转换，不改变合法输入行为。
- [x] 在 `Tests/TowerIslandTests` 补 malformed / 非字符串 `command` 的回归测试，运行相关测试类。

## G4 — 文档检查器的负向测试（已完成）

- [x] 给 `Scripts/check-docs.py` 增加可注入根目录的参数或可测试函数；用临时 fixture 验证缺失链接、未闭合围栏、缺失发行说明章节会失败。
- [x] 保留当前仓库的正常路径测试；CI 同时跑正负两条路径。新增 `Scripts/test-check-docs.py` 并接入 `docs.yml`。

## G5 — 发布说明与校验和一致性（已完成）

- [x] 增加一个仓库内检查：`docs/releases/<VERSION>.md` 中的 DMG SHA256 与 `SHA256SUMS.txt` 一致（仅在文件存在时检查）；同时验证 Cask sha256 与校验和一致。`preflight-release.sh` 已覆盖这三项，并新增 Cask 对 `SHA256SUMS.txt` 的直接交叉检查。
- [x] 把检查接入 `docs.yml` 或现有测试脚本，避免发布时人工抄错。`test-preflight-release.sh` 增加 Cask、发行说明、`SHA256SUMS.txt` 三类校验和漂移失败路径，CI 已调用。

## G6 — Swift 测试基线审计（已完成）

- [x] 运行一次完整的 `XIslandTests` 与 `MeteorLicenseCoreTests`，记录执行/跳过/失败、耗时和任何 flaky 现象。结果：`XIslandTests` 2219 项、20 跳过、0 失败；`MeteorLicenseCoreTests` 31 项、1 跳过、0 失败；墙钟 208.54 秒。
- [x] 若有失败，只修最小根因并补测试；若全绿，写一份 `docs/engineering-loop/test-baseline.md`，不修改运行时代码。本次全绿，已写基线文档，未改运行时代码。

## G7 — 运行时风险扫描（已完成）

- [x] 扫描 `Sources/` 中的 `try!`、`as!`、`fatalError`，只挑一个可证明可失败的路径做安全化；没有可安全改动时记录原因并跳过。结果：将 `SSHInputValidator` 的 4 个静态 `try!` 正则改为可失败 `compilePattern()` + `nil` 时 fail-closed；`AXConversationFocus` 的 `as!` 有 CFTypeID 前置 guard，保留并记录原因；详见 `docs/engineering-loop/runtime-risk-scan.md`。
- [x] 任何代码改动必须有对应测试，禁止只做格式化或大范围重构。新增 3 项 SSH 校验测试，目标测试 8 项、全量 2253 项均 0 失败。

## G8 — 收口与质量报告（已完成）

- [x] 跑最终 `python3 Scripts/check-docs.py`、目标测试和 `swift build -c release --product XIsland -j 2`。结果：文档检查 110 个文件通过；全量测试 2253 项、21 跳过、0 失败；release build 通过。
- [x] 汇总 8 轮提交、测试结果、未完成项和风险；把 `STATE.md` 的 `status` 设为 `complete`。不做发布。质量报告为 `docs/engineering-loop/quality-report.md`。
