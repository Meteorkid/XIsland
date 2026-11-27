# Engineering Loop Backlog

完成任务后把对应项改为 `[x]`，并在 `STATE.md` 写入结果。不要一次做多个。

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

## G8 — 收口与质量报告

- [ ] 跑最终 `python3 Scripts/check-docs.py`、目标测试和 `swift build -c release --product XIsland -j 2`。
- [ ] 汇总 8 轮提交、测试结果、未完成项和风险；把 `STATE.md` 的 `status` 设为 `complete`。不做发布。
