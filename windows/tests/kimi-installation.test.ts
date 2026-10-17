import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { applyKimiCodeIntegration, getKimiCodeStatus, planKimiCodeIntegration, type KimiCodeInstallerOptions } from '../src/integrations/kimi-installation';
import { IntegrationError, MAX_CONFIG_BYTES } from '../src/integrations/installer';
import { KIMI_CODE_HOOK_EVENTS } from '../src/adapters/kimi-code';
import { createKimiCodeConfigurationPlan } from '../src/integrations/kimi-config';
import { windowsHookCommand } from '../src/integrations/plan';

async function fixture(t: TestContext) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'xisland-kimi-install-')));
  t.after(() => rm(home, { recursive: true, force: true }));
  const resources = join(home, 'resources'); await mkdir(resources);
  for (const name of ['node.exe', 'xisland-hook.cjs', 'xisland-bridge.exe']) await writeFile(join(resources, name), 'isolated fixture, never executed');
  const options: KimiCodeInstallerOptions = { tempHome: home, resourceDirectory: resources, nodeExecutable: join(resources, 'node.exe') };
  return { home, resources, options, path: join(home, '.kimi-code', 'config.toml') };
}
const rejectsCode = (code: string) => (error: unknown) => error instanceof IntegrationError && error.code === code;
async function writeExisting(path: string, bytes: string | Buffer) { await mkdir(dirname(path), { recursive: true }); await writeFile(path, bytes); }
async function install(options: KimiCodeInstallerOptions) {
  const plan = await planKimiCodeIntegration('install', options);
  return applyKimiCodeIntegration('install', plan.revision, options);
}
async function linked(t: TestContext, target: string, path: string, directory: boolean): Promise<boolean> {
  try { await symlink(target, path, directory ? process.platform === 'win32' ? 'junction' : 'dir' : 'file'); return true; }
  catch (error) { if ((error as NodeJS.ErrnoException).code === 'EPERM') { t.skip('host cannot create test symlinks'); return false; } throw error; }
}
const original = '# 中文与😀注释\r\nmodel = "local"\r\n[providers.private]\r\napi_key = "fixture-secret"\r\nunknown = [1, 2]\r\n'
  + '[[hooks]]\r\nevent = "Stop"\r\ncommand = \'echo third-party\' # keep\r\ntimeout = 5\r\n';

test('Kimi Code status and review do not create files; apply installs all Node hook events', async t => {
  const { home, options, path } = await fixture(t);
  const status = await getKimiCodeStatus(options);
  assert.equal(status.agent, 'kimi_code'); assert.equal(status.platformSupported, true); assert.equal(status.runtimeReady, true);
  assert.equal(status.installed, false); assert.equal(status.configPath, path);
  const plan = await planKimiCodeIntegration('install', options);
  assert.equal(plan.changed, true); assert.equal(plan.addedHandlers, 20); assert.equal(plan.removedHandlers, 0);
  assert.equal(plan.backup.required, false); assert.match(plan.revision, /^[a-f0-9]{64}$/);
  assert.equal('nextText' in plan, false); assert.equal('nextConfig' in plan, false); assert.deepEqual(await readdir(home), ['resources']);
  const result = await applyKimiCodeIntegration('install', plan.revision, options);
  assert.equal(result.applied, true); assert.equal(result.backupId, undefined);
  const source = await readFile(path, 'utf8');
  for (const event of KIMI_CODE_HOOK_EVENTS) assert.ok(source.includes(`event = "${event}"`));
  assert.equal((source.match(/^\[\[hooks\]\]$/gm) ?? []).length, 20);
  const installed = await getKimiCodeStatus(options);
  assert.equal(installed.installed, true); assert.equal(installed.managedHandlers, 20);
  assert.deepEqual(await readdir(dirname(path)), ['config.toml']);
});

test('Kimi Code preserves TOML bytes, comments, unknown fields and third-party hooks across install/uninstall', async t => {
  const { options, path, home } = await fixture(t);
  await writeExisting(path, original);
  const legacy = join(home, '.kimi', 'config.toml'); await writeExisting(legacy, 'python sentinel');
  const result = await install(options); assert.ok(result.backupId);
  assert.deepEqual(await readFile(join(dirname(path), result.backupId!)), Buffer.from(original));
  const source = await readFile(path);
  assert.deepEqual(source.subarray(0, Buffer.byteLength(original)), Buffer.from(original));
  assert.equal(JSON.stringify(result).includes('fixture-secret'), false);
  assert.equal(JSON.stringify(await getKimiCodeStatus(options)).includes('fixture-secret'), false);
  const remove = await planKimiCodeIntegration('uninstall', options);
  assert.equal(remove.removedHandlers, 20); assert.equal(remove.addedHandlers, 0);
  const removed = await applyKimiCodeIntegration('uninstall', remove.revision, options); assert.ok(removed.backupId);
  assert.deepEqual(await readFile(path), Buffer.from(original)); assert.equal(await readFile(legacy, 'utf8'), 'python sentinel');
  assert.deepEqual(await readFile(join(dirname(path), removed.backupId!)), source);
});

test('Kimi Code repeated installation and removal are no-ops; uninstall keeps an empty config file', async t => {
  const { options, path } = await fixture(t);
  const first = await install(options), plan = await planKimiCodeIntegration('install', options);
  assert.equal(plan.changed, false); assert.equal(plan.addedHandlers, 0);
  const second = await applyKimiCodeIntegration('install', plan.revision, options);
  assert.equal(second.applied, false); assert.equal(second.revision, first.revision);
  assert.deepEqual(await readdir(dirname(path)), ['config.toml']);
  const removal = await planKimiCodeIntegration('uninstall', options);
  const removed = await applyKimiCodeIntegration('uninstall', removal.revision, options);
  assert.equal(await readFile(path, 'utf8'), ''); assert.ok(removed.backupId);
  const repeat = await planKimiCodeIntegration('uninstall', options);
  assert.equal(repeat.changed, false); assert.equal((await applyKimiCodeIntegration('uninstall', repeat.revision, options)).applied, false);
});

test('Kimi Code absent-config uninstall remains read-only', async t => {
  const { home, options } = await fixture(t);
  const plan = await planKimiCodeIntegration('uninstall', options);
  assert.equal(plan.changed, false); assert.equal((await applyKimiCodeIntegration('uninstall', plan.revision, options)).applied, false);
  assert.deepEqual(await readdir(home), ['resources']);
});

test('Kimi Code recognizes complete old generated commands for safe runtime-path updates', async t => {
  const { options, path } = await fixture(t);
  const previous = createKimiCodeConfigurationPlan({ configuration: original, operation: 'install',
    commandForEvent: event => windowsHookCommand('C:\\Old-XIsland\\node.exe', 'C:\\Old-XIsland\\xisland-hook.cjs', 'kimi_code', event) }).nextText;
  await writeExisting(path, previous);
  const status = await getKimiCodeStatus(options);
  assert.equal(status.installed, false); assert.equal(status.updateAvailable, true); assert.equal(status.managedHandlers, 20);
  const plan = await planKimiCodeIntegration('install', options);
  assert.equal(plan.addedHandlers, 20); assert.equal(plan.removedHandlers, 20);
  const result = await applyKimiCodeIntegration('install', plan.revision, options); assert.ok(result.backupId);
  assert.equal(await readFile(join(dirname(path), result.backupId!), 'utf8'), previous);
  assert.equal((await getKimiCodeStatus(options)).installed, true);
});

test('Kimi Code edited managed blocks and ambiguous TOML are preserved without writes', async t => {
  const { options, path } = await fixture(t);
  await install(options); const managed = await readFile(path, 'utf8');
  for (const source of [managed.replace('timeout = 10', 'timeout = 9'), managed + '[user]\nx = 1\n',
    managed.replace('# END XIsland:Windows:KimiCode:hooks v1', '# user changed ending'), 'hooks = []\n',
    '[[hooks]]\nevent = "unknown"\ncommand = "echo"\n', 'text = "unterminated\n', Buffer.from([0xc3, 0x28])]) {
    await writeFile(path, source); const before = await readFile(path);
    for (const operation of ['install', 'uninstall'] as const) await assert.rejects(planKimiCodeIntegration(operation, options), rejectsCode('invalid_toml'));
    assert.deepEqual(await readFile(path), before); assert.deepEqual(await readdir(dirname(path)), ['config.toml']);
  }
});

test('Kimi Code stale review revision cannot overwrite external edits', async t => {
  const { options, path } = await fixture(t);
  await writeExisting(path, original);
  const plan = await planKimiCodeIntegration('install', options);
  await writeFile(path, '# external update\n');
  await assert.rejects(applyKimiCodeIntegration('install', plan.revision, options), rejectsCode('revision_conflict'));
  assert.equal(await readFile(path, 'utf8'), '# external update\n'); assert.deepEqual(await readdir(dirname(path)), ['config.toml']);
});

test('Kimi Code checks bytes and file identity again at the atomic replacement boundary', async t => {
  const { options, path } = await fixture(t);
  await writeExisting(path, original); const plan = await planKimiCodeIntegration('install', options);
  await assert.rejects(applyKimiCodeIntegration('install', plan.revision, { ...options,
    beforeReplace: async () => { await writeFile(path, '# concurrent editor\n'); },
  }), rejectsCode('revision_conflict'));
  assert.equal(await readFile(path, 'utf8'), '# concurrent editor\n');
  await writeFile(path, original);
  await assert.rejects(applyKimiCodeIntegration('install', plan.revision, { ...options,
    beforeReplace: async () => { await writeFile(path + '.other', original); await rename(path + '.other', path); },
  }), rejectsCode('revision_conflict'));
  assert.equal(await readFile(path, 'utf8'), original);
  assert.equal((await readdir(dirname(path))).filter(name => name.endsWith('.bak')).length, 2);
  assert.equal((await readdir(dirname(path))).some(name => name.endsWith('.xisland-lock') || name.includes('.xisland-tmp-')), false);
});

test('Kimi Code failed replacement preserves existing TOML and recoverable backup', async t => {
  const { options, path } = await fixture(t);
  await writeExisting(path, original); const plan = await planKimiCodeIntegration('install', options);
  await assert.rejects(applyKimiCodeIntegration('install', plan.revision, { ...options,
    replaceFile: async () => { const error = new Error('fixture file is locked'); Object.assign(error, { code: 'EPERM' }); throw error; },
  }), /fixture file is locked/);
  assert.equal(await readFile(path, 'utf8'), original);
  const files = await readdir(dirname(path)), backup = files.find(name => name.endsWith('.bak')); assert.ok(backup);
  assert.equal(await readFile(join(dirname(path), backup), 'utf8'), original);
  assert.equal(files.some(name => name.endsWith('.xisland-lock') || name.includes('.xisland-tmp-')), false);
});

test('Kimi Code concurrent operations respect exclusive locks and preserve preexisting locks', async t => {
  const { options, path } = await fixture(t);
  const plan = await planKimiCodeIntegration('install', options);
  let entered!: () => void, release!: () => void;
  const arrived = new Promise<void>(resolve => { entered = resolve; }), blocked = new Promise<void>(resolve => { release = resolve; });
  const first = applyKimiCodeIntegration('install', plan.revision, { ...options, beforeReplace: async () => { entered(); await blocked; } });
  await arrived;
  try { await assert.rejects(applyKimiCodeIntegration('install', plan.revision, options), rejectsCode('installation_busy')); }
  finally { release(); }
  assert.equal((await first).applied, true);
  const removal = await planKimiCodeIntegration('uninstall', options); await writeFile(path + '.xisland-lock', 'existing lock');
  await assert.rejects(applyKimiCodeIntegration('uninstall', removal.revision, options), rejectsCode('installation_busy'));
  assert.equal(await readFile(path + '.xisland-lock', 'utf8'), 'existing lock');
});

test('KIMI_CODE_HOME selects only an in-home Node config; Python .kimi and KIMI_HOME are not targets', async t => {
  const { home, options, path } = await fixture(t);
  const custom = join(home, 'custom node home');
  const result = await install({ ...options, environment: { KIMI_CODE_HOME: custom } });
  assert.equal(result.configPath, join(custom, 'config.toml'));
  await assert.rejects(readFile(path), error => (error as NodeJS.ErrnoException).code === 'ENOENT');
  const python = join(home, '.kimi'); await writeExisting(join(python, 'config.toml'), 'python sentinel');
  for (const override of [python, join(python, 'nested'), 'relative', home + '\0bad']) {
    await assert.rejects(planKimiCodeIntegration('install', { ...options, environment: { KIMI_CODE_HOME: override } }), rejectsCode('invalid_config_home'));
  }
  await assert.rejects(planKimiCodeIntegration('install', { ...options, environment: { KIMI_CODE_HOME: dirname(home) } }), rejectsCode('custom_config_outside_home'));
  assert.equal((await getKimiCodeStatus({ ...options, environment: { KIMI_HOME: python } })).configPath, path);
  assert.equal(await readFile(join(python, 'config.toml'), 'utf8'), 'python sentinel');
});

test('Kimi Code missing runtime blocks install but allows removal of owned hooks', async t => {
  const { options, resources, path } = await fixture(t);
  await writeExisting(path, original); await install(options);
  await unlink(join(resources, 'xisland-bridge.exe'));
  assert.equal((await getKimiCodeStatus(options)).runtimeReady, false);
  await assert.rejects(planKimiCodeIntegration('install', options), rejectsCode('runtime_missing'));
  const plan = await planKimiCodeIntegration('uninstall', options);
  assert.equal(plan.runtimeReady, false); assert.equal((await applyKimiCodeIntegration('uninstall', plan.revision, options)).applied, true);
  assert.equal(await readFile(path, 'utf8'), original);
});

test('Kimi Code runtime disappearance before commit preserves the old TOML', async t => {
  const { options, resources, path } = await fixture(t);
  await writeExisting(path, original); const plan = await planKimiCodeIntegration('install', options);
  await assert.rejects(applyKimiCodeIntegration('install', plan.revision, { ...options,
    beforeReplace: async () => { await unlink(join(resources, 'xisland-bridge.exe')); },
  }), rejectsCode('runtime_missing'));
  assert.equal(await readFile(path, 'utf8'), original);
});

test('Kimi Code rejects oversized files and writes without an audited revision', async t => {
  const { options, path } = await fixture(t);
  await assert.rejects(applyKimiCodeIntegration('install', '', options), rejectsCode('revision_required'));
  const bytes = Buffer.alloc(MAX_CONFIG_BYTES + 1, 35); await writeExisting(path, bytes);
  await assert.rejects(planKimiCodeIntegration('install', options), rejectsCode('config_too_large'));
  assert.deepEqual(await readFile(path), bytes);
});

test('Kimi Code refuses production resources in fixtures and symlinked config locations', async t => {
  const { options, home, path } = await fixture(t);
  await assert.rejects(planKimiCodeIntegration('install', { ...options, tempHome: tmpdir() }), rejectsCode('test_home_not_isolated'));
  await assert.rejects(planKimiCodeIntegration('install', { ...options, nodeExecutable: process.execPath }), rejectsCode('test_resource_not_isolated'));
  const outside = await realpath(await mkdtemp(join(tmpdir(), 'xisland-kimi-outside-'))); t.after(() => rm(outside, { recursive: true, force: true }));
  const target = join(outside, 'config.toml'); await writeFile(target, 'outside sentinel');
  if (!await linked(t, outside, join(home, '.kimi-code'), true)) return;
  await assert.rejects(getKimiCodeStatus(options), rejectsCode('unsafe_path')); await unlink(join(home, '.kimi-code'));
  await mkdir(dirname(path)); if (!await linked(t, target, path, false)) return;
  await assert.rejects(planKimiCodeIntegration('install', options), rejectsCode('unsafe_path'));
  assert.equal(await readFile(target, 'utf8'), 'outside sentinel');
});

test('Kimi Code directory replacement during commit never follows the link during cleanup', async t => {
  const { options, path } = await fixture(t);
  const outside = await realpath(await mkdtemp(join(tmpdir(), 'xisland-kimi-swap-'))); t.after(() => rm(outside, { recursive: true, force: true }));
  const probe = join(outside, 'probe'); if (!await linked(t, outside, probe, true)) return; await unlink(probe);
  const plan = await planKimiCodeIntegration('install', options); let expected: string[] = [];
  await assert.rejects(applyKimiCodeIntegration('install', plan.revision, { ...options, beforeReplace: async () => {
    expected = await readdir(dirname(path)); for (const name of expected) await writeFile(join(outside, name), 'outside sentinel');
    await rename(dirname(path), dirname(path) + '.moved'); await symlink(outside, dirname(path), process.platform === 'win32' ? 'junction' : 'dir');
  } }), rejectsCode('unsafe_path'));
  assert.deepEqual((await readdir(outside)).sort(), expected.sort());
  for (const name of expected) assert.equal(await readFile(join(outside, name), 'utf8'), 'outside sentinel');
});

test('Kimi Code production installation is disabled on non-Windows hosts', async t => {
  if (process.platform === 'win32') { t.skip('production-home checks are intentionally not exercised on Windows'); return; }
  assert.equal((await getKimiCodeStatus()).platformSupported, false);
  await assert.rejects(planKimiCodeIntegration('install'), rejectsCode('unsupported_platform'));
});
