import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { lstat, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { isAbsolute, join, relative, sep, win32 } from 'node:path';
import { isRecord } from '../core/protocol';

export interface HookTrustSnapshot {
  state: 'granted' | 'required' | 'unavailable';
  configuredCount: number; trustedCount: number; fingerprint?: string; reason?: string;
}
const unavailable = (reason: string): HookTrustSnapshot => ({ state: 'unavailable', configuredCount: 0, trustedCount: 0, reason });

/** 只核对精确匹配的自有命令；响应正文和第三方 hook 定义不进入摘要。 */
export function parseCodexTrust(response: unknown, commands: readonly string[], cwd: string): HookTrustSnapshot {
  const expected = new Set(commands);
  if (!expected.size || expected.size !== commands.length || commands.some(value => !value)) return unavailable('没有可核对的自有 hook 命令。');
  if (!isRecord(response) || !Array.isArray(response.data) || response.data.length !== 1) return unavailable('Codex 返回了未知的授权状态格式。');
  const entry = response.data[0];
  if (!isRecord(entry) || typeof entry.cwd !== 'string' || win32.normalize(entry.cwd).toLowerCase() !== win32.normalize(cwd).toLowerCase()
    || !Array.isArray(entry.hooks) || !Array.isArray(entry.errors) || !Array.isArray(entry.warnings)
    || !entry.warnings.every(value => typeof value === 'string') || entry.errors.length) {
    return unavailable('Codex 未能读取指定目录的 hook 配置。');
  }
  const definitions = new Map<string, string>(); let trustedCount = 0;
  for (const hook of entry.hooks) {
    if (!isRecord(hook) || typeof hook.command !== 'string' || !expected.has(hook.command)) continue;
    if (definitions.has(hook.command) || hook.handlerType !== 'command' || typeof hook.enabled !== 'boolean'
      || typeof hook.isManaged !== 'boolean' || typeof hook.currentHash !== 'string' || !hook.currentHash.trim() || hook.currentHash.includes('\0')
      || !['trusted', 'untrusted', 'modified', 'managed'].includes(String(hook.trustStatus))) return unavailable('Codex 返回了重复或不完整的自有 hook 定义。');
    if (!hook.enabled || hook.isManaged || hook.trustStatus === 'managed') return unavailable('自有 hook 未启用或受管理策略控制。');
    definitions.set(hook.command, hook.currentHash);
    if (hook.trustStatus === 'trusted') trustedCount++;
  }
  if (definitions.size !== expected.size) return unavailable('Codex 尚未读取全部自有 hook 配置。');
  const fingerprint = createHash('sha256').update(JSON.stringify([...definitions].sort(([a], [b]) => a.localeCompare(b)))).digest('hex');
  return { state: trustedCount === expected.size ? 'granted' : 'required', configuredCount: expected.size, trustedCount, fingerprint,
    ...(trustedCount === expected.size ? {} : { reason: '请在 Codex 中审阅并启用 XIsland hook；本应用不会自动授予信任。' }) };
}

export interface CodexTrustOptions { testScript?: string; tempHome?: string; timeoutMs?: number }
function contained(root: string, path: string): boolean {
  const child = relative(root, path);
  return child !== '' && !isAbsolute(child) && child !== '..' && !child.startsWith('..' + sep);
}

export async function inspectCodexTrust(binary: string, cwd: string, commands: readonly string[], options: CodexTrustOptions = {}): Promise<HookTrustSnapshot> {
  if (!commands.length) return unavailable('尚未配置可检查的自有 hook。');
  if (options.timeoutMs !== undefined && (!Number.isInteger(options.timeoutMs) || options.timeoutMs < 20 || options.timeoutMs > 7000)) return unavailable('状态检查超时设置无效。');
  if (!options.testScript && (process.platform !== 'win32' || !/\.exe$/i.test(binary))) return unavailable('当前入口无法直接检查 Codex 信任，请在原客户端查看 /hooks。');
  if (!isAbsolute(binary) || !isAbsolute(cwd)) return unavailable('Codex 检查入口无效。');
  if (options.testScript) {
    try {
      if (!options.tempHome || !isAbsolute(options.tempHome) || !isAbsolute(options.testScript)) return unavailable('测试状态检查必须使用隔离临时目录。');
      const home = await realpath(options.tempHome), temporary = await realpath(tmpdir());
      const script = await realpath(options.testScript), directory = await realpath(cwd);
      if (!contained(temporary, home) || !contained(home, script) || !(directory === home || contained(home, directory))
        || await realpath(binary) !== await realpath(process.execPath) || (await lstat(options.testScript)).isSymbolicLink()) return unavailable('测试状态检查路径越过隔离目录。');
    } catch { return unavailable('测试状态检查入口无效。'); }
  } else {
    try { const info = await lstat(binary); if (!info.isFile() || info.isSymbolicLink()) return unavailable('Codex 检查需要真实可执行文件。'); }
    catch { return unavailable('Codex 检查入口不存在。'); }
  }
  return new Promise(resolve => {
    const environment = { ...process.env }; delete environment.NODE_OPTIONS; delete environment.NODE_PATH;
    if (options.tempHome) {
      environment.HOME = options.tempHome; environment.USERPROFILE = options.tempHome;
      environment.CODEX_HOME = join(options.tempHome, '.codex');
    }
    const child = spawn(binary, options.testScript ? [options.testScript] : ['app-server', '--stdio'],
      { cwd, shell: false, windowsHide: true, env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
    let pending = Buffer.alloc(0), bytes = 0, stage = 1, finished = false;
    let result: HookTrustSnapshot | undefined, forceTimer: ReturnType<typeof setTimeout> | undefined, settleTimer: ReturnType<typeof setTimeout> | undefined;
    const finish = (result: HookTrustSnapshot) => {
      if (finished) return; finished = true; clearTimeout(timer);
      completeResult(result);
    };
    const completeResult = (snapshot: HookTrustSnapshot) => {
      result = snapshot; child.stdin.destroy(); child.stdout.destroy(); child.stderr.destroy(); child.kill();
      forceTimer = setTimeout(() => child.kill('SIGKILL'), 100);
      settleTimer = setTimeout(() => resolve(snapshot), 300);
    };
    const timer = setTimeout(() => finish(unavailable('读取 Codex 信任状态超时。')), options.timeoutMs ?? 7000);
    const send = (packet: unknown) => { if (!finished) child.stdin.write(JSON.stringify(packet) + '\n'); };
    child.on('error', () => finish(unavailable('无法启动 Codex 状态检查。')));
    child.on('close', () => {
      clearTimeout(timer); clearTimeout(forceTimer); clearTimeout(settleTimer);
      if (!finished) finished = true;
      resolve(result ?? unavailable('Codex 在返回状态前已退出。'));
    });
    child.stdin.on('error', () => finish(unavailable('Codex 检查连接已关闭。')));
    child.stderr.resume();
    child.stdout.on('data', (chunk: Buffer) => {
      if (finished) return;
      bytes += chunk.length;
      if (bytes > 4 * 1024 * 1024) { finish(unavailable('Codex 状态响应超过大小上限。')); return; }
      pending = Buffer.concat([pending, chunk]);
      let newline: number;
      while (!finished && (newline = pending.indexOf(10)) >= 0) {
        const line = pending.subarray(0, newline); pending = pending.subarray(newline + 1);
        let packet: unknown;
        try { packet = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line)); }
        catch { finish(unavailable('Codex 状态响应不是有效 JSON。')); return; }
        if (!isRecord(packet) || packet.id !== stage) continue;
        if (packet.error !== undefined || !isRecord(packet.result)) { finish(unavailable('当前 Codex 不支持此状态查询。')); return; }
        if (stage === 1) {
          stage = 2; send({ method: 'initialized', params: {} });
          send({ id: 2, method: 'hooks/list', params: { cwds: [cwd] } });
        } else finish(parseCodexTrust(packet.result, commands, cwd));
      }
    });
    send({ id: 1, method: 'initialize', params: { clientInfo: { name: 'xisland-windows-hook-status', version: '1' }, capabilities: { experimentalApi: true } } });
  });
}
