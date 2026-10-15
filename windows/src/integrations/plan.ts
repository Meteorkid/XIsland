import { win32 } from 'node:path';
import { adapterFor, type ConfigurableAgent, type SupportedAgent } from '../adapters/registry';
import { isRecord } from '../core/protocol';

type Configuration = Record<string, unknown>;
export interface IntegrationPlanInput {
  agent: ConfigurableAgent;
  operation: 'install' | 'uninstall';
  homeDirectory: string;
  nodeExecutable: string;
  hookScript: string;
  configuration?: unknown;
}
export interface IntegrationPlan {
  agent: ConfigurableAgent;
  operation: 'install' | 'uninstall';
  configPath: string;
  nextConfig: Configuration;
  changed: boolean;
  addedHandlers: number;
  removedHandlers: number;
  backup: { required: boolean; directory: string; filenamePrefix: string; exclusive: true };
  warnings: string[];
  sources: string[];
}

const OWNER = 'xisland-windows-v1';
const PREFIX = 'powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ';
const MARKER = '# XIsland-Windows-Hook-v1:';
const profiles = {
  claude_code: { path: '.claude/settings.json', source: 'https://code.claude.com/docs/en/hooks', milliseconds: false },
  codex: { path: '.codex/hooks.json', source: 'https://learn.chatgpt.com/docs/hooks', milliseconds: false },
  cursor: { path: '.cursor/hooks.json', source: 'https://cursor.com/docs/hooks', milliseconds: false },
  gemini_cli: { path: '.gemini/settings.json', source: 'https://geminicli.com/docs/hooks/reference/', milliseconds: true },
  windsurf: { path: '.codeium/windsurf/hooks.json', source: 'https://docs.devin.ai/desktop/cascade/hooks', milliseconds: false },
  trae_cn: { path: '.trae-cn/hooks.json', source: 'https://docs.trae.cn/ide_hook-configuration-reference', milliseconds: false },
} as const;

function windowsPath(value: string): string {
  if (typeof value !== 'string' || !/^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)/.test(value)
    || /[\u0000-\u001f"<>|?*]/.test(value) || value.slice(2).includes(':')) throw new Error('必须提供有效的 Windows 绝对路径');
  return win32.normalize(value);
}

function psLiteral(value: string): string { return `'${value.replaceAll("'", "''")}'`; }
function windowsArgument(value: string): string {
  return `"${value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/g, '$1$1')}"`;
}

/** 只生成命令；编码隔离 shell 元字符，.NET 原始流转发避免 PowerShell 改写 UTF-8。 */
export function windowsHookCommand(nodeExecutable: string, hookScript: string, agent: SupportedAgent, event: string): string {
  const node = windowsPath(nodeExecutable), script = windowsPath(hookScript);
  if (!/\.exe$/i.test(node) || !/\.[cm]?js$/i.test(script) || !adapterFor(agent).events.includes(event)) throw new Error('无效 hook 启动参数');
  const manifest = Buffer.from(JSON.stringify({ node, script, agent, event }), 'utf8').toString('base64');
  const args = [script, '--agent', agent, '--hook', event, '--managed-by', OWNER].map(windowsArgument).join(' ');
  const observationOnly = agent === 'workbuddy';
  const source = [
    `${MARKER}${manifest}`,
    '$ErrorActionPreference = "Stop"',
    'try {',
    '$p = New-Object System.Diagnostics.Process',
    `$p.StartInfo.FileName = ${psLiteral(node)}`,
    `$p.StartInfo.Arguments = ${psLiteral(args)}`,
    '$p.StartInfo.UseShellExecute = $false',
    '$p.StartInfo.CreateNoWindow = $true',
    '$p.StartInfo.RedirectStandardInput = $true',
    '$p.StartInfo.RedirectStandardOutput = $true',
    '$p.StartInfo.RedirectStandardError = $true',
    '$null = $p.Start()',
    ...(observationOnly ? [
      // WorkBuddy 宿主超时会阻断任务；观察启动器先自行限时退出，并始终丢弃控制输出。
      '$out = $p.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null)',
      '$err = $p.StandardError.BaseStream.CopyToAsync([System.IO.Stream]::Null)',
      '$inputCopy = [Console]::OpenStandardInput().CopyToAsync($p.StandardInput.BaseStream)',
      'if (-not $inputCopy.Wait(1000)) { throw "input_timeout" }',
      '$p.StandardInput.Close()',
      'if (-not $p.WaitForExit(4000)) { $p.Kill(); $null = $p.WaitForExit(500) }',
      '$null = $out.Wait(500)',
      '$null = $err.Wait(500)',
      '$p.Dispose()',
      'exit 0',
      '} catch { try { if ($p -and -not $p.HasExited) { $p.Kill() }; if ($p) { $p.Dispose() } } catch { }; exit 0 }',
    ] : [
      '$out = $p.StandardOutput.BaseStream.CopyToAsync([Console]::OpenStandardOutput())',
      '$err = $p.StandardError.BaseStream.CopyToAsync([Console]::OpenStandardError())',
    // Node 可在达到输入上限时提前关闭管道；仍保留它已经生成的原生失败响应和退出码。
    'try { [Console]::OpenStandardInput().CopyTo($p.StandardInput.BaseStream) } catch { }',
    'try { $p.StandardInput.Close() } catch { }',
    '$p.WaitForExit()',
    '$out.GetAwaiter().GetResult()',
    '$err.GetAwaiter().GetResult()',
    '$code = $p.ExitCode',
    '$p.Dispose()',
    'exit $code',
      '} catch { [Console]::Error.WriteLine("XIsland hook launcher failed"); exit 1 }',
    ]),
  ].join('\n');
  const command = PREFIX + Buffer.from(source, 'utf16le').toString('base64');
  if (command.length > 8000) throw new Error('安装路径导致 Windows hook 命令超过安全长度，请缩短安装路径');
  return command;
}

function ownedHandler(handler: unknown, agent: SupportedAgent): boolean {
  if (!isRecord(handler) || (handler.type !== undefined && handler.type !== 'command') || handler.args !== undefined) return false;
  const command = agent === 'windsurf' ? handler.powershell : handler.command;
  if (typeof command !== 'string' || !command.startsWith(PREFIX)) return false;
  // 用户后加的其他平台命令属于用户配置，不能随 Windows 托管项一起删除。
  if (agent === 'windsurf' && handler.command !== undefined) return false;
  if (handler.commandWindows !== undefined && handler.commandWindows !== command) return false;
  if (handler.command_windows !== undefined && handler.command_windows !== command) return false;
  try {
    const encoded = command.slice(PREFIX.length);
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) return false;
    const source = Buffer.from(encoded, 'base64').toString('utf16le');
    const first = source.split('\n')[0]!;
    if (!first.startsWith(MARKER)) return false;
    const manifest: unknown = JSON.parse(Buffer.from(first.slice(MARKER.length), 'base64').toString('utf8'));
    return isRecord(manifest) && manifest.agent === agent && typeof manifest.node === 'string' && typeof manifest.script === 'string'
      && typeof manifest.event === 'string' && windowsHookCommand(manifest.node, manifest.script, agent, manifest.event) === command;
  } catch { return false; }
}

function validateKnownEvents(hooks: Configuration, agent: SupportedAgent): void {
  for (const event of adapterFor(agent).events) {
    const entries = hooks[event];
    if (entries === undefined) continue;
    if (!Array.isArray(entries)) throw new Error(`无效 hook 事件结构：${event}`);
    for (const entry of entries) {
      if (!isRecord(entry)) throw new Error(`无效 hook 条目：${event}`);
      if (agent === 'cursor') {
        const field = entry.type === 'prompt' ? 'prompt' : 'command';
        if (typeof entry[field] !== 'string' || !entry[field]) throw new Error(`无效 Cursor hook：${event}`);
      } else if (agent === 'windsurf') {
        if (![entry.command, entry.powershell].some(value => typeof value === 'string' && value.length > 0)) throw new Error(`无效 Windsurf hook：${event}`);
        for (const field of ['command', 'powershell', 'working_directory']) {
          if (entry[field] !== undefined && (typeof entry[field] !== 'string' || !entry[field] || entry[field].includes('\0'))) throw new Error(`无效 Windsurf hook 字段：${event}.${field}`);
        }
        if (entry.show_output !== undefined && typeof entry.show_output !== 'boolean') throw new Error(`无效 Windsurf hook 输出设置：${event}`);
      } else {
        if (!Array.isArray(entry.hooks) || (entry.matcher !== undefined && typeof entry.matcher !== 'string')) throw new Error(`无效 hook 分组：${event}`);
        for (const handler of entry.hooks) {
          if (agent === 'trae_cn') {
            if (!isRecord(handler) || (handler.type !== undefined && handler.type !== 'command') || typeof handler.command !== 'string' || !handler.command) throw new Error(`无效 Trae CN hook command：${event}`);
            continue;
          }
          if (!isRecord(handler) || typeof handler.type !== 'string') throw new Error(`无效 hook handler：${event}`);
          if (handler.type === 'command' && (typeof handler.command !== 'string' || !handler.command)) throw new Error(`无效 hook command：${event}`);
        }
      }
    }
  }
}

/** 纯合并：返回待写配置与备份意图；从不访问磁盘或覆盖已有用户设置。 */
export function createIntegrationPlan(input: IntegrationPlanInput): IntegrationPlan {
  const adapter = adapterFor(input.agent), profile = profiles[input.agent];
  if (!['install', 'uninstall'].includes(input.operation)) throw new Error('无效安装操作');
  const home = windowsPath(input.homeDirectory);
  if (input.configuration !== undefined && !isRecord(input.configuration)) throw new Error('配置根节点必须是 JSON 对象');
  const original = input.configuration ?? {};
  const nextConfig = JSON.parse(JSON.stringify(original)) as Configuration;
  if (nextConfig.hooks !== undefined && !isRecord(nextConfig.hooks)) throw new Error('hooks 必须是 JSON 对象');
  if (input.agent === 'cursor' && nextConfig.version !== undefined && nextConfig.version !== 1) throw new Error('不支持的 Cursor hooks 配置版本');
  if (input.agent === 'trae_cn' && nextConfig.version !== undefined && nextConfig.version !== 1) throw new Error('不支持的 Trae CN hooks 配置版本');
  const hooks: Configuration = isRecord(nextConfig.hooks) ? nextConfig.hooks : {};
  validateKnownEvents(hooks, input.agent);
  let removedHandlers = 0, addedHandlers = 0;
  for (const [event, entries] of Object.entries(hooks)) {
    // Gemini 的 hooks.disabled 等元数据与未来未知键必须原样保留。
    if (!Array.isArray(entries)) continue;
    const kept: unknown[] = [];
    for (const entry of entries) {
      if (input.agent === 'cursor' || input.agent === 'windsurf') {
        if (ownedHandler(entry, input.agent)) removedHandlers++;
        else kept.push(entry);
      } else if (isRecord(entry) && Array.isArray(entry.hooks)) {
        const retained = entry.hooks.filter(handler => { const owned = ownedHandler(handler, input.agent); if (owned) removedHandlers++; return !owned; });
        if (retained.length === entry.hooks.length) kept.push(entry);
        else if (retained.length) kept.push({ ...entry, hooks: retained });
      } else kept.push(entry);
    }
    if (kept.length || !entries.length) hooks[event] = kept;
    else delete hooks[event];
  }
  if (input.operation === 'install') {
    for (const event of adapter.events) {
      const command = windowsHookCommand(input.nodeExecutable, input.hookScript, input.agent, event);
      const interactive = event === 'PermissionRequest' || (input.agent === 'claude_code' && event === 'PreToolUse')
        || (input.agent === 'cursor' && ['beforeShellExecution', 'beforeMCPExecution', 'beforeReadFile'].includes(event));
      const timeout = profile.milliseconds ? 5000 : interactive ? 130 : 5;
      const handler: Configuration = { type: 'command', command, timeout };
      if (input.agent === 'cursor' && interactive) handler.failClosed = true;
      if (input.agent === 'codex') handler.commandWindows = command;
      if (input.agent === 'gemini_cli') handler.name = `XIsland:${event}`;
      const entry = input.agent === 'windsurf' ? { powershell: command, show_output: false }
        : input.agent === 'cursor' ? handler : { hooks: [handler] };
      hooks[event] = [...(hooks[event] as unknown[] | undefined ?? []), entry];
      addedHandlers++;
    }
    nextConfig.hooks = hooks;
    if (input.agent === 'cursor' || input.agent === 'trae_cn') nextConfig.version = 1;
  }
  const configPath = win32.join(home, profile.path);
  const changed = JSON.stringify(original) !== JSON.stringify(nextConfig);
  const warnings = ['此计划未写入配置，也未证明客户端已加载；需在原客户端确认 hook 信任与实际事件。',
    'Node 路径必须来自实际发现结果；命令要求 Windows PowerShell。Windows 启动器仍需实机验证。'];
  if (nextConfig.disableAllHooks === true || (isRecord(nextConfig.hooksConfig) && nextConfig.hooksConfig.enabled === false)) {
    warnings.push('客户端当前关闭了 hooks；计划保留该设置，不会自动启用。');
  }
  if (input.agent === 'codex') warnings.push('自定义 CODEX_HOME 或受管理 hooks 需由调用方核对；不修改 config.toml 或信任记录。');
  if (input.agent === 'windsurf') warnings.push('仅接入 Cascade 的 10 项观察事件；不接管原生审批，不读取 transcript，不适用于 Devin Local Agent。');
  if (input.agent === 'trae_cn') warnings.push('Trae CN 与 TraeWork CN 共用此 6 事件观察入口和配置文件，只需安装一次。Windows 桥接根据启动进程与公开产品信息区分来源；识别失败时保留共享标签。审批、提问和文档审阅仍在原客户端处理。',
    'TraeWork CN 依据 0.2.2 公开安装资源核对；Windows 本地任务尚待实测，云端任务、国际版及其他旧 SOLO 版本不在已核对范围。');
  return { agent: input.agent, operation: input.operation, configPath, nextConfig, changed,
    addedHandlers: changed ? addedHandlers : 0, removedHandlers: changed ? removedHandlers : 0,
    backup: { required: changed && input.configuration !== undefined, directory: win32.dirname(configPath),
      filenamePrefix: win32.basename(configPath) + '.xisland-backup-', exclusive: true }, warnings, sources: [profile.source] };
}

/** 可直接打印的摘要不含原用户配置、第三方 hook 命令或凭据。 */
export function integrationPlanSummary(plan: IntegrationPlan): Omit<IntegrationPlan, 'nextConfig'> {
  const { nextConfig: _privateConfig, ...summary } = plan;
  return summary;
}
