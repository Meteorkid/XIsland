# Engineering Loop State

- started_at: 2026-11-28T01:09:29+08:00
- planned_iterations: 8
- completed_iterations: 5
- next_iteration: 6
- status: active
- branch: codex/release-2.0.19
- last_iteration: 5
- last_task: G5 发布说明与校验和一致性
- last_check: `python3 Scripts/check-docs.py` 通过（108 个 Markdown 文件）；`bash Scripts/test-preflight-release.sh` 通过 fixture 基线 + 5 条失败路径（版本不匹配、缺少 DMG、Cask/发行说明/SHA256SUMS 校验和漂移）；`bash Scripts/preflight-release.sh --require-dmg` 通过。
- next_task: G6 Swift 测试基线审计
- notes: G5 在 `preflight-release.sh` 增加 Cask 与 `SHA256SUMS.txt` 的直接交叉检查，并补齐三类校验和漂移回归；未修改 `VERSION`、Cask 或发布产物。后续轮次不得推送、打 tag 或发布。
