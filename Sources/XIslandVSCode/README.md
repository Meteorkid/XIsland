# X Island Bridge 1.1.0

此扩展观察已核实版本的原生任务事件，并可接收 X Island 的 `vscode://meteorkid.xisland-vscode/focus` 请求，按 tty/pid/唯一 cwd 显示**已经存在**的集成终端。聚焦请求不新建终端、不发送命令、不读取终端输出；匹配不到或同一 tty 有多个终端时保持原状。它只是终端定位，不代表能恢复具体的 Claude/Copilot 聊天。

- Roo Code：`RooVeterinaryInc.roo-cline` 3.54.0，设置 `xisland.observeRooCode` 控制订阅。
- PearAI Roo fork：`PearAI.pearai-roo-cline` 3.15.3，实验设置 `xisland.observePearAIExperimental` 默认关闭。相同版本号不能证明发行产物与已审计源码一致，仍需核对实际宿主。

聚焦 URI 也只在本机 macOS 窗口生效；多窗口时 VS Code 只会把 URI 交给其中一个窗口，若该窗口没有匹配终端则不会跨窗口猜测。仅支持受信任的本地 macOS 扩展宿主。不会自动安装、激活目标扩展或创建模型任务。观察当前侧栏 API 可见的任务；普通 UI 新建标签页和晚接入时的历史状态可能不可见。工作目录、初始任务文字的角色、完整工具调用结果不能由现有 API 可靠给出，未伪造这些信息。

每次订阅有独立的观察身份，原生任务ID单独保留。同profile的不同窗口不会共用活跃会话；普通socket重连沿用身份，窗口重载形成新观察记录。消息按原生时间标识更新；未知角色文字和隐藏 reasoning 不写入助手对话。Roo 只有权威 taskInteractive 事件才能标记输入等待；Pear 的 ask 仅显示原应用提示。批准、拒绝和回答仍在原应用完成，扩展不调用 sendMessage、pressPrimaryButton 或类似接口。

观察传输通过 `~/.xisland/bin/di-bridge vscode-observation` 原生入口，每个连接只发送一个事件，接收端仍执行进程身份检查。入口仅接收 Roo/Pear 观察消息，单帧上限 256 KiB。连接前失败保留队列；消息交给原生进程后不会重放，没有应答确认，仍可能丢失断连中的事件。业务积压30秒过期，心跳积压3秒过期。来源每10秒发送心跳；接收端30秒未收到新鲜消息时停止显示运行状态，记录观察中断，不将原生任务标为完成。心跳不改变业务活动时间或证明模型正在运行。

正常停用会发送结束观察通知；意外退出由租约兜底。同一原生任务的不同观察片段分别保留，统计累计用量时去重。多窗口、重载和崩溃恢复已通过模拟原生API与隔离XIsland应用的链路检查，真实编辑器中的验收仍未完成。没有可靠的原生窗口编号，因此来源隔离不代表能够精确跳回对应窗口。

请配合 **X Island 2.0.7 或更新版本**使用；请先更新 App，再安装本版 VSIX 并重新加载编辑器窗口。在目标编辑器选择 **Extensions: Install from VSIX** 安装生成的包，再核对来源设置。XIsland 设置里的 Roo/Pear 开关控制接收，不再生成无依据的 hooks.json。扩展的协议和隔离通道已经测试，真实编辑器加载与完整客户端验收仍待完成。

开发验证：

```sh
npm run compile
npm test
```

仓库根目录可运行 `python3 Scripts/package-vscode-extension.py` 构建离线 VSIX；该命令使用已有 TypeScript 依赖，不安装依赖、不发布、不修改编辑器配置。

`python3 Scripts/test-vscode-transport.py` 使用 `.build/debug/DIBridge`（可用 `--bridge-path` 指定）交叉验证原生入口与当前Swift读取/解码函数；`python3 Scripts/test-vscode-app.py` 在新构建的隔离应用中启用生产 peer 检查，验证直接 Node 连接被拒绝及原生桥接的完整socket与会话状态链路。两者使用合成事件，不启动Roo/Pear客户端。

`python3 Scripts/test-vscode-observation.py` 验证双窗口、重载、正常退出、崩溃超时及临时历史库中的四条独立观察记录。此测试约需30—45秒，不安装扩展、不使用模型服务。

## 复制给 LLM

```text
你是我的 macOS 配置助手。请为本机 X Island Bridge VS Code 扩展完成安装与验证。

已知：
- 扩展只观察 Roo Code 3.54.0 与 PearAI Roo fork 3.15.3 的原生任务，并提供已存在集成终端的聚焦请求；不创建终端、不发送命令、不读取终端输出。
- X Island Bridge 需要配合 X Island 2.0.7 或更新版本；请先确认 App 版本。
- 批准、拒绝和回答仍在原扩展完成；本扩展不调用 sendMessage 或主按钮。

执行：
1. 检查 VS Code / Insiders 版本、已安装扩展和现有 X Island App 版本；备份已有 VSIX 或扩展目录。
2. 如果已有可信的本仓库构建产物，直接安装；否则运行 python3 Scripts/package-vscode-extension.py 构建离线 VSIX，不安装新依赖、不发布、不修改编辑器配置。
3. 使用 Extensions: Install from VSIX 安装，重新加载编辑器窗口；不要从不明来源下载同名扩展。
4. 在 X Island 设置中确认 Roo/Pear 接收开关状态；PearAI 实验来源默认关闭，只有我明确要求时才启用。
5. 打开一个受信任的本地 macOS 工作区，发一条只读任务，检查 X Island 是否出现会话；聚焦 URI 只验证已存在终端，不新建终端。

边界：
- 不自动安装、激活目标扩展或创建模型任务；不修改用户设置和凭据。
- 不把扩展安装成功当成真实客户端验收；观察 API 看不到的状态如实报告。
- 完成后报告：VS Code 形态、VSIX 路径、安装结果、启用的来源、真实任务结果和未覆盖的窗口/终端情况。
```
