$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
if (-not $IsWindows -and $env:OS -ne 'Windows_NT') { throw '请在 Windows PowerShell 中执行此脚本。' }
foreach ($tool in @('node', 'npm', 'cargo')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "缺少 $tool，请先按 README 安装构建工具。" }
}
npm ci
if ($LASTEXITCODE -ne 0) { throw '依赖安装失败' }
npm run check
if ($LASTEXITCODE -ne 0) { throw '类型检查失败' }
npm test
if ($LASTEXITCODE -ne 0) { throw '核心测试失败' }
cargo test --manifest-path src-tauri/Cargo.toml --no-default-features
if ($LASTEXITCODE -ne 0) { throw '原生通信测试失败' }
cargo build --manifest-path src-tauri/Cargo.toml --release --no-default-features --bin xisland-bridge
if ($LASTEXITCODE -ne 0) { throw '桥接程序编译失败' }
New-Item -ItemType Directory -Force src-tauri/resources | Out-Null
Copy-Item src-tauri/target/release/xisland-bridge.exe src-tauri/resources/xisland-bridge.exe -Force
npm run build:hook
if ($LASTEXITCODE -ne 0) { throw 'Agent hook 构建失败' }
npm run tauri -- build --bundles nsis
if ($LASTEXITCODE -ne 0) { throw 'Windows 安装包构建失败' }
Get-ChildItem src-tauri/target/release/bundle/nsis/*.exe | ForEach-Object { Get-FileHash $_.FullName -Algorithm SHA256 }
