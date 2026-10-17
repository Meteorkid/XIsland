import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, realpath, rename, unlink, type FileHandle } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve, sep, win32 } from 'node:path';
import { IntegrationError, MAX_CONFIG_BYTES, type InstallationSummary, type InstallerOptions, type IntegrationOperation } from './installer';
import { COPILOT_HOOKS_SOURCE, copilotConfigPath, copilotManagedHandlerCount, mergeCopilotConfiguration, validateCopilotConfiguration } from './copilot-config';

export interface CopilotInstallerOptions extends InstallerOptions {
  /** 测试不继承真实 COPILOT_HOME；覆盖只允许用于隔离 tempHome。 */
  environment?: Record<string, string | undefined>;
}
export type CopilotInstallationSummary = Omit<InstallationSummary, 'agent'> & { agent: 'copilot_cli' };
export type CopilotInstallationResult = CopilotInstallationSummary & { applied: boolean; backupId?: string };
interface Location { home: string; configPath: string; node: string; script: string; bridge: string; planNode: string; planScript: string }
interface Identity { dev: number; ino: number }
interface Snapshot { exists: boolean; bytes: Buffer; revision: string; configuration: Record<string, unknown>; identity?: Identity }
const errorCode = (error: unknown): string | undefined => (error as NodeJS.ErrnoException)?.code;
const digest = (bytes?: Buffer): string => createHash('sha256').update(bytes === undefined ? 'missing\0' : 'present\0').update(bytes ?? Buffer.alloc(0)).digest('hex');
const within = (root: string, path: string): boolean => {
  const child = relative(root, path);
  return child !== '' && !isAbsolute(child) && child !== '..' && !child.startsWith('..' + sep);
};
const sameIdentity = (left: Identity, right: Identity): boolean => left.dev === right.dev && left.ino === right.ino;

/** 计划与活动回执共用，避免环境目录或运行时路径变化后沿用旧确认。 */
export function copilotConfigurationRevision(configPath: string, rawRevision: string, nodeExecutable: string, hookScript: string): string {
  return createHash('sha256').update(JSON.stringify(['copilot_cli', configPath, nodeExecutable, hookScript, rawRevision])).digest('hex');
}
const revision = (paths: Location, snapshot: Snapshot): string => copilotConfigurationRevision(paths.configPath, snapshot.revision, paths.node, paths.script);

async function canonicalReference(path: string): Promise<string> {
  try { return await realpath(path); }
  catch (error) {
    if (errorCode(error) !== 'ENOENT' || dirname(path) === path) throw error;
    return join(await canonicalReference(dirname(path)), basename(path));
  }
}
async function location(options: CopilotInstallerOptions): Promise<Location> {
  if (!options.tempHome && process.platform !== 'win32') throw new IntegrationError('unsupported_platform', 'Copilot CLI 安装只支持 Windows 客户端。');
  if (!options.tempHome && Object.values(options).some(value => value !== undefined)) {
    throw new IntegrationError('test_override_forbidden', '生产安装不接受测试路径、环境或文件操作覆盖。');
  }
  const requestedHome = options.tempHome ?? homedir();
  if (!isAbsolute(requestedHome)) throw new IntegrationError('test_home_not_isolated', '测试 home 必须是独立现有临时目录。');
  const root = await lstat(requestedHome);
  if (!root.isDirectory() || root.isSymbolicLink()) throw new IntegrationError('unsafe_path', '用户目录必须是普通目录，不能是链接。');
  const home = await realpath(requestedHome);
  if (options.tempHome && !within(await realpath(tmpdir()), home)) throw new IntegrationError('test_home_not_isolated', '测试 home 必须位于临时目录的独立子目录。');
  const environment = options.tempHome ? options.environment ?? {} : process.env;
  const custom = environment.COPILOT_HOME || undefined;
  if (custom !== undefined && (!isAbsolute(custom) || /[\0\r\n]/.test(custom))) {
    throw new IntegrationError('invalid_config_home', 'COPILOT_HOME 必须是有效绝对路径；未回退到其他目录。');
  }
  if (custom !== undefined && resolve(custom) !== home && !within(home, resolve(custom))) {
    throw new IntegrationError('custom_config_outside_home', '当前安装器只支持用户目录内的 COPILOT_HOME；自定义目录未被修改。');
  }
  const configPath = copilotConfigPath(home, environment);
  if (!within(home, configPath)) throw new IntegrationError('unsafe_path', '配置路径不能越过用户目录。');
  const script = options.tempHome ? join(options.resourceDirectory ?? join(home, 'resources'), 'xisland-hook.cjs') : resolve(process.argv[1]!);
  const node = options.nodeExecutable ?? process.execPath, bridge = join(dirname(script), 'xisland-bridge.exe');
  if (options.tempHome) {
    const resources = [node, script, bridge];
    if (!resources.every(isAbsolute) || !(await Promise.all(resources.map(canonicalReference))).every(path => within(home, path))) {
      throw new IntegrationError('test_resource_not_isolated', '测试运行时必须全部位于同一隔离 home 内。');
    }
    for (const path of resources) await safeDirectory(home, dirname(path));
  }
  // 非 Windows 测试只模拟磁盘，配置内的 Windows 路径为不可执行的明确 fixture。
  const planPath = (path: string) => options.tempHome ? win32.join('C:\\XIsland-Test-Home', ...relative(home, path).split(sep)) : path;
  return { home, configPath, node, script, bridge, planNode: planPath(node), planScript: planPath(script) };
}
async function safeDirectory(home: string, directory: string, create = false): Promise<void> {
  if (directory !== home && !within(home, directory)) throw new IntegrationError('unsafe_path', '配置目录不能越过用户目录。');
  const root = await lstat(home);
  if (!root.isDirectory() || root.isSymbolicLink()) throw new IntegrationError('unsafe_path', '用户目录发生变化。');
  let current = home;
  for (const segment of relative(home, directory).split(sep).filter(Boolean)) {
    current = join(current, segment);
    try {
      const info = await lstat(current);
      if (!info.isDirectory() || info.isSymbolicLink()) throw new IntegrationError('unsafe_path', '配置目录不能包含链接或普通文件。');
    } catch (error) {
      if (errorCode(error) !== 'ENOENT') throw error;
      if (!create) return;
      try { await mkdir(current, { mode: 0o700 }); }
      catch (mkdirError) { if (errorCode(mkdirError) !== 'EEXIST') throw mkdirError; }
      const info = await lstat(current);
      if (!info.isDirectory() || info.isSymbolicLink()) throw new IntegrationError('unsafe_path', '配置目录发生变化。');
    }
  }
}
async function readSnapshot(path: string): Promise<Snapshot> {
  let info;
  try { info = await lstat(path); }
  catch (error) {
    if (errorCode(error) === 'ENOENT') return { exists: false, bytes: Buffer.alloc(0), revision: digest(), configuration: {} };
    throw error;
  }
  if (!info.isFile() || info.isSymbolicLink()) throw new IntegrationError('unsafe_path', '配置必须为普通文件，不能是链接。');
  if (info.size > MAX_CONFIG_BYTES) throw new IntegrationError('config_too_large', '配置超过 1 MiB 上限，原文件未修改。');
  const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const opened = await handle.stat();
    if (!opened.isFile() || !sameIdentity(info, opened)) throw new IntegrationError('revision_conflict', '读取时配置已改变，请重新生成计划。');
    const chunks: Buffer[] = []; let size = 0;
    while (true) {
      const chunk = Buffer.alloc(Math.min(16384, MAX_CONFIG_BYTES + 1 - size));
      const read = await handle.read(chunk, 0, chunk.length, null);
      if (!read.bytesRead) break;
      size += read.bytesRead;
      if (size > MAX_CONFIG_BYTES) throw new IntegrationError('config_too_large', '配置超过 1 MiB 上限，原文件未修改。');
      chunks.push(chunk.subarray(0, read.bytesRead));
    }
    const bytes = Buffer.concat(chunks, size);
    let configuration: unknown;
    try { configuration = JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes)); validateCopilotConfiguration(configuration); }
    catch { throw new IntegrationError('invalid_configuration', 'Copilot CLI hooks JSON、版本或结构无效，原文件未修改。'); }
    return { exists: true, bytes, revision: digest(bytes), configuration, identity: { dev: info.dev, ino: info.ino } };
  } finally { await handle.close(); }
}
async function runtimeReady(paths: Location): Promise<boolean> {
  if (!/\.exe$/i.test(paths.node) || !/\.cjs$/i.test(paths.script)) return false;
  for (const path of [paths.node, paths.script, paths.bridge]) {
    try { const info = await lstat(path); if (!info.isFile() || info.isSymbolicLink() || info.size === 0) return false; }
    catch (error) { if (['ENOENT', 'ENOTDIR'].includes(errorCode(error) ?? '')) return false; throw error; }
  }
  return true;
}
function validateOperation(operation: IntegrationOperation): void {
  if (!['install', 'uninstall'].includes(operation)) throw new IntegrationError('invalid_operation', '不支持的安装操作。');
}
function replacement(paths: Location, snapshot: Snapshot, operation: IntegrationOperation) {
  const merged = mergeCopilotConfiguration(snapshot.configuration, operation, paths.planNode, paths.planScript);
  const unchanged = JSON.stringify(snapshot.configuration) === JSON.stringify(merged.configuration);
  const bytes = merged.removable || !snapshot.exists && operation === 'uninstall' ? undefined
    : unchanged ? snapshot.bytes : Buffer.from(JSON.stringify(merged.configuration, null, 2) + '\n');
  return { ...merged, bytes, changed: bytes === undefined ? snapshot.exists : !snapshot.exists || !snapshot.bytes.equals(bytes) };
}
function summary(paths: Location, snapshot: Snapshot, operation: IntegrationOperation, ready: boolean): CopilotInstallationSummary {
  const next = replacement(paths, snapshot, operation);
  const warnings = ['此计划未写入配置；文件存在不代表 Copilot CLI 已加载，需要核对客户端实际事件。',
    '仅观察 12 个 Copilot CLI camelCase 事件；审批和问答留在原客户端。Windows PowerShell 启动器仍需实机验收。'];
  if (snapshot.configuration.disableAllHooks === true) warnings.push('此配置当前关闭 hooks，安装会保留关闭状态。');
  return { agent: 'copilot_cli', operation, configPath: paths.configPath, changed: next.changed,
    addedHandlers: next.changed ? next.addedHandlers : 0, removedHandlers: next.changed ? next.removedHandlers : 0,
    revision: revision(paths, snapshot), runtimeReady: ready,
    backup: { required: next.changed && snapshot.exists, directory: dirname(paths.configPath), filenamePrefix: 'xisland.json.xisland-backup-', exclusive: true },
    warnings, sources: [COPILOT_HOOKS_SOURCE] };
}
export async function getCopilotStatus(options: CopilotInstallerOptions = {}) {
  if (!options.tempHome && process.platform !== 'win32') return { agent: 'copilot_cli' as const, platformSupported: false,
    runtimeReady: false, installed: false, managedHandlers: 0, warnings: ['请在 Windows 客户端配置 Copilot CLI；当前平台不会修改用户配置。'] };
  const paths = await location(options);
  await safeDirectory(paths.home, dirname(paths.configPath));
  const snapshot = await readSnapshot(paths.configPath), ready = await runtimeReady(paths);
  const managedHandlers = copilotManagedHandlerCount(snapshot.configuration), next = replacement(paths, snapshot, 'install');
  return { agent: 'copilot_cli' as const, platformSupported: true, configPath: paths.configPath, revision: revision(paths, snapshot),
    runtimeReady: ready, installed: snapshot.exists && !next.changed, managedHandlers, updateAvailable: managedHandlers > 0 && next.changed,
    warnings: summary(paths, snapshot, 'install', ready).warnings };
}
export async function planCopilotIntegration(operation: IntegrationOperation, options: CopilotInstallerOptions = {}): Promise<CopilotInstallationSummary> {
  validateOperation(operation);
  const paths = await location(options);
  await safeDirectory(paths.home, dirname(paths.configPath));
  const snapshot = await readSnapshot(paths.configPath), ready = await runtimeReady(paths);
  if (operation === 'install' && !ready) throw new IntegrationError('runtime_missing', 'Node、hook 或 bridge 文件缺失，不能安装 Copilot CLI hooks。');
  return summary(paths, snapshot, operation, ready);
}
async function exclusiveWrite(path: string, bytes: Buffer): Promise<Identity> {
  const file = await open(path, 'wx', 0o600);
  try { await file.writeFile(bytes); await file.sync(); const info = await file.stat(); return { dev: info.dev, ino: info.ino }; }
  finally { await file.close(); }
}
async function removeOwnedTemporary(paths: Location, path: string, identity: Identity): Promise<void> {
  await safeDirectory(paths.home, dirname(path));
  let info;
  try { info = await lstat(path); }
  catch (error) { if (errorCode(error) === 'ENOENT') return; throw error; }
  if (!info.isFile() || info.isSymbolicLink() || !sameIdentity(identity, info)) throw new IntegrationError('revision_conflict', '临时文件归属已改变，未删除该文件。');
  await unlink(path);
}
async function withLock<T>(paths: Location, work: () => Promise<T>): Promise<T> {
  await safeDirectory(paths.home, dirname(paths.configPath), true);
  const path = paths.configPath + '.xisland-lock';
  let handle: FileHandle;
  try { handle = await open(path, 'wx', 0o600); }
  catch (error) {
    if (errorCode(error) === 'EEXIST') throw new IntegrationError('installation_busy', '另一个 Copilot CLI 安装操作持有锁，请稍后重试。');
    throw error;
  }
  const identity = await handle.stat();
  try { return await work(); }
  finally { await handle.close(); await removeOwnedTemporary(paths, path, identity); }
}
async function commit(paths: Location, snapshot: Snapshot, next: Buffer | undefined, operation: IntegrationOperation, options: CopilotInstallerOptions) {
  if (next && next.length > MAX_CONFIG_BYTES) throw new IntegrationError('config_too_large', '生成配置超过 1 MiB 上限，原文件未修改。');
  const temporary = paths.configPath + '.xisland-tmp-' + randomUUID();
  const backupId = snapshot.exists ? `${basename(paths.configPath)}.xisland-backup-${Date.now()}-${randomUUID()}.bak` : undefined;
  let temporaryIdentity: Identity | undefined;
  try {
    if (backupId) await exclusiveWrite(join(dirname(paths.configPath), backupId), snapshot.bytes);
    temporaryIdentity = await exclusiveWrite(temporary, next ?? Buffer.alloc(0));
    await options.beforeReplace?.();
    await safeDirectory(paths.home, dirname(paths.configPath));
    const current = await readSnapshot(paths.configPath);
    if (current.revision !== snapshot.revision || snapshot.identity && (!current.identity || !sameIdentity(snapshot.identity, current.identity))) {
      throw new IntegrationError('revision_conflict', '配置已被其他程序修改，请重新查看计划。');
    }
    if (operation === 'install' && !await runtimeReady(paths)) throw new IntegrationError('runtime_missing', '运行时文件在应用计划前发生变化，原配置未修改。');
    // 不先删除旧文件；Windows 文件占用导致 rename 失败时原配置仍在。
    await (options.replaceFile ?? rename)(next ? temporary : paths.configPath, next ? paths.configPath : temporary);
    if (!next) temporaryIdentity = snapshot.identity;
    return { backupId, revision: copilotConfigurationRevision(paths.configPath, digest(next), paths.node, paths.script) };
  } finally { if (temporaryIdentity) await removeOwnedTemporary(paths, temporary, temporaryIdentity); }
}
export async function applyCopilotIntegration(operation: IntegrationOperation, expectedRevision: string, options: CopilotInstallerOptions = {}): Promise<CopilotInstallationResult> {
  validateOperation(operation);
  if (!/^[a-f0-9]{64}$/.test(expectedRevision)) throw new IntegrationError('revision_required', '写入前必须提供已确认计划的 revision。');
  const paths = await location(options);
  await safeDirectory(paths.home, dirname(paths.configPath));
  const apply = async (write: boolean): Promise<CopilotInstallationResult | undefined> => {
    const snapshot = await readSnapshot(paths.configPath);
    if (revision(paths, snapshot) !== expectedRevision) throw new IntegrationError('revision_conflict', '配置位置、运行时或内容已改变，请重新查看计划。');
    const ready = await runtimeReady(paths);
    if (operation === 'install' && !ready) throw new IntegrationError('runtime_missing', 'Node、hook 或 bridge 文件缺失，原配置未修改。');
    const plan = summary(paths, snapshot, operation, ready);
    if (!plan.changed) return { ...plan, applied: false };
    if (!write) return undefined;
    const result = await commit(paths, snapshot, replacement(paths, snapshot, operation).bytes, operation, options);
    return { ...plan, ...result, applied: true, warnings: [operation === 'install'
      ? 'Copilot CLI 观察配置已写入；仍需核对客户端实际事件，尚未证明客户端已加载。'
      : '已移除可认领的 Copilot CLI handlers，保留用户内容与原文件备份。', ...plan.warnings.slice(1)] };
  };
  const unchanged = await apply(false);
  return unchanged ?? withLock(paths, async () => (await apply(true))!);
}
