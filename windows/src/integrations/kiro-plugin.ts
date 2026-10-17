import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, readdir, realpath, rmdir, unlink } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve, sep, win32 } from 'node:path';
import { KIRO_HOOK_EVENTS } from '../adapters/kiro';
import { discoverClient, type ClientDiscovery } from './discovery';
import { windowsHookCommand } from './plan';

export const KIRO_DOCUMENTED_CLI_VERSION = '2.31.0';
export const KIRO_HOOK_FILE_NAME = 'xisland-observer.json';
export interface KiroSetupOptions {
  tempHome?: string; nodeExecutable?: string; hookScript?: string; bridgeExecutable?: string; client?: ClientDiscovery;
}
export interface KiroExportResult {
  agent: 'kiro'; exportedPath: string; eventCount: number; observationOnly: true; clientVerified: false; runtimeReady: true;
}
export interface KiroSetupStatus {
  agent: 'kiro'; client: ClientDiscovery; runtimeReady: boolean; exportedPath?: string; needsPreparation: boolean;
}

/** 仅生成独立 hook 文件，既不写 Kiro 配置，也不宣称检测到了模板基线版本。 */
export function kiroPluginFiles(nodeExecutable: string, hookScript: string): Record<string, string> {
  const document = { version: 'v1', hooks: KIRO_HOOK_EVENTS.map(event => ({ name: `XIsland:KiroV3:${event}`,
    trigger: event, enabled: true, action: { type: 'command', command: windowsHookCommand(nodeExecutable, hookScript, 'kiro', event) } })) };
  return {
    [KIRO_HOOK_FILE_NAME]: JSON.stringify(document, null, 2) + '\n',
    'README.txt': ['XIsland Windows · Kiro CLI V3 观察配置', '',
      `模板基线：Kiro CLI ${KIRO_DOCUMENTED_CLI_VERSION}，明确使用 V3；这不是本机版本探测结果。`,
      '本目录仅准备文件，尚未安装、启用或证明客户端加载。Windows 原生客户端与 hook 宿主 shell 仍待实机验收。',
      '先核对实际 CLI 版本和 V3 引擎，再审阅 xisland-observer.json 中的命令。',
      '由用户将该 JSON 放入所选 Kiro CLI 全局目录的 hooks 子目录；默认是用户主目录下 .kiro/hooks/。',
      '若启动 Kiro 的环境设置了 KIRO_HOME，使用该目录下的 hooks/；已有同名文件先备份，不自动覆盖。',
      '它是独立 hook 文档，不是 settings.json，也不是 agent 配置。只选一个作用域，避免重复上报。',
      '在匹配的 2.31.0 CLI 中使用 kiro-cli chat --v3，并在新会话中通过 /config 核对 Hooks 来源。',
      'SessionStart、UserPromptSubmit、PreToolUse、PostToolUse、Stop、SessionEnd 共六类事件只观察，不回答或授予权限。',
      'PreToolUse 仅表示准备；缺少原生工具调用 ID 时不猜测并行配对。Stop 仅表示本轮结束待确认，SessionEnd 才关闭会话。',
      '命令使用限时 PowerShell 编码启动器，保持空 stdout；安装成功不等于完整客户端验收。',
      '不覆盖 Kiro IDE、Web、Classic/V2、旧 Amazon Q；未自动启用工具信任或审批选项。',
      'https://kiro.dev/docs/hooks/', 'https://kiro.dev/docs/hooks/actions/',
      'https://kiro.dev/docs/getting-started/installation/', ''].join('\r\n'),
  };
}

const errorCode = (error: unknown): string | undefined => error && typeof error === 'object' && 'code' in error
  && typeof error.code === 'string' ? error.code : undefined;
const inside = (root: string, path: string): boolean => {
  const child = relative(root, path); return !!child && !isAbsolute(child) && child !== '..' && !child.startsWith('..' + sep);
};
function safeError(error: unknown): Error {
  const known = ['unsupported_platform', 'test_override_forbidden', 'test_home_not_isolated', 'test_resource_not_isolated',
    'runtime_missing', 'unsafe_export_directory', 'modified_kiro_artifact'];
  return new Error(error instanceof Error && known.includes(error.message) ? error.message : 'kiro_setup_failed');
}

async function context(options: KiroSetupOptions) {
  let home: string, node: string, script: string, bridge: string;
  if (options.tempHome === undefined) {
    if (Object.values(options).some(value => value !== undefined)) throw new Error('test_override_forbidden');
    if (process.platform !== 'win32') throw new Error('unsupported_platform');
    home = await realpath(homedir()); node = process.execPath; script = resolve(process.argv[1]!);
    bridge = join(dirname(script), 'xisland-bridge.exe');
  } else {
    if (!isAbsolute(options.tempHome)) throw new Error('test_home_not_isolated');
    home = await realpath(options.tempHome);
    if (!inside(await realpath(tmpdir()), home)) throw new Error('test_home_not_isolated');
    node = options.nodeExecutable ?? join(home, 'resources', 'node.exe');
    script = options.hookScript ?? join(home, 'resources', 'xisland-hook.cjs');
    bridge = options.bridgeExecutable ?? join(home, 'resources', 'xisland-bridge.exe');
    for (const path of [node, script, bridge, options.client?.executablePath].filter((value): value is string => value !== undefined)) {
      if (!isAbsolute(path) || !inside(home, path)) throw new Error('test_resource_not_isolated');
      try { if (!inside(home, await realpath(path))) throw new Error('test_resource_not_isolated'); }
      catch (error) { if (errorCode(error) !== 'ENOENT') throw error; }
    }
  }
  let runtimeReady = true;
  for (const path of [node, script, bridge]) {
    try { const info = await lstat(path); runtimeReady = runtimeReady && info.isFile() && !info.isSymbolicLink() && info.size > 0; }
    catch (error) { if (errorCode(error) !== 'ENOENT') throw error; runtimeReady = false; }
  }
  const commandPath = (path: string) => options.tempHome
    ? win32.join('C:\\XIsland-Test-Resources', relative(home, path).split(sep).join('\\')) : path;
  const files = kiroPluginFiles(commandPath(node), commandPath(script)), hash = createHash('sha256');
  for (const path of Object.keys(files).sort()) hash.update(path).update('\0').update(files[path]!).update('\0');
  const base = join(home, 'XIsland-Plugins'), destination = join(base, `kiro-${hash.digest('hex')}`);
  return { home, base, destination, files, runtimeReady };
}

async function directory(path: string, create = false): Promise<boolean> {
  const parent = dirname(path);
  if (parent !== path && !await directory(parent, create)) return false;
  try {
    const info = await lstat(path);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('unsafe_export_directory');
  } catch (error) {
    if (errorCode(error) !== 'ENOENT') throw error;
    if (!create) return false;
    try { await mkdir(path, { mode: 0o700 }); } catch (failure) { if (errorCode(failure) !== 'EEXIST') throw failure; }
    const info = await lstat(path);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('unsafe_export_directory');
  }
  return true;
}

async function existsUnmodified(destination: string, files: Record<string, string>): Promise<boolean> {
  if (!await directory(dirname(destination))) return false;
  try {
    const info = await lstat(destination);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('modified_kiro_artifact');
  } catch (error) { if (errorCode(error) === 'ENOENT') return false; throw error; }
  if (JSON.stringify((await readdir(destination)).sort()) !== JSON.stringify(Object.keys(files).sort())) throw new Error('modified_kiro_artifact');
  for (const [name, content] of Object.entries(files)) {
    const path = join(destination, name), expected = Buffer.from(content), info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink() || info.size !== expected.length) throw new Error('modified_kiro_artifact');
    const file = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
    try {
      const opened = await file.stat();
      if (!opened.isFile() || opened.dev !== info.dev || opened.ino !== info.ino) throw new Error('modified_kiro_artifact');
      const bytes = Buffer.alloc(expected.length + 1), read = await file.read(bytes, 0, bytes.length, 0);
      if (read.bytesRead !== expected.length || !bytes.subarray(0, read.bytesRead).equals(expected)) throw new Error('modified_kiro_artifact');
    } finally { await file.close(); }
  }
  return true;
}

export async function kiroSetupStatus(options: KiroSetupOptions = {}): Promise<KiroSetupStatus> {
  try {
    const current = await context(options), prepared = await existsUnmodified(current.destination, current.files);
    const client = options.tempHome ? options.client ?? { state: 'not_found' as const, detail: '隔离测试未提供 Kiro CLI 入口。' }
      : await discoverClient('kiro', { home: current.home, path: process.env.PATH ?? '', appData: process.env.APPDATA,
        localAppData: process.env.LOCALAPPDATA, programFiles: process.env.ProgramFiles });
    return { agent: 'kiro', client, runtimeReady: current.runtimeReady, needsPreparation: !prepared,
      ...(prepared ? { exportedPath: current.destination } : {}) };
  } catch (error) { throw safeError(error); }
}

export async function prepareKiroPlugin(options: KiroSetupOptions = {}): Promise<KiroExportResult> {
  try {
    const current = await context(options);
    if (!current.runtimeReady) throw new Error('runtime_missing');
    if (!await existsUnmodified(current.destination, current.files)) {
      await directory(current.base, true);
      let created = false;
      try { await mkdir(current.destination, { mode: 0o700 }); created = true; }
      catch (error) { if (errorCode(error) !== 'EEXIST') throw error; }
      if (created) {
        const written: string[] = [];
        try {
          for (const [name, content] of Object.entries(current.files)) {
            const path = join(current.destination, name), file = await open(path, 'wx', 0o600); written.push(path);
            try { await file.writeFile(content); await file.sync(); } finally { await file.close(); }
          }
        } catch (error) {
          for (const path of written) await unlink(path).catch(() => {});
          await rmdir(current.destination).catch(() => {}); throw error;
        }
      }
      if (!await existsUnmodified(current.destination, current.files)) throw new Error('modified_kiro_artifact');
    }
    return { agent: 'kiro', exportedPath: current.destination, eventCount: KIRO_HOOK_EVENTS.length,
      observationOnly: true, clientVerified: false, runtimeReady: true };
  } catch (error) { throw safeError(error); }
}
