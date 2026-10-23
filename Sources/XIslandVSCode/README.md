# X Island Bridge 1.0.0

此扩展观察已核实版本的原生任务事件。不会把编辑文件、切换标签页、打开终端或扩展已激活当成 AI 正在工作。

- Roo Code：`RooVeterinaryInc.roo-cline` 3.54.0，设置 `xisland.observeRooCode` 控制订阅。
- PearAI Roo fork：`PearAI.pearai-roo-cline` 3.15.3，实验设置 `xisland.observePearAIExperimental` 默认关闭。相同版本号不能证明发行产物与已审计源码一致，仍需核对实际宿主。

仅支持受信任的本地 macOS 扩展宿主。不会自动安装、激活目标扩展或创建模型任务。观察当前侧栏 API 可见的任务；普通 UI 新建标签页和晚接入时的历史状态可能不可见。工作目录、初始任务文字的角色、完整工具调用结果不能由现有 API 可靠给出，未伪造这些信息。

每次订阅有独立的观察身份，原生任务ID单独保留。同profile的不同窗口不会共用活跃会话；普通socket重连沿用身份，窗口重载形成新观察记录。消息按原生时间标识更新；未知角色文字和隐藏 reasoning 不写入助手对话。Roo 只有权威 taskInteractive 事件才能标记输入等待；Pear 的 ask 仅显示原应用提示。批准、拒绝和回答仍在原应用完成，扩展不调用 sendMessage、pressPrimaryButton 或类似接口。

观察传输通过 `~/.xisland/bin/di-bridge vscode-observation` 原生入口，每个连接只发送一个事件，接收端仍执行进程身份检查。入口仅接收 Roo/Pear 观察消息，单帧上限 256 KiB。连接前失败保留队列；消息交给原生进程后不会重放，没有应答确认，仍可能丢失断连中的事件。业务积压30秒过期，心跳积压3秒过期。来源每10秒发送心跳；接收端30秒未收到新鲜消息时停止显示运行状态，记录观察中断，不将原生任务标为完成。心跳不改变业务活动时间或证明模型正在运行。

正常停用会发送结束观察通知；意外退出由租约兜底。同一原生任务的不同观察片段分别保留，统计累计用量时去重。多窗口、重载和崩溃恢复已通过模拟原生API与隔离XIsland应用的链路检查，真实编辑器中的验收仍未完成。没有可靠的原生窗口编号，因此来源隔离不代表能够精确跳回对应窗口。

请配合包含 `vscode-observation` 原生入口的 X Island 构建使用。在目标编辑器选择 **Extensions: Install from VSIX** 安装生成的包，再核对来源设置。XIsland 设置里的 Roo/Pear 开关控制接收，不再生成无依据的 hooks.json。扩展的协议和隔离通道已经测试，真实编辑器加载与完整客户端验收仍待完成。

开发验证：

```sh
npm run compile
npm test
```

仓库根目录可运行 `python3 Scripts/package-vscode-extension.py` 构建离线 VSIX；该命令使用已有 TypeScript 依赖，不安装依赖、不发布、不修改编辑器配置。

`python3 Scripts/test-vscode-transport.py` 使用 `.build/debug/DIBridge`（可用 `--bridge-path` 指定）交叉验证原生入口与当前Swift读取/解码函数；`python3 Scripts/test-vscode-app.py` 在新构建的隔离应用中启用生产 peer 检查，验证直接 Node 连接被拒绝及原生桥接的完整socket与会话状态链路。两者使用合成事件，不启动Roo/Pear客户端。

`python3 Scripts/test-vscode-observation.py` 验证双窗口、重载、正常退出、崩溃超时及临时历史库中的四条独立观察记录。此测试约需30—45秒，不安装扩展、不使用模型服务。
