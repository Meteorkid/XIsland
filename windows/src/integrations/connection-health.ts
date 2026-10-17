import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, realpath, rename, rmdir, unlink } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { adapterFor } from '../adapters/registry';
import { isRecord } from '../core/protocol';
import { discoverClient, type ClientDiscovery } from './discovery';
import { inspectCodexTrust, type HookTrustSnapshot } from './codex-trust';
import { windowsHookCommand } from './plan';
import { configurationRevision as scopedConfigurationRevision } from './installer';
import { copilotConfigurationRevision } from './copilot-installation';
import { piConfigurationRevision } from './pi-installation';
import { openCodeConfigurationRevision } from './opencode-installation';
import { kimiCodeConfigurationRevision } from './kimi-installation';

export interface ConnectionStatus {
  agent: string; installed: boolean; runtimeReady: boolean; revision?: string; configPath?: string; platformSupported?: boolean;
}
export interface ConnectionIdentity { agent: string; configurationRevision: string; runtimeFingerprint: string }
export interface ConnectionActivityReceipt extends ConnectionIdentity { event: string }
export interface ConnectionActivity { event: string; receivedAt: number }
export interface ConnectionHealthOptions {
  tempHome?: string;
  testRuntime?: {
    nodeExecutable: string; hookScript: string; bridgeExecutable: string;
    client?: ClientDiscovery; codexProbeScript?: string;
  };
  /** 只供隔离测试固定时间，不暴露给生产 CLI。 */
  now?: number;
}
interface Locations { home: string; runtimeRoot: string; node: string; script: string; bridge: string }
const sha256 = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const within = (root: string, path: string): boolean => {
  const child = relative(root, path);
  return child !== '' && !isAbsolute(child) && child !== '..' && !child.startsWith('..' + sep);
};
const code = (error: unknown): string | undefined => isRecord(error) && typeof error.code === 'string' ? error.code : undefined;

async function locations(options: ConnectionHealthOptions): Promise<Locations | undefined> {
  if (!options.tempHome) {
    if (options.testRuntime || options.now !== undefined) throw new Error('test_override_forbidden');
    if (process.platform !== 'win32') return undefined;
    if (!process.env.LOCALAPPDATA || !isAbsolute(process.env.LOCALAPPDATA)) return undefined;
    return { home: await realpath(homedir()), runtimeRoot: join(process.env.LOCALAPPDATA, 'XIsland'), node: process.execPath,
      script: resolve(process.argv[1]!), bridge: join(dirname(resolve(process.argv[1]!)), 'xisland-bridge.exe') };
  }
  if (!isAbsolute(options.tempHome)) throw new Error('test_home_not_isolated');
  const home = await realpath(options.tempHome);
  if (!within(await realpath(tmpdir()), home)) throw new Error('test_home_not_isolated');
  if (options.now !== undefined && (!Number.isSafeInteger(options.now) || options.now <= 0)) throw new Error('invalid_test_time');
  const paths = options.testRuntime ?? { nodeExecutable: join(home, 'resources', 'node.exe'),
    hookScript: join(home, 'resources', 'xisland-hook.cjs'), bridgeExecutable: join(home, 'resources', 'xisland-bridge.exe') };
  for (const path of [paths.nodeExecutable, paths.hookScript, paths.bridgeExecutable,
    options.testRuntime?.client?.executablePath, options.testRuntime?.codexProbeScript].filter((path): path is string => path !== undefined)) {
    if (!isAbsolute(path) || !within(home, path)) throw new Error('test_resource_not_isolated');
    // 不存在的测试资源可报告未就绪，但已存在的链接不能逃出 home。
    try { if (!within(home, await realpath(path))) throw new Error('test_resource_not_isolated'); }
    catch (error) { if (code(error) !== 'ENOENT') throw error; }
  }
  return { home, runtimeRoot: join(home, 'runtime'), node: paths.nodeExecutable, script: paths.hookScript, bridge: paths.bridgeExecutable };
}

/** 验证逐级目录，既不跟随 runtime 链接，也不在读取状态时创建目录。 */
async function directory(path: string, create: boolean): Promise<boolean> {
  const parent = dirname(path);
  if (parent !== path && !await directory(parent, create)) return false;
  try { const info = await lstat(path); if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('unsafe_activity_directory'); }
  catch (error) {
    if (code(error) !== 'ENOENT') throw error;
    if (!create) return false;
    try { await mkdir(path, { mode: 0o700 }); } catch (failure) { if (code(failure) !== 'EEXIST') throw failure; }
    const info = await lstat(path); if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('unsafe_activity_directory');
  }
  return true;
}

async function fileDigest(path: string, limit: number, prefix = ''): Promise<string> {
  const before = await lstat(path);
  if (!before.isFile() || before.isSymbolicLink() || before.size > limit) throw new Error('invalid_connection_file');
  const file = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const opened = await file.stat();
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino) throw new Error('connection_file_changed');
    const hash = createHash('sha256').update(prefix); let size = 0;
    for await (const chunk of file.createReadStream({ autoClose: false })) {
      size += chunk.length; if (size > limit) throw new Error('connection_file_too_large'); hash.update(chunk);
    }
    const after = await file.stat();
    if (after.size !== before.size || after.mtimeMs !== before.mtimeMs || after.ctimeMs !== before.ctimeMs) throw new Error('connection_file_changed');
    return hash.digest('hex');
  } finally { await file.close(); }
}

async function identityAt(status: ConnectionStatus, paths: Locations): Promise<ConnectionIdentity | undefined> {
  if (!status.installed || !status.runtimeReady || !sha256(status.revision) || !status.configPath || !isAbsolute(status.configPath)) return undefined;
  try {
    adapterFor(status.agent);
    if (!within(paths.home, status.configPath)) return undefined;
    const configurationPath = await realpath(status.configPath);
    if (!within(paths.home, configurationPath)) return undefined;
    const rawRevision = await fileDigest(status.configPath, 1024 * 1024, 'present\0');
    const configurationRevision = status.agent === 'copilot_cli'
      ? copilotConfigurationRevision(status.configPath, rawRevision, paths.node, paths.script)
      : status.agent === 'pi' ? piConfigurationRevision(status.configPath, rawRevision, paths.node, paths.script)
      : status.agent === 'opencode' ? openCodeConfigurationRevision(status.configPath, rawRevision, paths.node, paths.script)
      : status.agent === 'kimi_code' ? kimiCodeConfigurationRevision(status.configPath, rawRevision, paths.node, paths.script)
      : scopedConfigurationRevision(status.agent, status.configPath, rawRevision);
    if (configurationRevision !== status.revision) return undefined;
    // Node 本体约 90 MiB；每个工具事件重读它会拖慢原任务。此处只是活动有效性，非程序签名证明。
    const node = await lstat(paths.node, { bigint: true });
    if (!node.isFile() || node.isSymbolicLink() || !node.size) return undefined;
    // 相同内容可存在于不同 Agent 配置目录；活动只属于实际读取的规范化路径。
    const resources: string[][] = [[configurationPath], [await realpath(paths.node), process.version, String(node.dev), String(node.ino),
      String(node.size), String(node.mtimeNs), String(node.ctimeNs)]];
    for (const path of [paths.script, paths.bridge]) {
      const info = await lstat(path); if (!info.size) return undefined;
      resources.push([await realpath(path), await fileDigest(path, 512 * 1024 * 1024)]);
    }
    return { agent: status.agent, configurationRevision,
      runtimeFingerprint: createHash('sha256').update(JSON.stringify(resources)).digest('hex') };
  } catch { return undefined; }
}

/** 在投递原生事件前捕获身份；处理期间更新配置或资源不会给新配置留下旧证据。 */
export async function connectionIdentity(status: ConnectionStatus, options: ConnectionHealthOptions = {}): Promise<ConnectionIdentity | undefined> {
  const paths = await locations(options);
  return paths ? identityAt(status, paths) : undefined;
}

function validIdentity(value: unknown): value is ConnectionIdentity {
  if (!isRecord(value) || typeof value.agent !== 'string' || !sha256(value.configurationRevision) || !sha256(value.runtimeFingerprint)) return false;
  try { adapterFor(value.agent); return true; } catch { return false; }
}
function validEvent(agent: string, event: unknown): event is string {
  return typeof event === 'string' && adapterFor(agent).events.includes(event);
}

function sameIdentity(left: ConnectionIdentity | undefined, right: ConnectionIdentity): boolean {
  return !!left && left.agent === right.agent && left.configurationRevision === right.configurationRevision
    && left.runtimeFingerprint === right.runtimeFingerprint;
}

async function activityMetadata(agent: string, paths: Locations): Promise<unknown> {
  const root = join(paths.runtimeRoot, 'connection-activity'); if (!await directory(root, false)) return undefined;
  const path = join(root, agent + '.json');
  let info;
  try { info = await lstat(path); } catch (error) { if (code(error) === 'ENOENT') return undefined; throw error; }
  if (!info.isFile() || info.isSymbolicLink() || info.size > 4096) throw new Error('unsafe_activity_file');
  const file = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const opened = await file.stat();
    if (!opened.isFile() || opened.dev !== info.dev || opened.ino !== info.ino) throw new Error('activity_file_changed');
    const bytes = Buffer.alloc(4097), read = await file.read(bytes, 0, bytes.length, 0);
    if (read.bytesRead > 4096) throw new Error('activity_file_too_large');
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, read.bytesRead)));
  } finally { await file.close(); }
}

async function writeActivityMetadata(agent: string, record: unknown, paths: Locations): Promise<void> {
  const root = join(paths.runtimeRoot, 'connection-activity'); await directory(root, true);
  const target = join(root, agent + '.json'), temporary = target + '.tmp-' + randomUUID();
  try {
    const file = await open(temporary, 'wx', 0o600);
    try { await file.writeFile(JSON.stringify(record) + '\n'); await file.sync(); } finally { await file.close(); }
    await directory(root, false);
    try { const info = await lstat(target); if (!info.isFile() || info.isSymbolicLink()) throw new Error('unsafe_activity_file'); }
    catch (error) { if (code(error) !== 'ENOENT') throw error; }
    await rename(temporary, target);
  } finally { await unlink(temporary).catch(error => { if (code(error) !== 'ENOENT') throw error; }); }
}

async function codexEpoch(paths: Locations): Promise<string> {
  const record = await activityMetadata('codex', paths);
  if (record === undefined) return 'initial';
  if (!isRecord(record) || record.version !== 1 || record.agent !== 'codex') throw new Error('invalid_authorization_metadata');
  if (typeof record.authorizationEpoch === 'string' && /^(?:initial|legacy|[a-f0-9-]{36})$/.test(record.authorizationEpoch)) return record.authorizationEpoch;
  if (validIdentity(record)) return 'legacy';
  throw new Error('invalid_authorization_metadata');
}

/** 锁只保护短暂的元数据替换；客户端探测在锁外，查询中的短任务可以继续排入记录。 */
async function withCodexActivityLock<T>(paths: Locations, action: () => Promise<T>): Promise<T> {
  const root = join(paths.runtimeRoot, 'connection-activity'); await directory(root, true);
  const lock = join(root, 'codex.lock'), deadline = Date.now() + 2000;
  for (;;) {
    try { await mkdir(lock, { mode: 0o700 }); break; }
    catch (error) {
      if (code(error) !== 'EEXIST') throw error;
      try {
        const info = await lstat(lock);
        if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('activity_lock_unavailable');
      } catch (failure) { if (code(failure) !== 'ENOENT') throw failure; }
      if (Date.now() >= deadline) throw new Error('activity_lock_unavailable');
      await new Promise(resolve => setTimeout(resolve, 15));
    }
  }
  try { return await action(); } finally { await rmdir(lock); }
}

async function invalidateCodexActivity(paths: Locations): Promise<void> {
  await withCodexActivityLock(paths, () => writeActivityMetadata('codex', {
    version: 1, agent: 'codex', revoked: true, authorizationEpoch: randomUUID(),
  }, paths));
}

/** 仅保存非 Codex 的元数据；生产入口须先验证主窗口接纳回执与当前身份。 */
export async function recordIntegrationActivity(identity: ConnectionIdentity, event: unknown, options: ConnectionHealthOptions = {}): Promise<void> {
  const paths = await locations(options); if (!paths) return;
  if (!validIdentity(identity) || !validEvent(identity.agent, event)) throw new Error('invalid_connection_activity');
  if (identity.agent === 'codex') throw new Error('codex_activity_requires_authorization');
  const receivedAt = options.now ?? Date.now();
  if (!Number.isSafeInteger(receivedAt) || receivedAt <= 0) throw new Error('invalid_activity_time');
  const record = { version: 1, agent: identity.agent, configurationRevision: identity.configurationRevision,
    runtimeFingerprint: identity.runtimeFingerprint, event, receivedAt };
  await writeActivityMetadata(identity.agent, record, paths);
}

async function readActivity(identity: ConnectionIdentity, paths: Locations, now: number, authorizationFingerprint?: string): Promise<ConnectionActivity | undefined> {
  try {
    const record = await activityMetadata(identity.agent, paths);
    if (!isRecord(record) || record.version !== 1 || !validIdentity(record) || record.agent !== identity.agent
      || record.configurationRevision !== identity.configurationRevision || record.runtimeFingerprint !== identity.runtimeFingerprint
      || !validEvent(identity.agent, record.event) || !Number.isSafeInteger(record.receivedAt)
      || (record.receivedAt as number) <= 0 || (record.receivedAt as number) > now) return undefined;
    if (identity.agent === 'codex' && (!sha256(authorizationFingerprint) || record.authorizationFingerprint !== authorizationFingerprint)) return undefined;
    return { event: record.event, receivedAt: record.receivedAt as number };
  } catch { return undefined; }
}

async function clientAt(agent: string, paths: Locations, options: ConnectionHealthOptions): Promise<ClientDiscovery> {
  return options.tempHome ? options.testRuntime?.client ?? { state: 'not_found', detail: '隔离测试未提供客户端入口。' }
    : discoverClient(agent, { home: paths.home, path: process.env.PATH ?? '', appData: process.env.APPDATA,
      localAppData: process.env.LOCALAPPDATA, programFiles: process.env.ProgramFiles });
}

async function codexTrustAt(client: ClientDiscovery, paths: Locations, options: ConnectionHealthOptions): Promise<HookTrustSnapshot> {
  if (client.state !== 'detected' || !client.executablePath?.toLowerCase().endsWith('.exe')) {
    return { state: 'unavailable', configuredCount: 0, trustedCount: 0, reason: '未找到可直接检查的 Codex 可执行文件，请在原客户端查看 /hooks。' };
  }
  try {
    const info = await lstat(client.executablePath);
    if (!info.isFile() || info.isSymbolicLink()) throw new Error('not_native_executable');
  } catch { return { state: 'unavailable', configuredCount: 0, trustedCount: 0, reason: 'Codex 可执行文件已不可用。' }; }
  const node = options.tempHome ? 'C:\\XIsland-Test-Resources\\node.exe' : paths.node;
  const script = options.tempHome ? 'C:\\XIsland-Test-Resources\\xisland-hook.cjs' : paths.script;
  const commands = adapterFor('codex').events.map(event => windowsHookCommand(node, script, 'codex', event));
  return inspectCodexTrust(options.testRuntime?.codexProbeScript ? process.execPath : client.executablePath,
    paths.home, commands, options.tempHome ? { tempHome: paths.home, testScript: options.testRuntime?.codexProbeScript } : {});
}

/** 仅由主窗口接纳有效活动后调用；投递前身份必须仍与当前配置和运行时一致。 */
export async function recordAcceptedIntegrationActivity(status: ConnectionStatus, receipt: ConnectionActivityReceipt,
  options: ConnectionHealthOptions = {}): Promise<boolean> {
  const paths = await locations(options); if (!paths) throw new Error('unsupported_platform');
  if (!validIdentity(receipt) || !validEvent(receipt.agent, receipt.event) || status.agent !== receipt.agent) throw new Error('invalid_connection_activity');
  if (!sameIdentity(await identityAt(status, paths), receipt)) return false;
  if (receipt.agent !== 'codex') { await recordIntegrationActivity(receipt, receipt.event, options); return true; }
  const epoch = await codexEpoch(paths);
  const trust = await codexTrustAt(await clientAt('codex', paths, options), paths, options);
  if (trust.state === 'required') { await invalidateCodexActivity(paths); return false; }
  if (trust.state !== 'granted' || !sha256(trust.fingerprint)) return false;
  return withCodexActivityLock(paths, async () => {
    if (await codexEpoch(paths) !== epoch || !sameIdentity(await identityAt(status, paths), receipt)) return false;
    await writeActivityMetadata('codex', { version: 1, agent: receipt.agent, configurationRevision: receipt.configurationRevision,
      runtimeFingerprint: receipt.runtimeFingerprint, event: receipt.event, receivedAt: options.now ?? Date.now(),
      authorizationFingerprint: trust.fingerprint, authorizationEpoch: epoch }, paths);
    return true;
  });
}

/** 探测、授权和回传记录分别呈现；找不到授权信息时绝不沿用旧活动。 */
export async function decorateIntegrationStatus<T extends ConnectionStatus>(status: T, options: ConnectionHealthOptions = {}): Promise<T & {
  client: ClientDiscovery; trust?: HookTrustSnapshot; activity?: ConnectionActivity;
}> {
  const paths = await locations(options);
  const client: ClientDiscovery = !paths ? { state: 'unconfirmed', detail: '请在 Windows 客户端检查自动接入。' }
    : await clientAt(status.agent, paths, options);
  const result = { ...status, client, trust: undefined as HookTrustSnapshot | undefined, activity: undefined as ConnectionActivity | undefined };
  if (!paths) return result;
  const identity = await identityAt(status, paths); if (!identity) return result;
  if (status.agent === 'codex') {
    result.trust = await codexTrustAt(client, paths, options);
    if (result.trust.state === 'required') await invalidateCodexActivity(paths);
    if (!sameIdentity(await identityAt(status, paths), identity)) {
      result.trust = { state: 'unavailable', configuredCount: 0, trustedCount: 0, reason: '检查期间接入配置或运行时已变化，请重新检查。' };
      return result;
    }
    if (result.trust.state !== 'granted') return result;
  }
  result.activity = await readActivity(identity, paths, options.now ?? Date.now(), result.trust?.fingerprint);
  return result;
}
