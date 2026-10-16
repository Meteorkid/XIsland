# GLM 多客户端接入

GLM 是模型系列。X Island 沿用运行它的客户端事件与权限协议，在会话中显示客户端上报的模型，并提供 GLM 筛选；不会另外创建一个 GLM 会话或改写 API 密钥。

## 使用方式

1. 在 Claude Code、OpenCode、Cline 或 Pi 中按厂商说明配置并选择 GLM。
2. 在 X Island 的 Agent 设置中启用对应客户端的接入；如果客户端要求启用 hooks 或信任配置，在该客户端中完成。
3. 开始一条任务。会话保留原客户端名称，模型行显示实际收到的模型标识，例如 `glm-5.3`。
4. 展开筛选栏，选择 GLM，可以同时查看不同客户端中使用该模型系列的会话；搜索框也支持模型名称。

| 客户端 | 模型字段来源 | 厂商配置说明 |
| --- | --- | --- |
| Claude Code | 原生 hook 的 model | [Z.AI Claude Code](https://docs.z.ai/devpack/tool/claude) |
| OpenCode | chat.message 的 model.modelID | [Z.AI OpenCode](https://docs.z.ai/devpack/tool/opencode) |
| Cline | 文件 hook 的 model.slug | [Z.AI Cline](https://docs.z.ai/devpack/tool/cline) |
| Pi | 扩展上下文的 model.id | [Z.AI Pi](https://docs.z.ai/devpack/tool/pi) |

模型名称来自客户端，不读取认证文件或服务商账单。客户端只上报 `sonnet` 等别名时，X Island 无法证明背后实际使用 GLM；此时保留原始名称，不猜测映射。客户端在尚未选定模型时没有上报 model，模型行暂不显示。

GLM 筛选只识别明确的模型名称（含 `z-ai/glm-*` 等命名空间），不会改变客户端分组、会话 ID、权限响应格式或工具归属。切换模型会更新同一个会话；历史与导出保留该会话最后收到的模型标识。

## 验证范围与排查

四条客户端载荷经解析、会话管理、模型筛选和历史恢复的契约测试，以及 Pi 生成扩展的模拟宿主测试覆盖此功能。它们不等于四款客户端均已通过真实服务商端到端验收。各客户端其余能力与限制见[适配矩阵](README.md)和[发布验证摘要](release-verification-2.0.0.json)。

- 没有会话：先检查对应客户端的接入是否启用，并确认它实际加载了 X Island hook 或扩展。
- 有会话但没有模型：检查客户端是否发送模型字段；不需要把客户端名称改为 GLM。
- 没有 GLM 筛选：只有当前可见会话包含明确的 GLM 模型标识时才显示。
- 审批或提问：沿用原客户端能力；切换成 GLM 不会给观察型接口新增审批权限。

本轮相关代码：`GLMIntegration.swift`、`SessionManager.swift`、`PiPluginConfiguration.swift`；回归测试：`GLMMultiClientTests.swift`、`GLMClientBoundaryTests.swift`、`PiPluginConfigurationTests.swift`。
