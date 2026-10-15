import { randomUUID } from 'node:crypto';
import { lstat, mkdir, realpath, rmdir, unlink, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { WORKBUDDY_HOOK_EVENTS } from '../adapters/workbuddy';
import { windowsHookCommand } from './plan';

export interface WorkBuddyExportResult {
  agent: 'workbuddy'; exportedPath: string; eventCount: number; observationOnly: true; clientVerified: false; runtimeReady: true;
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
