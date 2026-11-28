# X Island Engineering Loop

这是一个本地软件工程迭代循环。每个周期 8 轮，每轮只做一个可验证的小改动，测试通过后提交到当前分支；不发布、不打 tag、不推送。

## 每轮步骤

1. 工作目录固定为 `/Users/meteor/github/xisland`。先读 `docs/engineering-loop/STATE.md` 和 `BACKLOG.md`。
2. 如果 `status` 不是 `active`，或 `next_iteration > cycle_end_iteration`，直接汇报循环结束，不再改代码。
3. 运行 `git status --short`。如果工作区有未提交的代码改动，先停下并汇报，不要覆盖上一轮或用户的内容；`XIsland-2.2.0-测试报告.md`、`competition/`、`docs/trademark-application-prep.md` 是用户未跟踪文件，永远不要提交、移动或删除。
4. 跑基线：`python3 Scripts/check-docs.py`；涉及 Swift 时再跑相关测试或 `swift build -c release --product XIsland -j 2`。
5. 从 `BACKLOG.md` 选第一个未完成、且不依赖 GUI/真实客户端/网络登录的任务。只做一个任务，不并行扩展。
6. 先写或补测试，再实现；保持改动最小。不要降低测试标准，不要用 skip 掩盖失败，不要改版本号。
7. 跑目标测试和文档检查。若通过，提交本轮涉及的文件；提交信息写清轮次和任务。若失败且无法在 45 分钟内收敛，恢复自己改动的文件，更新 `STATE.md` 记录阻塞原因，不留下脏工作区。
8. 更新 `STATE.md`：`completed_iterations`、`next_iteration`、`last_task`、`last_check`、`status`。若 `next_iteration > cycle_end_iteration`，将 `status` 改为 `complete`；否则保持 `active`。
9. 最终回复只汇报：本轮任务、改动文件、测试结果、提交哈希、下一轮编号，以及是否需要用户介入。

## 边界

- 禁止 `git push`、`git tag`、`gh release`、修改 `Casks/` 版本或发布 DMG；本轮只做工程改进，不发布。
- 禁止 `sudo`、删除用户数据、改写系统配置、读取或输出密钥。
- 不修改 `Sources/XIslandVSCode` 之外的用户未跟踪目录；不运行真实 Agent 任务或 GUI 自动化。
- 不为了让测试通过而改断言、删测试、放宽安全校验；如果测试本身有问题，只报告证据。
- 每轮最多 45 分钟。超时就停止，不留下半成品。
- 同一时间只允许一轮；若发现上一轮仍在运行，直接退出。
