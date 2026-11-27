# Engineering Loop Backlog

完成任务后把对应项改为 `[x]`，并在 `STATE.md` 写入结果。不要一次做多个。

## G1 — 文档质量门禁（已完成）

- [x] 新增 `Scripts/check-docs.py`，检查 Markdown 围栏、仓库内相对链接、发行说明必需章节、VERSION/Cask 一致性和 LLM 提示覆盖。
- [x] 新增 `.github/workflows/docs.yml`，在 push / PR 上运行文档检查。

## G2 — 发布预检脚本

- [ ] 新增 `Scripts/preflight-release.sh`：只读检查 `VERSION`、Cask 版本、发行说明章节和 `SHA256SUMS.txt`；可选运行 `swift build -c release --product XIsland -j 2`。失败时非零退出，不发布、不修改文件。
- [ ] 用一个故意不匹配的临时版本测试失败路径；确认正常版本通过。

## G3 — ACP 配置强制转换硬化

- [ ] 检查 `Sources/DIShared/ACPCustomAgentConfiguration.swift` 的 `result["command"] as! String`；改为显式校验/安全转换，不改变合法输入行为。
- [ ] 在 `Tests/TowerIslandTests` 补 malformed / 非字符串 `command` 的回归测试，运行相关测试类。

## G4 — 文档检查器的负向测试

- [ ] 给 `Scripts/check-docs.py` 增加可注入根目录的参数或可测试函数；用临时 fixture 验证缺失链接、未闭合围栏、缺失发行说明章节会失败。
- [ ] 保留当前仓库的正常路径测试；CI 同时跑正负两条路径。

## G5 — 发布说明与校验和一致性

- [ ] 增加一个仓库内检查：`docs/releases/<VERSION>.md` 中的 DMG SHA256 与 `SHA256SUMS.txt` 一致（仅在文件存在时检查）；同时验证 Cask sha256 与校验和一致。
- [ ] 把检查接入 `docs.yml` 或现有测试脚本，避免发布时人工抄错。

## G6 — Swift 测试基线审计

- [ ] 运行一次完整的 `XIslandTests` 与 `MeteorLicenseCoreTests`，记录执行/跳过/失败、耗时和任何 flaky 现象。
- [ ] 若有失败，只修最小根因并补测试；若全绿，写一份 `docs/engineering-loop/test-baseline.md`，不修改运行时代码。

## G7 — 运行时风险扫描

- [ ] 扫描 `Sources/` 中的 `try!`、`as!`、`fatalError`，只挑一个可证明可失败的路径做安全化；没有可安全改动时记录原因并跳过。
- [ ] 任何代码改动必须有对应测试，禁止只做格式化或大范围重构。

## G8 — 收口与质量报告

- [ ] 跑最终 `python3 Scripts/check-docs.py`、目标测试和 `swift build -c release --product XIsland -j 2`。
- [ ] 汇总 8 轮提交、测试结果、未完成项和风险；把 `STATE.md` 的 `status` 设为 `complete`。不做发布。
