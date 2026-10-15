此目录包含 Windows 安装包的配套工具。
xisland-bridge.exe 由 scripts/build-windows.ps1 编译生成。
xisland-hook.cjs 由 npm run build:hook 生成，包含各客户端的专用适配器。
node.exe 为随应用隔离携带的 Node.js LTS 运行时，不进行全局安装或 PATH 修改。
node-runtime.json 记录官方来源和 SHA-256，许可见 LICENSE-node.txt。
安装与启动 XIsland 不会自动修改 Agent 配置。
