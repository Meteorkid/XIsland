# Engineering Loop State

- started_at: 2026-11-28T01:09:29+08:00
- planned_iterations: 8
- completed_iterations: 4
- next_iteration: 5
- status: active
- branch: codex/release-2.0.19
- last_iteration: 4
- last_task: G4 文档检查器的负向测试
- last_check: `python3 Scripts/check-docs.py` 通过（108 个 Markdown 文件）；`python3 Scripts/test-check-docs.py` 通过临时 fixture 的基线、缺失链接、未闭合围栏、缺失发行说明章节和仓库正常路径；`docs.yml` YAML 校验通过。
- next_task: G5 发布说明与校验和一致性
- notes: G4 给 `check-docs.py` 增加 `--root` 和 `check_documentation(root)`，临时 fixture 走非 git 的回退扫描；仓库正常检查仍走 `git ls-files`，输出和 108 文件结果不变。后续轮次不得推送、打 tag 或发布。
