# Kiro CLI V3 接入

XIsland 提供 **Kiro CLI 2.31.0、明确使用 V3 引擎**的观察配置导出。会话开始、提交提示、工具准备、工具结果、回合结束和会话关闭共六类事件可以接入。该入口基于官方文档与本地协议回归；真实 Kiro 配置加载、模型任务和 IDE 仍待验证，审批仍在 Kiro 中处理。

## 生成配置

先确认实际 CLI 版本为 `2.31.0`，再在终端执行：

```sh
printf '{}\n' | "/Applications/X Island.app/Contents/MacOS/di-bridge" kiro-config-v3 --cli-version 2.31.0 --engine v3 > /tmp/xisland-kiro-observer.json
```

输出是完整的独立 hook 文档，顶层有 `version` 和 `hooks` 数组，**不是** `settings.json`，也不是 agent 配置的 `hooks` 字段。命令只输出 JSON，不执行 Kiro，不修改任何现有配置。其他版本或未明确 V3 的请求会被拒绝；版本参数表示选定的文档基线，不代表 XIsland 已检测或验证本机版本。

## 交给 Kiro 加载

检查生成的 JSON 后，将它保存为 CLI 全局目录中的 `hooks/xisland-observer.json`。默认完整路径是 `~/.kiro/hooks/xisland-observer.json`；若启动 Kiro 的环境设置了 `KIRO_HOME`，使用该目录下的 `hooks/xisland-observer.json`。只选一个作用域，避免重复上报。已有同名文件时先备份，再按下一节合并。

```sh
kiro-cli chat --v3
```

在这个新会话中用 `/config` 查看 Hooks 及来源，再提交一次普通提示，检查 XIsland 是否出现会话。工具请求按 Kiro 本身的交互处理。配置文件存在只证明配置已写入，出现原生事件才证明加载与上报成功。[官方路径及激活规则](https://kiro.dev/docs/hooks/)、[CLI 2.31 的 KIRO_HOME 支持](https://kiro.dev/changelog/cli/2-31/)、[配置面板](https://kiro.dev/changelog/cli/2-21/)

本入口面向 CLI；不要将同一配置同时复制到 IDE/CLI 共享的项目 `.kiro/hooks/`。Kiro IDE、Web、旧 Amazon Q 和 Classic/V2 不属于本说明的已实现范围。Headless hooks 从 2.27.1 起才支持，本次没有自动开启工具信任或审批选项。[官方 headless 说明](https://kiro.dev/docs/cli/headless/)

## 更新或移除

更新时把现有 **独立 hook 文件**输入同一个导出命令，先写入不同的临时文件并检查，再替换原文件。不要让输入与重定向输出指向同一个文件。

```sh
"/Applications/X Island.app/Contents/MacOS/di-bridge" kiro-config-v3 --cli-version 2.31.0 --engine v3 < /path/to/xisland-observer.json > /tmp/xisland-kiro-updated.json

"/Applications/X Island.app/Contents/MacOS/di-bridge" kiro-config-v3 --remove < /path/to/xisland-observer.json > /tmp/xisland-kiro-removed.json
```

合并和移除保留第三方 hooks；本应用的条目若被手动修改，会停止变换，避免删除定制内容。完全独立且未添加其他内容的 `xisland-observer.json` 也可直接由用户删除。变更在下次启动会话后验证。

## 当前限制

- 没有原生工具调用 ID，不按名称猜测并行工具的对应关系；前置事件只报告“准备调用”。
- `Stop` 只表示本轮准备结束，可能不含答案；其他 hook 仍可要求继续执行，因此显示“完成未确认”，不直接宣布空闲。只有 `SessionEnd` 才关闭会话。
- 官方 V3 schema 与 CLI actions 的超时字段仍不一致，导出省略这两个可选字段，采用客户端默认超时；观察命令不等待岛上审批，不向模型输出内容。
- 不提供原生批准/拒绝按钮，也没有证明子代理树、配置热加载或所有客户端模式。

协议与测试范围见[发布验证摘要](release-verification-2.0.0.json)；官方事件定义见 [Kiro hooks](https://kiro.dev/docs/hooks/) 与 [hook actions](https://kiro.dev/docs/hooks/actions/)。
