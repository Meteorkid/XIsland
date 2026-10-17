import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { applyOpenCodeIntegration, getOpenCodeStatus, openCodeConfigurationRevision, planOpenCodeIntegration, type OpenCodeInstallerOptions } from '../src/integrations/opencode-installation';
import { IntegrationError, MAX_CONFIG_BYTES } from '../src/integrations/installer';
import { openCodePluginPath, openCodePluginSource } from '../src/integrations/opencode-plugin';

async function fixture(t: TestContext) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'xisland-opencode-install-')));
  t.after(() => rm(home, { recursive: true, force: true }));
  const resources = join(home, 'resources'); await mkdir(resources);
  for (const name of ['node.exe', 'xisland-hook.cjs', 'xisland-bridge.exe']) await writeFile(join(resources, name), 'isolated fixture, never executed');
  const options: OpenCodeInstallerOptions = { tempHome: home, resourceDirectory: resources, nodeExecutable: join(resources, 'node.exe') };
  return { home, resources, options, path: openCodePluginPath(home) };
}
const rejectsCode = (code: string) => (error: unknown) => error instanceof IntegrationError && error.code === code;
async function install(options: OpenCodeInstallerOptions) {
  const plan = await planOpenCodeIntegration('install', options);
  return applyOpenCodeIntegration('install', plan.revision, options);
}
async function writeExisting(path: string, bytes: string | Buffer) {
  await mkdir(dirname(path), { recursive: true }); await writeFile(path, bytes);
}
async function linked(t: TestContext, target: string, path: string, directory: boolean): Promise<boolean> {
  try { await symlink(target, path, directory ? process.platform === 'win32' ? 'junction' : 'dir' : 'file'); return true; }
  catch (error) { if ((error as NodeJS.ErrnoException).code === 'EPERM') { t.skip('host cannot create test symlinks'); return false; } throw error; }
}

test('OpenCode status and review are read-only; installation creates exactly one independently loadable plugin', async t => {
  const { home, options, path, resources } = await fixture(t);
  const status = await getOpenCodeStatus(options);
  assert.equal(status.agent, 'opencode'); assert.equal(status.platformSupported, true);
  assert.equal(status.runtimeReady, true); assert.equal(status.installed, false); assert.equal(status.managedHandlers, 0);
  const plan = await planOpenCodeIntegration('install', options);
  assert.equal(plan.configPath, path); assert.equal(plan.addedHandlers, 1); assert.equal(plan.removedHandlers, 0);
  assert.equal(plan.revision, status.revision);
  assert.equal(plan.backup.required, false); assert.match(plan.revision, /^[a-f0-9]{64}$/);
  assert.equal('nextConfig' in plan, false); assert.equal('source' in plan, false);
  assert.deepEqual(await readdir(home), ['resources']);
  const result = await applyOpenCodeIntegration('install', plan.revision, options);
  assert.equal(result.applied, true); assert.equal(result.backupId, undefined);
  assert.notEqual(result.revision, plan.revision);
  assert.equal(await readFile(path, 'utf8'), openCodePluginSource(join(resources, 'node.exe'), join(resources, 'xisland-hook.cjs')));
  assert.deepEqual(await readdir(dirname(path)), ['xisland.js']);
  const installed = await getOpenCodeStatus(options);
  assert.equal(installed.installed, true); assert.equal(installed.managedHandlers, 1);
  const rawRevision = createHash('sha256').update('present\0').update(await readFile(path)).digest('hex');
  assert.equal(result.revision, openCodeConfigurationRevision(path, rawRevision, options.nodeExecutable!, join(resources, 'xisland-hook.cjs')));
  assert.equal(installed.revision, result.revision);
  assert.equal(JSON.stringify(result).includes('const NODE'), false);
});

test('OpenCode repeat installation is a no-op without rewriting or adding backups', async t => {
  const { options, path } = await fixture(t);
  const installed = await install(options), original = await readFile(path);
  const plan = await planOpenCodeIntegration('install', options);
  assert.equal(plan.changed, false); assert.equal(plan.addedHandlers, 0); assert.equal(plan.backup.required, false);
  const result = await applyOpenCodeIntegration('install', plan.revision, options);
  assert.equal(result.applied, false); assert.equal(result.revision, installed.revision);
  assert.deepEqual(await readFile(path), original); assert.deepEqual(await readdir(dirname(path)), ['xisland.js']);
});

test('OpenCode uninstall preserves a byte-exact backup and works when runtime has been removed', async t => {
  const { options, path, resources } = await fixture(t);
  await install(options); const original = await readFile(path);
  await unlink(join(resources, 'xisland-bridge.exe'));
  const plan = await planOpenCodeIntegration('uninstall', options);
  assert.equal(plan.runtimeReady, false); assert.equal(plan.removedHandlers, 1); assert.equal(plan.addedHandlers, 0);
  assert.equal(plan.backup.required, true);
  const result = await applyOpenCodeIntegration('uninstall', plan.revision, options);
  assert.equal(result.applied, true); assert.ok(result.backupId);
  assert.deepEqual(await readFile(join(dirname(path), result.backupId!)), original);
  const removed = await getOpenCodeStatus(options);
  assert.equal(removed.installed, false); assert.equal(removed.revision, result.revision);
  await assert.rejects(readFile(path), error => (error as NodeJS.ErrnoException).code === 'ENOENT');
  const again = await planOpenCodeIntegration('uninstall', options);
  const unchanged = await applyOpenCodeIntegration('uninstall', again.revision, options);
  assert.equal(unchanged.applied, false); assert.equal(unchanged.revision, result.revision);
  assert.deepEqual(await readdir(dirname(path)), [result.backupId!]);
});

test('OpenCode missing-plugin uninstall does not create configuration directories', async t => {
  const { home, options } = await fixture(t);
  const plan = await planOpenCodeIntegration('uninstall', options);
  assert.equal(plan.changed, false);
  assert.equal((await applyOpenCodeIntegration('uninstall', plan.revision, options)).applied, false);
  assert.deepEqual(await readdir(home), ['resources']);
});

test('OpenCode runtime-path updates back up the old owned source before atomic replacement', async t => {
  const { home, options, path } = await fixture(t);
  await install(options); const original = await readFile(path);
  const oldPlan = await planOpenCodeIntegration('install', options);
  const moved = join(home, 'new resources'); await mkdir(moved);
  for (const name of ['node.exe', 'xisland-hook.cjs', 'xisland-bridge.exe']) await writeFile(join(moved, name), 'new runtime fixture');
  for (const changed of [{ ...options, nodeExecutable: join(moved, 'node.exe') }, { ...options, resourceDirectory: moved }]) {
    await assert.rejects(applyOpenCodeIntegration('install', oldPlan.revision, changed), rejectsCode('revision_conflict'));
    assert.deepEqual(await readFile(path), original); assert.deepEqual(await readdir(dirname(path)), ['xisland.js']);
  }
  const updatedOptions = { ...options, resourceDirectory: moved, nodeExecutable: join(moved, 'node.exe') };
  const status = await getOpenCodeStatus(updatedOptions);
  assert.equal(status.installed, false); assert.equal(status.updateAvailable, true); assert.equal(status.managedHandlers, 1);
  const plan = await planOpenCodeIntegration('install', updatedOptions);
  assert.equal(plan.changed, true); assert.equal(plan.addedHandlers, 1); assert.equal(plan.removedHandlers, 1);
  const updated = await applyOpenCodeIntegration('install', plan.revision, updatedOptions);
  assert.ok(updated.backupId); assert.deepEqual(await readFile(join(dirname(path), updated.backupId!)), original);
  assert.equal(await readFile(path, 'utf8'), openCodePluginSource(join(moved, 'node.exe'), join(moved, 'xisland-hook.cjs')));
});

test('OpenCode refuses foreign, edited, appended, BOM and invalid-UTF8 files without exposing source', async t => {
  const { options, path, resources } = await fixture(t);
  const owned = openCodePluginSource(join(resources, 'node.exe'), join(resources, 'xisland-hook.cjs'));
  for (const source of ['// user secret text', owned + '\n// user secret text', owned.replace('once', 'always'),
    Buffer.from('\ufeff' + owned), Buffer.from([0xc3, 0x28])]) {
    await writeExisting(path, source);
    const bytes = await readFile(path), status = await getOpenCodeStatus(options);
    assert.equal(status.foreignPlugin, true); assert.equal(status.managedHandlers, 0); assert.equal(status.installed, false);
    assert.equal(JSON.stringify(status).includes('user secret text'), false);
    for (const operation of ['install', 'uninstall'] as const) {
      await assert.rejects(planOpenCodeIntegration(operation, options), rejectsCode('foreign_plugin'));
      await assert.rejects(applyOpenCodeIntegration(operation, status.revision!, options), rejectsCode('foreign_plugin'));
    }
    assert.deepEqual(await readFile(path), bytes); assert.deepEqual(await readdir(dirname(path)), ['xisland.js']);
  }
});

test('OpenCode oversized files are rejected without truncation or backups', async t => {
  const { options, path } = await fixture(t);
  const bytes = Buffer.alloc(MAX_CONFIG_BYTES + 1, 120); await writeExisting(path, bytes);
  await assert.rejects(getOpenCodeStatus(options), rejectsCode('config_too_large'));
  await assert.rejects(planOpenCodeIntegration('install', options), rejectsCode('config_too_large'));
  assert.deepEqual(await readFile(path), bytes); assert.deepEqual(await readdir(dirname(path)), ['xisland.js']);
});

test('OpenCode stale review revision preserves an external update', async t => {
  const { options, path } = await fixture(t);
  const plan = await planOpenCodeIntegration('install', options);
  const foreign = '// external update'; await writeExisting(path, foreign);
  await assert.rejects(applyOpenCodeIntegration('install', plan.revision, options), rejectsCode('revision_conflict'));
  assert.equal(await readFile(path, 'utf8'), foreign); assert.deepEqual(await readdir(dirname(path)), ['xisland.js']);
});

test('OpenCode rechecks revision and file identity immediately before replacement', async t => {
  const { options, path } = await fixture(t);
  await install(options); const original = await readFile(path);
  const plan = await planOpenCodeIntegration('uninstall', options);
  await assert.rejects(applyOpenCodeIntegration('uninstall', plan.revision, { ...options,
    beforeReplace: async () => { await writeFile(path, '// changed while applying'); },
  }), rejectsCode('revision_conflict'));
  assert.equal(await readFile(path, 'utf8'), '// changed while applying');
  await writeFile(path, original);
  await assert.rejects(applyOpenCodeIntegration('uninstall', plan.revision, { ...options,
    beforeReplace: async () => { const external = path + '.external'; await writeFile(external, original); await rename(external, path); },
  }), rejectsCode('revision_conflict'));
  assert.deepEqual(await readFile(path), original);
  const files = await readdir(dirname(path));
  assert.equal(files.filter(name => name.endsWith('.bak')).length, 2);
  assert.equal(files.some(name => name.endsWith('.xisland-lock') || name.includes('.xisland-tmp-')), false);
});

test('OpenCode Windows-style rename failures leave the old plugin and recoverable backup intact', async t => {
  const { options, path, resources } = await fixture(t);
  const oldSource = openCodePluginSource(join(resources, 'old-node.exe'), join(resources, 'xisland-hook.cjs'));
  await writeExisting(path, oldSource);
  for (const operation of ['install', 'uninstall'] as const) {
    const plan = await planOpenCodeIntegration(operation, options);
    await assert.rejects(applyOpenCodeIntegration(operation, plan.revision, { ...options,
      replaceFile: async () => { const error = new Error('fixture file is open'); Object.assign(error, { code: 'EPERM' }); throw error; },
    }), /fixture file is open/);
    assert.equal(await readFile(path, 'utf8'), oldSource);
    const files = await readdir(dirname(path));
    assert.equal(files.some(name => name.endsWith('.xisland-lock') || name.includes('.xisland-tmp-')), false);
    for (const backup of files.filter(name => name.endsWith('.bak'))) assert.equal(await readFile(join(dirname(path), backup), 'utf8'), oldSource);
  }
});

test('OpenCode concurrent writers cannot bypass the exclusive application lock', async t => {
  const { options, path } = await fixture(t);
  const plan = await planOpenCodeIntegration('install', options);
  let entered!: () => void, release!: () => void;
  const arrived = new Promise<void>(resolve => { entered = resolve; });
  const blocked = new Promise<void>(resolve => { release = resolve; });
  const first = applyOpenCodeIntegration('install', plan.revision, { ...options, beforeReplace: async () => { entered(); await blocked; } });
  await arrived;
  try { await assert.rejects(applyOpenCodeIntegration('install', plan.revision, options), rejectsCode('installation_busy')); }
  finally { release(); }
  assert.equal((await first).applied, true); assert.deepEqual(await readdir(dirname(path)), ['xisland.js']);
});

test('OpenCode existing application locks remain untouched', async t => {
  const { options, path } = await fixture(t);
  const plan = await planOpenCodeIntegration('install', options);
  await writeExisting(path + '.xisland-lock', 'existing lock');
  await assert.rejects(applyOpenCodeIntegration('install', plan.revision, options), rejectsCode('installation_busy'));
  assert.equal(await readFile(path + '.xisland-lock', 'utf8'), 'existing lock');
});

test('OpenCode XDG_CONFIG_HOME is honored inside isolated home and never silently falls back', async t => {
  const { options, home, path } = await fixture(t);
  const originalPlan = await planOpenCodeIntegration('install', options);
  const custom = join(home, 'custom configuration');
  const customOptions = { ...options, environment: { XDG_CONFIG_HOME: custom } };
  await assert.rejects(applyOpenCodeIntegration('install', originalPlan.revision, customOptions), rejectsCode('revision_conflict'));
  assert.deepEqual(await readdir(home), ['resources']);
  const result = await install(customOptions);
  assert.equal(result.configPath, join(custom, 'opencode', 'plugins', 'xisland.js'));
  assert.equal((await getOpenCodeStatus(customOptions)).installed, true);
  await assert.rejects(readFile(path), error => (error as NodeJS.ErrnoException).code === 'ENOENT');
  for (const value of ['relative', home + '\0bad', home + '\nbad']) {
    await assert.rejects(planOpenCodeIntegration('install', { ...options, environment: { XDG_CONFIG_HOME: value } }), rejectsCode('invalid_config_home'));
  }
  await assert.rejects(planOpenCodeIntegration('install', { ...options, environment: { XDG_CONFIG_HOME: dirname(home) } }), rejectsCode('custom_config_outside_home'));
  assert.equal((await getOpenCodeStatus({ ...options, environment: { XDG_CONFIG_HOME: '' } })).configPath, path);
  assert.equal((await getOpenCodeStatus(options)).installed, false);
});

test('OpenCode test paths cannot use temporary root, production runtime, or symlink escape', async t => {
  const { options, home, resources } = await fixture(t);
  await assert.rejects(planOpenCodeIntegration('install', { ...options, tempHome: tmpdir() }), rejectsCode('test_home_not_isolated'));
  await assert.rejects(planOpenCodeIntegration('install', { ...options, tempHome: 'relative' }), rejectsCode('test_home_not_isolated'));
  await assert.rejects(planOpenCodeIntegration('install', { ...options, nodeExecutable: process.execPath }), rejectsCode('test_resource_not_isolated'));
  const link = join(home, 'linked-resources');
  if (!await linked(t, resources, link, true)) return;
  await assert.rejects(planOpenCodeIntegration('install', { ...options, resourceDirectory: link }), rejectsCode('unsafe_path'));
});

test('OpenCode config directory and plugin symlinks preserve their targets', async t => {
  const { options, home, path } = await fixture(t);
  const outside = await realpath(await mkdtemp(join(tmpdir(), 'xisland-opencode-outside-')));
  t.after(() => rm(outside, { recursive: true, force: true }));
  const target = join(outside, 'xisland.js'); await writeFile(target, 'outside sentinel');
  if (!await linked(t, outside, join(home, '.config'), true)) return;
  await assert.rejects(getOpenCodeStatus(options), rejectsCode('unsafe_path'));
  await unlink(join(home, '.config'));
  await mkdir(dirname(path), { recursive: true });
  if (!await linked(t, target, path, false)) return;
  await assert.rejects(getOpenCodeStatus(options), rejectsCode('unsafe_path'));
  assert.equal(await readFile(target, 'utf8'), 'outside sentinel');
});

test('OpenCode does not follow a directory swapped to a link during commit or cleanup', async t => {
  const { options, path } = await fixture(t);
  const outside = await realpath(await mkdtemp(join(tmpdir(), 'xisland-opencode-swap-')));
  t.after(() => rm(outside, { recursive: true, force: true }));
  const probe = join(outside, 'link-probe');
  if (!await linked(t, outside, probe, true)) return;
  await unlink(probe);
  const plan = await planOpenCodeIntegration('install', options);
  let expected: string[] = [];
  await assert.rejects(applyOpenCodeIntegration('install', plan.revision, { ...options, beforeReplace: async () => {
    const directory = dirname(path);
    expected = await readdir(directory);
    for (const name of expected) await writeFile(join(outside, name), 'outside sentinel');
    await rename(directory, directory + '.moved');
    await symlink(outside, directory, process.platform === 'win32' ? 'junction' : 'dir');
  } }), rejectsCode('unsafe_path'));
  assert.deepEqual((await readdir(outside)).sort(), expected.sort());
  for (const name of expected) assert.equal(await readFile(join(outside, name), 'utf8'), 'outside sentinel');
});

test('OpenCode absent runtime and unreviewed writes are rejected; uninstall remains available', async t => {
  const { options, resources } = await fixture(t);
  await unlink(join(resources, 'xisland-bridge.exe'));
  assert.equal((await getOpenCodeStatus(options)).runtimeReady, false);
  await assert.rejects(planOpenCodeIntegration('install', options), rejectsCode('runtime_missing'));
  await assert.rejects(applyOpenCodeIntegration('install', '', options), rejectsCode('revision_required'));
  assert.equal((await planOpenCodeIntegration('uninstall', options)).changed, false);
});

test('OpenCode runtime disappearing during commit cannot leave a newly installed broken plugin', async t => {
  const { options, resources, path } = await fixture(t);
  const plan = await planOpenCodeIntegration('install', options);
  await assert.rejects(applyOpenCodeIntegration('install', plan.revision, { ...options,
    beforeReplace: async () => { await unlink(join(resources, 'xisland-bridge.exe')); },
  }), rejectsCode('runtime_missing'));
  assert.deepEqual(await readdir(dirname(path)), []);
});

test('OpenCode production installation service is disabled on non-Windows hosts', async t => {
  if (process.platform === 'win32') { t.skip('production-home checks are intentionally not exercised on Windows'); return; }
  const status = await getOpenCodeStatus();
  assert.equal(status.platformSupported, false); assert.equal(status.runtimeReady, false); assert.equal(status.installed, false);
  await assert.rejects(planOpenCodeIntegration('install'), rejectsCode('unsupported_platform'));
});
