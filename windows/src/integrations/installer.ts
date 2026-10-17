import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, realpath, rename, unlink } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { adapterFor, type ConfigurableAgent } from '../adapters/registry';
import { createIntegrationPlan, integrationPlanSummary, type IntegrationPlan } from './plan';
import { isRecord } from '../core/protocol';

export const MAX_CONFIG_BYTES = 1024 * 1024;
export type IntegrationOperation = 'install' | 'uninstall';
export class IntegrationError extends Error {
  constructor(readonly code: string, message: string) { super(message); this.name = 'IntegrationError'; }
}
export interface InstallerOptions {
  /** 测试只能显式指定已存在的独立临时目录；不会将此选项暴露给生产 CLI。 */
  tempHome?: string;
  resourceDirectory?: string;
  nodeExecutable?: string;
  beforeReplace?: () => Promise<void>;
  replaceFile?: (source: string, target: string) => Promise<void>;
}
interface Location {
  agent: ConfigurableAgent;
  home: string; configPath: string; node: string; script: string; bridge: string;
  planHome: string; planNode: string; planScript: string;
  droidStandalone: boolean;
}
interface Snapshot { exists: boolean; bytes: Buffer; revision: string; configuration?: Record<string, unknown> }
export type InstallationSummary = Omit<IntegrationPlan, 'nextConfig'> & { revision: string; runtimeReady: boolean };

const files: Record<ConfigurableAgent, string[]> = {
  claude_code: ['.claude', 'settings.json'], codex: ['.codex', 'hooks.json'],
  cursor: ['.cursor', 'hooks.json'], gemini_cli: ['.gemini', 'settings.json'],
  windsurf: ['.codeium', 'windsurf', 'hooks.json'], trae_cn: ['.trae-cn', 'hooks.json'],
  qwen: ['.qwen', 'settings.json'], code_buddy: ['.codebuddy', 'settings.json'], droid: ['.factory', 'settings.json'],
};
const errorCode = (error: unknown) => isRecord(error) && typeof error.code === 'string' ? error.code : undefined;
function hash(bytes?: Buffer): string {
  return createHash('sha256').update(bytes === undefined ? 'missing\0' : 'present\0').update(bytes ?? Buffer.alloc(0)).digest('hex');
}
export function configurationRevision(agent: string, path: string, revision: string): string {
  return agent === 'droid' ? createHash('sha256').update(path).update('\0').update(revision).digest('hex') : revision;
}
function reviewRevision(paths: Location, revision: string): string {
  return configurationRevision(paths.agent, paths.configPath, revision);
}
async function verifySelectedConfiguration(paths: Location): Promise<void> {
  if (paths.agent !== 'droid') return;
  let standalone = false;
  try { await lstat(join(paths.home, '.factory', 'hooks.json')); standalone = true; }
  catch (error) { if (errorCode(error) !== 'ENOENT') throw error; }
  if (standalone !== paths.droidStandalone) throw new IntegrationError('revision_conflict', 'Droid 的有效配置位置发生变化，请重新查看计划。');
}
function contained(root: string, path: string): boolean {
  const child = relative(root, path);
  return child !== '' && !isAbsolute(child) && child !== '..' && !child.startsWith('..' + sep);
}
async function canonicalReference(path: string): Promise<string> {
  try { return await realpath(path); }
  catch (error) {
    if (errorCode(error) !== 'ENOENT' || dirname(path) === path) throw error;
    return join(await canonicalReference(dirname(path)), basename(path));
  }
}

async function location(agent: ConfigurableAgent, options: InstallerOptions): Promise<Location> {
  adapterFor(agent);
  if (!options.tempHome && process.platform !== 'win32') throw new IntegrationError('unsupported_platform', '此安装服务只操作 Windows 配置。');
  if (!options.tempHome && (options.resourceDirectory || options.nodeExecutable || options.beforeReplace || options.replaceFile)) {
    throw new IntegrationError('test_override_forbidden', '生产安装不接受测试路径或文件操作覆盖。');
  }
  const home = await realpath(options.tempHome ?? homedir());
  if (options.tempHome && (!isAbsolute(options.tempHome) || !contained(await realpath(tmpdir()), home))) {
    throw new IntegrationError('test_home_not_isolated', '测试 home 必须是临时目录中的独立现有目录。');
  }
  const script = options.tempHome ? join(options.resourceDirectory ?? join(home, 'resources'), 'xisland-hook.cjs') : resolve(process.argv[1]!);
  const node = options.nodeExecutable ?? process.execPath;
  const bridge = join(dirname(script), 'xisland-bridge.exe');
  if (options.tempHome) {
    const references = [script, node, bridge];
    const canonical = await Promise.all(references.map(canonicalReference));
    if (!references.every(isAbsolute) || !canonical.every(path => contained(home, path))) {
      throw new IntegrationError('test_resource_not_isolated', '测试资源必须位于同一隔离 home 内。');
    }
  }
  let configPath = join(home, ...files[agent]);
  let droidStandalone = false;
  if (agent === 'droid') {
    const standalone = join(home, '.factory', 'hooks.json');
    try { await lstat(standalone); configPath = standalone; droidStandalone = true; }
    catch (error) { if (errorCode(error) !== 'ENOENT') throw error; }
  }
  return { agent, home, configPath, node, script, bridge, droidStandalone,
    // 非 Windows 测试只模拟磁盘；配置内 Windows 启动路径为明确的 fixture，不执行它们。
    planHome: options.tempHome ? 'C:\\XIsland-Test-Home' : home,
    planNode: options.tempHome ? 'C:\\XIsland-Test-Resources\\node.exe' : node,
    planScript: options.tempHome ? 'C:\\XIsland-Test-Resources\\xisland-hook.cjs' : script };
}

async function safeDirectory(home: string, directory: string, create = false): Promise<void> {
  if (!contained(home, directory)) throw new IntegrationError('unsafe_path', '配置路径越过用户目录。');
  let current = home;
  for (const segment of relative(home, directory).split(sep)) {
    current = join(current, segment);
    try {
      const info = await lstat(current);
      if (info.isSymbolicLink() || !info.isDirectory()) throw new IntegrationError('unsafe_path', '配置目录不能是链接或普通文件。');
    } catch (error) {
      if (errorCode(error) !== 'ENOENT') throw error;
      if (!create) return;
      try { await mkdir(current, { mode: 0o700 }); }
      catch (mkdirError) { if (errorCode(mkdirError) !== 'EEXIST') throw mkdirError; }
      const info = await lstat(current);
      if (info.isSymbolicLink() || !info.isDirectory()) throw new IntegrationError('unsafe_path', '配置目录发生变化。');
    }
  }
}

async function readSnapshot(path: string): Promise<Snapshot> {
  let info;
  try { info = await lstat(path); }
  catch (error) {
    if (errorCode(error) === 'ENOENT') return { exists: false, bytes: Buffer.alloc(0), revision: hash() };
    throw error;
  }
  if (!info.isFile() || info.isSymbolicLink()) throw new IntegrationError('unsafe_path', '配置必须为普通文件，不能是链接。');
  if (info.size > MAX_CONFIG_BYTES) throw new IntegrationError('config_too_large', '配置超过 1 MiB 上限，未修改原文件。');
  const file = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const opened = await file.stat();
    if (!opened.isFile() || opened.dev !== info.dev || opened.ino !== info.ino) throw new IntegrationError('revision_conflict', '读取时配置已改变，请重新生成计划。');
    const chunks: Buffer[] = []; let size = 0;
    while (true) {
      const chunk = Buffer.alloc(Math.min(16384, MAX_CONFIG_BYTES + 1 - size));
      const read = await file.read(chunk, 0, chunk.length, null);
      if (!read.bytesRead) break;
      size += read.bytesRead;
      if (size > MAX_CONFIG_BYTES) throw new IntegrationError('config_too_large', '配置超过 1 MiB 上限，未修改原文件。');
      chunks.push(chunk.subarray(0, read.bytesRead));
    }
    const bytes = Buffer.concat(chunks, size);
    let configuration: unknown;
    try { configuration = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
    catch { throw new IntegrationError('invalid_json', '当前配置不是有效 UTF-8 JSON，未修改原文件。'); }
    if (!isRecord(configuration)) throw new IntegrationError('invalid_json', '配置根节点必须是 JSON 对象，未修改原文件。');
    return { exists: true, bytes, revision: hash(bytes), configuration };
  } finally { await file.close(); }
}

async function runtimeReady(paths: Location): Promise<boolean> {
  for (const path of [paths.node, paths.script, paths.bridge]) {
    try { const info = await lstat(path); if (!info.isFile() || info.isSymbolicLink() || info.size === 0) return false; }
    catch { return false; }
  }
  return /\.exe$/i.test(paths.planNode) && /\.cjs$/i.test(paths.planScript);
}

function makePlan(agent: ConfigurableAgent, operation: IntegrationOperation, paths: Location, snapshot: Snapshot): IntegrationPlan {
  const plan = createIntegrationPlan({ agent, operation, configuration: snapshot.configuration,
    homeDirectory: paths.planHome, nodeExecutable: paths.planNode, hookScript: paths.planScript, droidStandalone: paths.droidStandalone });
  return { ...plan, configPath: paths.configPath, backup: { ...plan.backup, directory: dirname(paths.configPath) } };
}

export async function getIntegrationStatus(agent: ConfigurableAgent, options: InstallerOptions = {}) {
  if (process.platform !== 'win32' && !options.tempHome) {
    return { agent, platformSupported: false, runtimeReady: false, installed: false, managedHandlers: 0,
      warnings: ['请在 Windows 客户端配置接入；当前平台不会修改用户配置。'] };
  }
  const paths = await location(agent, options);
  await safeDirectory(paths.home, dirname(paths.configPath));
  const snapshot = await readSnapshot(paths.configPath), ready = await runtimeReady(paths);
  const removal = makePlan(agent, 'uninstall', paths, snapshot);
  const installation = makePlan(agent, 'install', paths, snapshot);
  return { agent, platformSupported: true, configPath: paths.configPath, revision: reviewRevision(paths, snapshot.revision), runtimeReady: ready,
    installed: !installation.changed, managedHandlers: removal.removedHandlers,
    warnings: installation.warnings.map(warning => warning.startsWith('此计划未写入') ? '配置文件状态不代表客户端已加载；请确认 hook 信任与实际事件。' : warning) };
}

export async function planIntegration(agent: ConfigurableAgent, operation: IntegrationOperation, options: InstallerOptions = {}): Promise<InstallationSummary> {
  const paths = await location(agent, options);
  await safeDirectory(paths.home, dirname(paths.configPath));
  const snapshot = await readSnapshot(paths.configPath), ready = await runtimeReady(paths);
  if (operation === 'install' && !ready) throw new IntegrationError('runtime_missing', 'Node、hook 或 bridge 文件缺失，不能安装接入。');
  const plan = makePlan(agent, operation, paths, snapshot);
  return { ...integrationPlanSummary(plan), revision: reviewRevision(paths, snapshot.revision), runtimeReady: ready };
}

async function exclusiveWrite(path: string, bytes: Buffer): Promise<void> {
  const handle = await open(path, 'wx', 0o600);
  try { await handle.writeFile(bytes); await handle.sync(); }
  finally { await handle.close(); }
}

async function commit(paths: Location, original: Snapshot, replacement: Buffer, options: InstallerOptions): Promise<{ backupId?: string; revision: string }> {
  if (replacement.length > MAX_CONFIG_BYTES) throw new IntegrationError('config_too_large', '合并后的配置超过大小上限，未写入。');
  const temporary = paths.configPath + '.xisland-tmp-' + randomUUID();
  const backupId = original.exists ? `${basename(paths.configPath)}.xisland-backup-${Date.now()}-${randomUUID()}.bak` : undefined;
  try {
    if (backupId) await exclusiveWrite(join(dirname(paths.configPath), backupId), original.bytes);
    await exclusiveWrite(temporary, replacement);
    await options.beforeReplace?.();
    await verifySelectedConfiguration(paths);
    await safeDirectory(paths.home, dirname(paths.configPath));
    const current = await readSnapshot(paths.configPath);
    if (current.revision !== original.revision) throw new IntegrationError('revision_conflict', '配置已被其他程序修改，请重新查看计划。');
    // Windows 上 rename 使用替换语义；若目标被占用而失败，绝不先删除原文件。
    await (options.replaceFile ?? rename)(temporary, paths.configPath);
    return { backupId, revision: hash(replacement) };
  } finally { await unlink(temporary).catch(error => { if (errorCode(error) !== 'ENOENT') throw error; }); }
}

async function withLock<T>(paths: Location, operation: () => Promise<T>): Promise<T> {
  await safeDirectory(paths.home, dirname(paths.configPath), true);
  const lockPath = paths.configPath + '.xisland-lock';
  let lock;
  try { lock = await open(lockPath, 'wx', 0o600); }
  catch (error) {
    if (errorCode(error) === 'EEXIST') throw new IntegrationError('installation_busy', '另一个安装操作持有锁，请稍后重试。');
    throw error;
  }
  try { return await operation(); }
  finally { await lock.close(); await unlink(lockPath); }
}

export async function applyIntegration(agent: ConfigurableAgent, operation: IntegrationOperation, expectedRevision: string, options: InstallerOptions = {}) {
  if (!/^[a-f0-9]{64}$/.test(expectedRevision)) throw new IntegrationError('revision_required', '写入前必须提供已确认计划的 revision。');
  const paths = await location(agent, options);
  return withLock(paths, async () => {
    const snapshot = await readSnapshot(paths.configPath);
    if (reviewRevision(paths, snapshot.revision) !== expectedRevision) throw new IntegrationError('revision_conflict', '配置已改变，请重新查看并确认计划。');
    await verifySelectedConfiguration(paths);
    const ready = await runtimeReady(paths);
    if (operation === 'install' && !ready) throw new IntegrationError('runtime_missing', 'Node、hook 或 bridge 文件缺失，未写入配置。');
    const plan = makePlan(agent, operation, paths, snapshot);
    if (!plan.changed) return { ...integrationPlanSummary(plan), revision: reviewRevision(paths, snapshot.revision), runtimeReady: ready, applied: false };
    const result = await commit(paths, snapshot, Buffer.from(JSON.stringify(plan.nextConfig, null, 2) + '\n'), options);
    return { ...integrationPlanSummary(plan), ...result, revision: reviewRevision(paths, result.revision), runtimeReady: ready, applied: true,
      warnings: plan.warnings.map(warning => warning.startsWith('此计划未写入') ? '配置已写入；仍需在客户端确认 hook 信任与实际事件。' : warning) };
  });
}

/** 显式回滚仍需当前 revision，且为回滚前状态再留一份备份。 */
export async function rollbackIntegration(agent: ConfigurableAgent, backupId: string, expectedRevision: string, options: InstallerOptions = {}) {
  const paths = await location(agent, options);
  if (basename(backupId) !== backupId || !backupId.startsWith(basename(paths.configPath) + '.xisland-backup-') || !backupId.endsWith('.bak')) {
    throw new IntegrationError('invalid_backup', '备份必须属于当前客户端配置。');
  }
  return withLock(paths, async () => {
    const snapshot = await readSnapshot(paths.configPath);
    if (reviewRevision(paths, snapshot.revision) !== expectedRevision) throw new IntegrationError('revision_conflict', '配置已改变，不能覆盖为旧备份。');
    const backup = await readSnapshot(join(dirname(paths.configPath), backupId));
    if (!backup.exists) throw new IntegrationError('invalid_backup', '指定备份不存在。');
    const result = await commit(paths, snapshot, backup.bytes, options);
    return { agent, operation: 'rollback' as const, configPath: paths.configPath, applied: true, ...result, revision: reviewRevision(paths, result.revision) };
  });
}
