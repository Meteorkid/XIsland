import { lstat, readFile } from 'node:fs/promises';
import { win32 } from 'node:path';
import { isRecord } from '../core/protocol';

export interface ClientDiscovery {
  state: 'detected' | 'not_found' | 'unconfirmed';
  executablePath?: string;
  version?: string;
  detail: string;
}
export interface DiscoveryEnvironment {
  home: string; path: string; appData?: string; localAppData?: string; programFiles?: string;
}
export interface DiscoveryIO {
  isFile(path: string): Promise<boolean>;
  packageAt(path: string): Promise<unknown>;
  readText?(path: string): Promise<string | undefined>;
}
const executables: Record<string, string[]> = {
  claude_code: ['claude.exe', 'claude.cmd'], codex: ['codex.exe', 'codex.cmd'], cursor: ['Cursor.exe', 'cursor.cmd'],
  gemini_cli: ['gemini.cmd', 'gemini.exe'], windsurf: ['Windsurf.exe', 'windsurf.cmd'],
  trae_cn: ['Trae CN.exe', 'TraeWork CN.exe', 'TRAE SOLO CN.exe'], workbuddy: ['WorkBuddy.exe'],
  opencode: ['opencode.exe', 'opencode.cmd'], qwen: ['qwen.cmd', 'qwen.exe'],
  code_buddy: ['codebuddy.cmd', 'codebuddy.exe'], droid: ['droid.exe'], kimi_code: ['kimi.cmd', 'kimi-code.cmd'], kiro: ['kiro-cli.exe'],
  copilot_cli: ['copilot.exe', 'copilot.cmd'], pi: ['pi.cmd', 'pi.exe'],
};
const applications: Record<string, string[]> = {
  cursor: ['Programs/cursor/Cursor.exe'], windsurf: ['Programs/Windsurf/Windsurf.exe'],
  trae_cn: ['Programs/Trae CN/Trae CN.exe', 'Programs/TRAE SOLO CN/TRAE SOLO CN.exe', 'Programs/TraeWork CN/TraeWork CN.exe'],
  workbuddy: ['Programs/WorkBuddy/WorkBuddy.exe'], opencode: ['Programs/OpenCode/OpenCode.exe'],
};

/** 仅探测固定名称，不执行 PATH 中的命令，也不读取客户端账号或会话。 */
export function clientCandidates(agent: string, env: DiscoveryEnvironment): string[] {
  const directories = [
    ...env.path.split(';').slice(0, 48), win32.join(env.home, '.local', 'bin'),
    win32.join(env.home, '.codex', 'bin'), win32.join(env.home, '.opencode', 'bin'), win32.join(env.home, '.copilot', 'bin'),
    env.appData ? win32.join(env.appData, 'npm') : '',
    env.programFiles ? win32.join(env.programFiles, 'nodejs') : '',
  ].filter(path => /^[A-Za-z]:[\\/]/.test(path) && !/[\0\r\n]/.test(path));
  const result = directories.flatMap(directory => (executables[agent] ?? []).map(name => win32.join(directory, name)));
  if (env.localAppData && win32.isAbsolute(env.localAppData)) {
    result.push(...(applications[agent] ?? []).map(path => win32.join(env.localAppData!, path)));
  }
  const seen = new Set<string>();
  return result.filter(path => { const key = path.toLowerCase(); if (seen.has(key)) return false; seen.add(key); return true; }).slice(0, 160);
}

async function readSmallText(path: string): Promise<string | undefined> {
  try {
    const info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink() || info.size > 64 * 1024) return undefined;
    const bytes = await readFile(path);
    if (bytes.length > 64 * 1024) return undefined;
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch { return undefined; }
}

/** 只接受真实 node 调用行；echo/rem 中提及包路径不能证明 shim 指向它。 */
export function isKimiCodeShim(source: string): boolean {
  return isNodePackageShim(source, '@moonshot-ai\\kimi-code\\dist\\main.mjs');
}

export function isPiShim(source: string): boolean {
  return isNodePackageShim(source, '@earendil-works\\pi-coding-agent\\dist\\bundle\\cli.js');
}

function isNodePackageShim(source: string, expectedEntry: string): boolean {
  if (source.length > 64 * 1024 || source.includes('\0')) return false;
  const lines = source.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  const invocation = /^(?:endlocal\s*&\s*goto\s+#_undefined_#\s+2>NUL\s*\|\|\s*title\s+%COMSPEC%\s*&\s*)?(?:"%_prog%"|"%~dp0\\node\.exe"|node(?:\.exe)?)\s+"%(?:dp0%|~dp0)\\node_modules\\([^"\r\n]+)"\s+%\*$/i;
  const last = lines.at(-1), match = last && invocation.exec(last);
  if (!last || !match || match[1]?.toLowerCase() !== expectedEntry.toLowerCase()) return false;
  const prefix = lines.slice(0, -1).map(line => line.toLowerCase());
  if (!last.includes('%_prog%')) return prefix.length === 0 || prefix.length === 1 && prefix[0] === '@echo off';
  // 限于 npm cmd-shim 生成的 Node 包装器，额外 SET、CALL、EXIT 不能伪装成有效入口。
  const expected = ['@echo off', 'goto start', ':find_dp0', 'set dp0=%~dp0', 'exit /b', ':start', 'setlocal', 'call :find_dp0',
    'if exist "%dp0%\\node.exe" (', 'set "_prog=%dp0%\\node.exe"', ') else (', 'set "_prog=node"', 'set pathext=%pathext:;.js;=;%', ')'];
  return JSON.stringify(prefix) === JSON.stringify(expected);
}

export async function discoverClient(agent: string, env: DiscoveryEnvironment, io: DiscoveryIO = {
  isFile: async path => { try { const info = await lstat(path); return info.isFile() && !info.isSymbolicLink(); } catch { return false; } },
  packageAt: async path => {
    try { const source = await readSmallText(path); return source === undefined ? null : JSON.parse(source); }
    catch { return null; }
  },
  readText: readSmallText,
}): Promise<ClientDiscovery> {
  const candidates = clientCandidates(agent, env);
  const found = await Promise.all(candidates.map(async path => await io.isFile(path) ? path : undefined));
  const executablePath = found.find((path): path is string => path !== undefined);
  if (!executablePath) return { state: 'not_found', detail: '未在常用位置找到客户端；自定义安装位置仍可手动配置。' };
  if (agent === 'kimi_code' || agent === 'pi') {
    // Python Kimi CLI 也会安装 kimi 命令；必须核对 Node 发行包，不能靠文件名选协议。
    for (const candidate of found) {
      if (!candidate) continue;
      const packageName = agent === 'pi' ? '@earendil-works/pi-coding-agent' : '@moonshot-ai/kimi-code';
      const packageRoot = win32.join(win32.dirname(candidate), 'node_modules', ...packageName.split('/'));
      const metadata = await io.packageAt(win32.join(packageRoot, 'package.json'));
      const shim = await io.readText?.(candidate);
      const entry = agent === 'pi' ? 'dist/bundle/cli.js' : 'dist/main.mjs';
      if (!isRecord(metadata) || metadata.name !== packageName || !shim || !(agent === 'pi' ? isPiShim(shim) : isKimiCodeShim(shim))
        || !(await io.isFile(win32.join(packageRoot, entry)))) continue;
      const version = typeof metadata.version === 'string' && /^\d+\.\d+\.\d+(?:[-+][\w.-]+)?$/.test(metadata.version) ? metadata.version : undefined;
      return { state: 'detected', executablePath: candidate, version, detail: agent === 'pi'
        ? '已发现当前 Node 版 Pi；仍需原客户端加载扩展并产生事件。' : '已发现 Node 版 Kimi Code；仍需原客户端加载配置并产生事件。' };
    }
    return { state: 'unconfirmed', executablePath, detail: agent === 'pi'
      ? '发现同名 Pi 命令，但尚未确认是当前官方 Node 发行包；请核对版本和扩展接口。'
      : '发现同名 Kimi 命令，但尚未确认是 Node 版 Kimi Code；不能套用 Python CLI 协议。' };
  }
  const native = agent === 'codex' ? found.find(path => path?.toLowerCase().endsWith('.exe')) : undefined;
  return { state: 'detected', executablePath: native ?? executablePath, detail: '已发现客户端入口；文件存在不代表版本兼容或 hook 已启用。' };
}
