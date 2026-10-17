import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { applyCopilotIntegration, copilotConfigurationRevision, getCopilotStatus, planCopilotIntegration, type CopilotInstallerOptions } from '../src/integrations/copilot-installation';
import { copilotConfigPath, copilotManagedHandlerCount } from '../src/integrations/copilot-config';
import { IntegrationError, MAX_CONFIG_BYTES } from '../src/integrations/installer';

async function fixture(t: TestContext) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'xisland-copilot-install-')));
  t.after(() => rm(home, { recursive: true, force: true }));
  const resources = join(home, 'resources'); await mkdir(resources);
  for (const name of ['node.exe', 'xisland-hook.cjs', 'xisland-bridge.exe']) await writeFile(join(resources, name), 'isolated fixture, never executed');
  const options: CopilotInstallerOptions = { tempHome: home, resourceDirectory: resources, nodeExecutable: join(resources, 'node.exe') };
  return { home, resources, options, path: copilotConfigPath(home) };
}
const rejectsCode = (code: string) => (error: unknown) => error instanceof IntegrationError && error.code === code;
async function install(options: CopilotInstallerOptions) {
  const plan = await planCopilotIntegration('install', options);
  return applyCopilotIntegration('install', plan.revision, options);
}
async function writeExisting(path: string, bytes: string | Buffer) {
  await mkdir(dirname(path), { recursive: true }); await writeFile(path, bytes);
}
async function linked(t: TestContext, target: string, path: string, directory: boolean): Promise<boolean> {
  try { await symlink(target, path, directory ? process.platform === 'win32' ? 'junction' : 'dir' : 'file'); return true; }
  catch (error) { if ((error as NodeJS.ErrnoException).code === 'EPERM') { t.skip('host cannot create test symlinks'); return false; } throw error; }
}

test('Copilot CLI status and review are read-only; install writes one native version 1 JSON file', async t => {
  const { home, options, path, resources } = await fixture(t);
  const status = await getCopilotStatus(options), plan = await planCopilotIntegration('install', options);
  assert.equal(status.agent, 'copilot_cli'); assert.equal(status.platformSupported, true);
  assert.equal(status.runtimeReady, true); assert.equal(status.installed, false); assert.equal(status.managedHandlers, 0);
  assert.equal(plan.configPath, path); assert.equal(plan.addedHandlers, 12); assert.equal(plan.removedHandlers, 0);
  assert.equal(plan.backup.required, false); assert.match(plan.revision, /^[a-f0-9]{64}$/);
  assert.equal('nextConfig' in plan, false); assert.deepEqual(await readdir(home), ['resources']);
  const result = await applyCopilotIntegration('install', plan.revision, options);
  assert.equal(result.applied, true); assert.equal(result.backupId, undefined); assert.notEqual(result.revision, plan.revision);
  const bytes = await readFile(path), config = JSON.parse(bytes.toString('utf8'));
  assert.equal(config.version, 1); assert.equal(copilotManagedHandlerCount(config), 12);
  assert.deepEqual(await readdir(dirname(path)), ['xisland.json']);
  const rawRevision = createHash('sha256').update('present\0').update(bytes).digest('hex');
  assert.equal(result.revision, copilotConfigurationRevision(path, rawRevision, join(resources, 'node.exe'), join(resources, 'xisland-hook.cjs')));
  const installed = await getCopilotStatus(options);
  assert.equal(installed.installed, true); assert.equal(installed.managedHandlers, 12); assert.equal(installed.revision, result.revision);
});

test('Copilot CLI repeated install and missing uninstall preserve bytes and do not create extra directories', async t => {
  const { home, options, path } = await fixture(t);
  const absent = await planCopilotIntegration('uninstall', options);
  assert.equal((await applyCopilotIntegration('uninstall', absent.revision, options)).applied, false);
  assert.deepEqual(await readdir(home), ['resources']);
  const installed = await install(options), original = await readFile(path);
  const plan = await planCopilotIntegration('install', options);
  assert.equal(plan.changed, false); assert.equal(plan.addedHandlers, 0); assert.equal(plan.removedHandlers, 0);
  const result = await applyCopilotIntegration('install', plan.revision, options);
  assert.equal(result.applied, false); assert.equal(result.revision, installed.revision);
  assert.deepEqual(await readFile(path), original); assert.deepEqual(await readdir(dirname(path)), ['xisland.json']);
});

test('Copilot CLI preserves foreign settings and handlers with byte-exact backups through install and uninstall', async t => {
  const { options, path } = await fixture(t);
  const userConfig = { version: 1, disableAllHooks: true, userSecret: 'do-not-print-fixture', hooks: {
    sessionStart: [{ type: 'command', command: 'user-command' }],
    permissionRequest: [{ type: 'command', exec: 'user-approval.exe', args: ['--flag'] }],
  } };
  const original = Buffer.from(JSON.stringify(userConfig) + '\r\n'); await writeExisting(path, original);
  const plan = await planCopilotIntegration('install', options);
  assert.equal(plan.backup.required, true); assert.equal(JSON.stringify(plan).includes('do-not-print-fixture'), false);
  assert.ok(plan.warnings.some(warning => warning.includes('关闭')));
  const installed = await applyCopilotIntegration('install', plan.revision, options);
  assert.deepEqual(await readFile(join(dirname(path), installed.backupId!)), original);
  const installedBytes = await readFile(path);
  const removal = await planCopilotIntegration('uninstall', options);
  assert.equal(removal.removedHandlers, 12);
  const removed = await applyCopilotIntegration('uninstall', removal.revision, options);
  assert.deepEqual(await readFile(join(dirname(path), removed.backupId!)), installedBytes);
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), userConfig);
  const before = await readFile(path), noop = await planCopilotIntegration('uninstall', options);
  assert.equal((await applyCopilotIntegration('uninstall', noop.revision, options)).applied, false);
  assert.deepEqual(await readFile(path), before);
});

test('Copilot CLI pure managed uninstall deletes only its file and works without runtime', async t => {
  const { options, path, resources } = await fixture(t);
  await install(options); const original = await readFile(path);
  await unlink(join(resources, 'xisland-bridge.exe'));
  const plan = await planCopilotIntegration('uninstall', options);
  assert.equal(plan.runtimeReady, false); assert.equal(plan.removedHandlers, 12);
  const result = await applyCopilotIntegration('uninstall', plan.revision, options);
  assert.deepEqual(await readFile(join(dirname(path), result.backupId!)), original);
  await assert.rejects(readFile(path), error => (error as NodeJS.ErrnoException).code === 'ENOENT');
  assert.equal((await getCopilotStatus(options)).installed, false);
});

test('Copilot CLI invalid versions, encoding, structure and oversized files remain untouched', async t => {
  const { options, path } = await fixture(t);
  for (const bytes of [Buffer.from('{'), Buffer.from('{"version":2,"hooks":{}}'), Buffer.from('{"hooks":[]}'),
    Buffer.from('\ufeff{"version":1}'), Buffer.from([0xc3, 0x28])]) {
    await writeExisting(path, bytes);
    await assert.rejects(getCopilotStatus(options), rejectsCode('invalid_configuration'));
    await assert.rejects(planCopilotIntegration('install', options), rejectsCode('invalid_configuration'));
    assert.deepEqual(await readFile(path), bytes); assert.deepEqual(await readdir(dirname(path)), ['xisland.json']);
  }
  const bytes = Buffer.alloc(MAX_CONFIG_BYTES + 1, 120); await writeFile(path, bytes);
  await assert.rejects(getCopilotStatus(options), rejectsCode('config_too_large'));
  assert.deepEqual(await readFile(path), bytes);
});

test('Copilot CLI custom home stays within user home and revisions cannot cross directories', async t => {
  const { options, home, path } = await fixture(t);
  const originalPlan = await planCopilotIntegration('install', options);
  const custom = join(home, 'custom configuration'), customOptions = { ...options, environment: { COPILOT_HOME: custom } };
  await assert.rejects(applyCopilotIntegration('install', originalPlan.revision, customOptions), rejectsCode('revision_conflict'));
  const installed = await install(customOptions);
  assert.equal(installed.configPath, join(custom, 'hooks', 'xisland.json'));
  assert.equal((await getCopilotStatus(customOptions)).installed, true);
  await assert.rejects(readFile(path), error => (error as NodeJS.ErrnoException).code === 'ENOENT');
  for (const value of ['relative', home + '\0bad', home + '\nbad']) {
    await assert.rejects(planCopilotIntegration('install', { ...options, environment: { COPILOT_HOME: value } }), rejectsCode('invalid_config_home'));
  }
  await assert.rejects(planCopilotIntegration('install', { ...options, environment: { COPILOT_HOME: dirname(home) } }), rejectsCode('custom_config_outside_home'));
  assert.equal((await getCopilotStatus({ ...options, environment: { COPILOT_HOME: '' } })).configPath, path);
});

test('Copilot CLI runtime movement updates only owned commands and invalidates stale review', async t => {
  const { home, options, path } = await fixture(t);
  await install(options); const original = await readFile(path), oldPlan = await planCopilotIntegration('install', options);
  const moved = join(home, 'moved runtime'); await mkdir(moved);
  for (const name of ['node.exe', 'xisland-hook.cjs', 'xisland-bridge.exe']) await writeFile(join(moved, name), 'new runtime fixture');
  const updatedOptions = { ...options, resourceDirectory: moved, nodeExecutable: join(moved, 'node.exe') };
  await assert.rejects(applyCopilotIntegration('install', oldPlan.revision, updatedOptions), rejectsCode('revision_conflict'));
  const status = await getCopilotStatus(updatedOptions);
  assert.equal(status.installed, false); assert.equal(status.updateAvailable, true); assert.equal(status.managedHandlers, 12);
  const updated = await install(updatedOptions);
  assert.equal(updated.addedHandlers, 12); assert.equal(updated.removedHandlers, 12);
  assert.deepEqual(await readFile(join(dirname(path), updated.backupId!)), original);
  assert.equal((await getCopilotStatus(updatedOptions)).installed, true);
});

test('Copilot CLI detects external edits and same-byte inode replacement immediately before commit', async t => {
  const { options, path } = await fixture(t);
  const absent = await planCopilotIntegration('install', options);
  await writeExisting(path, '{"version":1,"user":true}');
  await assert.rejects(applyCopilotIntegration('install', absent.revision, options), rejectsCode('revision_conflict'));
  await install(options); const original = await readFile(path), plan = await planCopilotIntegration('uninstall', options);
  await assert.rejects(applyCopilotIntegration('uninstall', plan.revision, { ...options, beforeReplace: async () => {
    const external = path + '.external'; await writeFile(external, original); await rename(external, path);
  } }), rejectsCode('revision_conflict'));
  assert.deepEqual(await readFile(path), original);
  assert.equal((await readdir(dirname(path))).some(name => name.includes('.xisland-tmp-') || name.endsWith('.xisland-lock')), false);
});

test('Copilot CLI rename failure preserves original configuration and recoverable backup', async t => {
  const { options, path } = await fixture(t);
  await install(options); const original = await readFile(path), plan = await planCopilotIntegration('uninstall', options);
  await assert.rejects(applyCopilotIntegration('uninstall', plan.revision, { ...options,
    replaceFile: async () => { throw Object.assign(new Error('fixture file is open'), { code: 'EPERM' }); },
  }), /fixture file is open/);
  assert.deepEqual(await readFile(path), original);
  const files = await readdir(dirname(path));
  assert.equal(files.some(name => name.endsWith('.xisland-lock') || name.includes('.xisland-tmp-')), false);
  for (const backup of files.filter(name => name.endsWith('.bak'))) assert.deepEqual(await readFile(join(dirname(path), backup)), original);
});

test('Copilot CLI exclusive lock blocks simultaneous apply without deleting another writer lock', async t => {
  const { options, path } = await fixture(t), plan = await planCopilotIntegration('install', options);
  let entered!: () => void, release!: () => void;
  const arrived = new Promise<void>(resolve => { entered = resolve; }), blocked = new Promise<void>(resolve => { release = resolve; });
  const first = applyCopilotIntegration('install', plan.revision, { ...options, beforeReplace: async () => { entered(); await blocked; } });
  await arrived;
  try { await assert.rejects(applyCopilotIntegration('install', plan.revision, options), rejectsCode('installation_busy')); }
  finally { release(); }
  assert.equal((await first).applied, true); assert.deepEqual(await readdir(dirname(path)), ['xisland.json']);
});

test('Copilot CLI rejects symlink directories, files and isolated runtime escapes', async t => {
  const { options, home, path } = await fixture(t);
  await assert.rejects(planCopilotIntegration('install', { ...options, tempHome: tmpdir() }), rejectsCode('test_home_not_isolated'));
  await assert.rejects(planCopilotIntegration('install', { ...options, nodeExecutable: process.execPath }), rejectsCode('test_resource_not_isolated'));
  const outside = await realpath(await mkdtemp(join(tmpdir(), 'xisland-copilot-outside-')));
  t.after(() => rm(outside, { recursive: true, force: true }));
  const target = join(outside, 'xisland.json'); await writeFile(target, '{"version":1,"sentinel":true}');
  if (!await linked(t, outside, join(home, '.copilot'), true)) return;
  await assert.rejects(getCopilotStatus(options), rejectsCode('unsafe_path'));
  await unlink(join(home, '.copilot')); await mkdir(dirname(path), { recursive: true });
  if (!await linked(t, target, path, false)) return;
  await assert.rejects(getCopilotStatus(options), rejectsCode('unsafe_path'));
  assert.equal(await readFile(target, 'utf8'), '{"version":1,"sentinel":true}');
});

test('Copilot CLI runtime loss before commit leaves no new configuration or transient files', async t => {
  const { options, resources, path } = await fixture(t), plan = await planCopilotIntegration('install', options);
  await assert.rejects(applyCopilotIntegration('install', plan.revision, { ...options,
    beforeReplace: async () => { await unlink(join(resources, 'xisland-bridge.exe')); },
  }), rejectsCode('runtime_missing'));
  assert.deepEqual(await readdir(dirname(path)), []);
  await assert.rejects(planCopilotIntegration('install', options), rejectsCode('runtime_missing'));
  await assert.rejects(applyCopilotIntegration('install', '', options), rejectsCode('revision_required'));
});

test('Copilot CLI production writes are disabled on non-Windows hosts', async t => {
  if (process.platform === 'win32') { t.skip('production-home checks are intentionally not exercised on Windows'); return; }
  const status = await getCopilotStatus();
  assert.equal(status.platformSupported, false); assert.equal(status.installed, false);
  await assert.rejects(planCopilotIntegration('install'), rejectsCode('unsupported_platform'));
});
