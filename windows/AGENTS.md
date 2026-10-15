# Windows XIsland

- 这是现有 macOS XIsland 的 Windows 客户端；视觉、业务与协议基准见 `../docs/windows/`。
- 未经任务明确需要，不改动 `../Sources/`、`../Tests/` 或已有发布配置；保留用户未提交修改。
- 前端使用 TypeScript，原生层使用 Rust/Tauri 2。核心状态逻辑不得依赖 DOM/Tauri，平台行为放在独立模块。
- 核心逻辑变更须补充回归测试；运行 `npm run check`、`npm test`、`npm run build`。原生层另运行 Cargo 检查；Windows 实机结果单独报告。
- 样例模式与真实会话严格隔离；审批只在实际回传成功后标记解决，禁止超时默认批准。
- 保持现有 DIMessage 的字段和事件名；原生 Agent 输出必须按对应客户端协议转换。
- 不复制 GPL/AGPL 项目源码。第三方源码引入必须记录来源、许可与修改说明。
- 不自动安装全局依赖或修改 PATH，不自动提交/推送/发布；新增依赖限于本子项目。
