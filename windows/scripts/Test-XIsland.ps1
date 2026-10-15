param(
    [string]$AppPath = '',
    [string]$OutputPath = (Join-Path $PSScriptRoot 'XIsland-Windows-diagnostics.json')
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw '此检查脚本只用于 Windows。' }
$report = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTime]::UtcNow.ToString('o')
    scope = 'read-only-environment-and-pipe-check'
    os = $null
    application = [ordered]@{ found = $false; running = $false; version = $null; architecture = $null }
    node = [ordered]@{ available = $false; version = $null; bundled = $false }
    displays = @()
    runtime = [ordered]@{ descriptorPresent = $false; protocolVersion = $null; pipeReachable = $false; error = $null }
    manualGates = @('installation', 'visual-parity', 'chinese-ime', 'dpi-and-multi-monitor', 'real-agent-status', 'real-agent-approval', 'uninstall')
}
$os = Get-CimInstance Win32_OperatingSystem
$report.os = [ordered]@{ name = $os.Caption; version = $os.Version; build = $os.BuildNumber; architecture = $os.OSArchitecture }
if (-not $AppPath) {
    $candidates = @((Join-Path $env:LOCALAPPDATA 'X Island\xisland.exe'), (Join-Path $env:ProgramFiles 'X Island\xisland.exe'))
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { $AppPath = $candidate; break } }
}
if ($AppPath -and (Test-Path -LiteralPath $AppPath -PathType Leaf)) {
    $report.application.found = $true
    $report.application.version = [Diagnostics.FileVersionInfo]::GetVersionInfo($AppPath).ProductVersion
    $reader = New-Object IO.BinaryReader([IO.File]::OpenRead($AppPath))
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw '应用不是有效的 Windows PE 文件。' }
        $reader.BaseStream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($reader.BaseStream.Length - 6)) { throw '应用 PE 头无效。' }
        $reader.BaseStream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw '应用 PE 签名无效。' }
        $machine = $reader.ReadUInt16()
        $report.application.architecture = switch ($machine) { 0x8664 { 'x64' } 0xAA64 { 'arm64' } 0x014C { 'x86' } default { 'unknown' } }
    } finally { $reader.Dispose() }
}
$report.application.running = @(Get-Process -Name 'xisland' -ErrorAction SilentlyContinue).Count -gt 0
$nodePath = $null
if ($AppPath) {
    $candidate = Join-Path (Split-Path -Parent $AppPath) 'resources\node.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $nodePath = $candidate; $report.node.bundled = $true }
}
if (-not $nodePath) { $node = Get-Command node.exe -ErrorAction SilentlyContinue; if ($node) { $nodePath = $node.Source } }
if ($nodePath) {
    $report.node.available = $true
    $report.node.version = ((& $nodePath --version 2>$null) | Select-Object -First 1)
}
try {
    Add-Type -AssemblyName System.Windows.Forms
    $report.displays = @([Windows.Forms.Screen]::AllScreens | ForEach-Object {
        [ordered]@{ name = $_.DeviceName; primary = $_.Primary; x = $_.Bounds.X; y = $_.Bounds.Y; width = $_.Bounds.Width; height = $_.Bounds.Height }
    })
} catch { $report.displays = @() }
$runtimePath = Join-Path $env:LOCALAPPDATA 'XIsland\runtime.json'
if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
    $report.runtime.descriptorPresent = $true
    $pipe = $null
    try {
        $runtime = [IO.File]::ReadAllText($runtimePath) | ConvertFrom-Json
        $report.runtime.protocolVersion = $runtime.protocolVersion
        if ($runtime.protocolVersion -ne 1 -or $runtime.endpoint -notmatch '^\\\\\.\\pipe\\(xisland-[a-f0-9]{32})$') { throw '运行时描述格式不匹配' }
        $pipeName = $Matches[1]
        $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(1500)
        $report.runtime.pipeReachable = $pipe.IsConnected
        # 仅连接后关闭，不发送事件、不写历史、不创建审批，也不输出 token。
    } catch { $report.runtime.error = '无法连接当前运行时；请确认 XIsland 已启动后重试。' }
    finally { if ($pipe) { $pipe.Dispose() } }
}
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw '输出目录不存在，请指定已有目录。' }
$json = $report | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $json, (New-Object Text.UTF8Encoding($false)))
Write-Host '只读检查完成。此结果不代表视觉、审批或真实客户端验收已通过。'
Write-Host ('诊断文件：' + [IO.Path]::GetFullPath($OutputPath))
