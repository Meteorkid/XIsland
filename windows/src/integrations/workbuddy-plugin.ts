import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, readdir, realpath, rmdir, unlink, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve, sep, win32 } from 'node:path';
import { WORKBUDDY_HOOK_EVENTS } from '../adapters/workbuddy';
import { windowsHookCommand } from './plan';
import { discoverClient, type ClientDiscovery } from './discovery';

export interface WorkBuddyExportResult {
  agent: 'workbuddy'; exportedPath: string; eventCount: number; observationOnly: true; clientVerified: false; runtimeReady: true;
}

export interface WorkBuddySetupOptions {
  tempHome?: string; nodeExecutable?: string; hookScript?: string; bridgeExecutable?: string; client?: ClientDiscovery;
}
export interface WorkBuddySetupStatus {
  agent: 'workbuddy'; client: ClientDiscovery; runtimeReady: boolean; exportedPath?: string; needsPreparation: boolean;
}

export function workBuddyPluginFiles(nodeExecutable: string, hookScript: string): Record<string, string> {
  const manifest = { name: 'xisland-workbuddy-observer', version: '0.1.1',
    description: 'XIsland Windows observation hooks; no permission decisions. Windows client acceptance pending.' };
  const hooks = Object.fromEntries(WORKBUDDY_HOOK_EVENTS.map(event => [event, [{ hooks: [{ type: 'command',
    command: windowsHookCommand(nodeExecutable, hookScript, 'workbuddy', event), timeout: 10 }] }]]));
  const json = (value: unknown) => JSON.stringify(value, null, 2) + '\n';
  return {
    '.codebuddy-plugin/plugin.json': json(manifest),
    '.codebuddy-plugin/marketplace.json': json({ name: 'xisland-workbuddy-local', owner: { name: 'XIsland' },
      plugins: [{ ...manifest, source: './' }] }),
    'hooks/hooks.json': json({ hooks }),
    'README.txt': ['XIsland Windows · WorkBuddy 观察插件', '',
      '在 WorkBuddy 插件页面的「添加市场」入口选择整个目录，再安装并启用 xisland-workbuddy-observer。',
      '如果当前版本的入口不接受本地目录，请回传版本和错误；不要手动覆盖客户端配置。',
      '本次只导出插件，尚未安装、启用或证明 WorkBuddy 已加载。Windows 原生客户端仍待验收。',
      '观察 11 类事件；审批、回答和工具授权由 WorkBuddy 本身处理。',
      'Stop 仅表示准备停止；FinalStop 才按原生原因更新状态。子代理结束不结束父任务。',
      '仅限本地任务；云端任务不保证能连接此电脑的 XIsland。',
      '插件引用当前 XIsland 安装中的 Node、hook 与 bridge；移动或卸载应用后需重新导出。',
      '从旧观察插件升级：在 WorkBuddy 移除旧插件和旧本地市场，再导入本次导出目录；不要只移动旧目录。',
      '观察启动器会限时结束并保持空输出，不使用可能注入模型上下文的异步握手。',
      '卸载接入：在 WorkBuddy 中停用并卸载该插件，然后移除该本地市场。',
      '合同依据：WorkBuddy 5.7.6 / 5.7.7 的公开安装资源；其他版本需单独验证。',
      'https://www.codebuddy.cn/docs/workbuddy/Plugins', ''].join('\r\n'),
  };
}

/** 只向全新目录导出；不访问 WorkBuddy 设置、市场数据库或信任记录。 */
export async function writeWorkBuddyPlugin(destination: string, files: Record<string, string>): Promise<void> {
  if (!isAbsolute(destination) || destination.includes('\0')) throw new Error('invalid_export_path');
  const expected = ['.codebuddy-plugin/plugin.json', '.codebuddy-plugin/marketplace.json', 'hooks/hooks.json', 'README.txt'];
  if (Object.keys(files).length !== expected.length || expected.some(path => typeof files[path] !== 'string')) throw new Error('invalid_plugin_files');
  const parent = await realpath(dirname(destination));
  if (parent !== dirname(destination)) throw new Error('export_parent_not_canonical');
  await mkdir(destination, { mode: 0o700 });
  const created: string[] = [], directories: string[] = [];
  try {
    for (const dir of ['.codebuddy-plugin', 'hooks']) {
      const path = join(destination, dir); await mkdir(path, { mode: 0o700 }); directories.push(path);
    }
    for (const [name, content] of Object.entries(files)) {
      const path = join(destination, name); await writeFile(path, content, { encoding: 'utf8', flag: 'wx', mode: 0o600 }); created.push(path);
    }
  } catch (error) {
    for (const path of created.reverse()) await unlink(path).catch(() => {});
    for (const path of directories.reverse()) await rmdir(path).catch(() => {});
    await rmdir(destination).catch(() => {});
    throw error;
  }
}

export async function exportWorkBuddyPlugin(): Promise<WorkBuddyExportResult> {
  if (process.platform !== 'win32') throw new Error('unsupported_platform');
  const script = resolve(process.argv[1]!), node = process.execPath;
  for (const path of [node, script, join(dirname(script), 'xisland-bridge.exe')]) {
    const info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink() || info.size === 0) throw new Error('runtime_missing');
  }
  const files = workBuddyPluginFiles(node, script);
  const base = join(homedir(), 'XIsland-Plugins');
  try { await mkdir(base, { mode: 0o700 }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error; }
  const info = await lstat(base);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('unsafe_export_directory');
  const destination = join(await realpath(base), `workbuddy-${randomUUID()}`);
  await writeWorkBuddyPlugin(destination, files);
  return { agent: 'workbuddy', exportedPath: destination, eventCount: WORKBUDDY_HOOK_EVENTS.length,
    observationOnly: true, clientVerified: false, runtimeReady: true };
}

const setupErrors = new Set(['unsupported_platform', 'test_override_forbidden', 'test_home_not_isolated',
  'test_resource_not_isolated', 'runtime_missing', 'unsafe_export_directory', 'modified_workbuddy_artifact']);
const errorCode = (error: unknown): string | undefined => error && typeof error === 'object' && 'code' in error
  && typeof error.code === 'string' ? error.code : undefined;
const inside = (root: string, path: string): boolean => {
  const child = relative(root, path); return !!child && !isAbsolute(child) && child !== '..' && !child.startsWith('..' + sep);
};
function setupError(error: unknown): Error {
  return new Error(error instanceof Error && setupErrors.has(error.message) ? error.message : 'workbuddy_setup_failed');
}

async function setupContext(options: WorkBuddySetupOptions) {
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
  const files = workBuddyPluginFiles(commandPath(node), commandPath(script));
  const hash = createHash('sha256');
  for (const path of Object.keys(files).sort()) hash.update(path).update('\0').update(files[path]!).update('\0');
  const base = join(home, 'XIsland-Plugins'), destination = join(base, `workbuddy-${hash.digest('hex')}`);
  return { home, base, destination, files, runtimeReady };
}

/** 检查每一级目录，状态读取不会创建目录或沿链接进入其他位置。 */
async function setupDirectory(path: string, create = false): Promise<boolean> {
  const parent = dirname(path);
  if (parent !== path && !await setupDirectory(parent, create)) return false;
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

async function existingSetup(destination: string, files: Record<string, string>): Promise<boolean> {
  if (!await setupDirectory(dirname(destination))) return false;
  try {
    const info = await lstat(destination);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('modified_workbuddy_artifact');
  } catch (error) { if (errorCode(error) === 'ENOENT') return false; throw error; }
  const expected = new Set([...Object.keys(files), '.codebuddy-plugin', 'hooks']);
  const actual = new Set<string>();
  async function verify(folder: string, prefix = ''): Promise<void> {
    for (const name of await readdir(folder)) {
      const relativePath = prefix + name, path = join(folder, name), info = await lstat(path);
      if (!expected.has(relativePath) || info.isSymbolicLink()) throw new Error('modified_workbuddy_artifact');
      actual.add(relativePath);
      if (files[relativePath] === undefined) {
        if (!info.isDirectory()) throw new Error('modified_workbuddy_artifact');
        await verify(path, relativePath + '/');
      } else {
        const bytes = Buffer.from(files[relativePath]!);
        if (!info.isFile() || info.size !== bytes.length) throw new Error('modified_workbuddy_artifact');
        const file = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
        try {
          const opened = await file.stat();
          if (!opened.isFile() || opened.dev !== info.dev || opened.ino !== info.ino) throw new Error('modified_workbuddy_artifact');
          const buffer = Buffer.alloc(bytes.length + 1), read = await file.read(buffer, 0, buffer.length, 0);
          if (read.bytesRead !== bytes.length || !buffer.subarray(0, read.bytesRead).equals(bytes)) throw new Error('modified_workbuddy_artifact');
        } finally { await file.close(); }
      }
    }
  }
  await verify(destination);
  if (actual.size !== expected.size) throw new Error('modified_workbuddy_artifact');
  return true;
}

/** 只读检查 XIsland 自有产物和固定客户端入口，不读取 WorkBuddy 配置或信任记录。 */
export async function workBuddySetupStatus(options: WorkBuddySetupOptions = {}): Promise<WorkBuddySetupStatus> {
  try {
    const context = await setupContext(options);
    const prepared = await existingSetup(context.destination, context.files);
    const client = options.tempHome ? options.client ?? { state: 'not_found' as const, detail: '隔离测试未提供客户端入口。' }
      : await discoverClient('workbuddy', { home: context.home, path: process.env.PATH ?? '', appData: process.env.APPDATA,
        localAppData: process.env.LOCALAPPDATA, programFiles: process.env.ProgramFiles });
    return { agent: 'workbuddy', client, runtimeReady: context.runtimeReady, needsPreparation: !prepared,
      ...(prepared ? { exportedPath: context.destination } : {}) };
  } catch (error) { throw setupError(error); }
}

/** 内容相同就复用；目标已存在时只核验，从不覆盖用户修改。 */
export async function prepareWorkBuddyPlugin(options: WorkBuddySetupOptions = {}): Promise<WorkBuddyExportResult> {
  try {
    const context = await setupContext(options);
    if (!context.runtimeReady) throw new Error('runtime_missing');
    if (!await existingSetup(context.destination, context.files)) {
      await setupDirectory(context.base, true);
      try { await writeWorkBuddyPlugin(context.destination, context.files); }
      catch (error) { if (errorCode(error) !== 'EEXIST') throw error; }
      if (!await existingSetup(context.destination, context.files)) throw new Error('modified_workbuddy_artifact');
    }
    return { agent: 'workbuddy', exportedPath: context.destination, eventCount: WORKBUDDY_HOOK_EVENTS.length,
      observationOnly: true, clientVerified: false, runtimeReady: true };
  } catch (error) { throw setupError(error); }
}
