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

## 复制给 LLM

GLM 不是独立客户端。下面提示让 Agent 在实际宿主里配置模型并验证 X Island 的模型显示；不要让它创建一套“GLM hooks”。

```text
你是我的 macOS 配置助手。请帮我在实际宿主客户端中启用 GLM，并验证 X Island 能显示和筛选该模型。

已知：
- GLM 是模型来源，不是独立 Agent；运行在 Claude Code、OpenCode、Cline 或 Pi 中。
- X Island 只读取客户端上报的模型字段，不读取认证文件、服务商账单或 API Key。
- 不创建 GLM 独立会话、不改写 API 密钥、不伪造模型映射。

执行：
1. 先确认我使用哪个宿主（Claude Code / OpenCode / Cline / Pi）和实际模型名。
2. 按宿主厂商说明配置 GLM；只改该宿主的模型设置，保留其他 provider、模型和凭据。
3. 检查 X Island 对应宿主的接入已启用，并让宿主重新加载 hook 或扩展。
4. 发一条只读任务，确认 X Island 会话里显示的模型标识与实际选择一致；展开筛选栏检查 GLM 是否出现。

边界：
- 不读取或输出 API Key；不把 sonnet 等别名猜成 GLM；客户端没上报 model 时如实报告“未显示”。
- 切换模型不改变会话 ID、权限响应格式或工具归属。
- 完成后报告：宿主、模型名、改动位置（不含密钥）、X Island 显示的模型和真实任务结果。
```
