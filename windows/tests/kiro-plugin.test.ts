import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, readdir, realpath, rm, stat, symlink, unlink, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { KIRO_HOOK_EVENTS } from '../src/adapters/kiro';
import { KIRO_DOCUMENTED_CLI_VERSION, KIRO_HOOK_FILE_NAME, kiroPluginFiles, kiroSetupStatus,
  prepareKiroPlugin, type KiroSetupOptions } from '../src/integrations/kiro-plugin';

async function fixture(t: TestContext) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'xisland-kiro-setup-')));
  t.after(() => rm(home, { recursive: true, force: true }));
  const resources = join(home, 'resources'); await mkdir(resources);
  const options: KiroSetupOptions = { tempHome: home, nodeExecutable: join(resources, 'node.exe'),
    hookScript: join(resources, 'xisland-hook.cjs'), bridgeExecutable: join(resources, 'xisland-bridge.exe'),
    client: { state: 'detected', detail: 'isolated Kiro CLI fixture' } };
  for (const path of [options.nodeExecutable!, options.hookScript!, options.bridgeExecutable!]) await writeFile(path, 'isolated runtime');
  return { home, options, base: join(home, 'XIsland-Plugins') };
}

test('Kiro generates the six-event standalone V3 document with neutral Windows commands', () => {
  const files = kiroPluginFiles('C:\\Program Files\\XIsland\\node.exe', 'C:\\中文 空格\\xisland-hook.cjs');
  assert.equal(KIRO_DOCUMENTED_CLI_VERSION, '2.31.0');
  assert.deepEqual(Object.keys(files).sort(), ['README.txt', 'xisland-observer.json']);
  const document = JSON.parse(files[KIRO_HOOK_FILE_NAME]!);
  assert.equal(document.version, 'v1'); assert.deepEqual(document.hooks.map((hook: { trigger: string }) => hook.trigger), [...KIRO_HOOK_EVENTS]);
  for (const hook of document.hooks) {
    assert.equal(hook.name, `XIsland:KiroV3:${hook.trigger}`); assert.equal(hook.enabled, true);
    assert.deepEqual(Object.keys(hook.action).sort(), ['command', 'type']); assert.equal(hook.action.type, 'command');
    assert.equal(hook.timeout, undefined); assert.equal(hook.action.timeout, undefined);
    const command = Buffer.from(hook.action.command.split(' -EncodedCommand ')[1], 'base64').toString('utf16le');
    assert.ok(command.includes('"--agent" "kiro"')); assert.ok(command.includes(`"--hook" "${hook.trigger}"`));
    assert.ok(command.includes('[System.IO.Stream]::Null')); assert.ok(command.includes('WaitForExit(4000)'));
    assert.ok(command.endsWith('exit 0 }')); assert.ok(!command.includes('OpenStandardOutput'));
  }
  assert.ok(files['README.txt']!.includes('不是本机版本探测结果')); assert.ok(files['README.txt']!.includes('仍待实机验收'));
});

test('Kiro status is read-only and preparation reuses identical files without touching Kiro configuration', async t => {
  const { home, options, base } = await fixture(t), before = await readdir(home);
  const status = await kiroSetupStatus(options);
  assert.equal(status.client.state, 'detected'); assert.equal(status.runtimeReady, true); assert.equal(status.needsPreparation, true);
  assert.deepEqual(await readdir(home), before);
  const first = await prepareKiroPlugin(options), path = join(first.exportedPath, KIRO_HOOK_FILE_NAME);
  assert.equal(first.eventCount, 6); assert.equal(first.observationOnly, true); assert.equal(first.clientVerified, false);
  assert.match(first.exportedPath, /kiro-[a-f0-9]{64}$/);
  const contents = await readFile(path), modifiedAt = (await stat(path)).mtimeMs;
  assert.equal((await prepareKiroPlugin(options)).exportedPath, first.exportedPath);
  assert.deepEqual(await readFile(path), contents); assert.equal((await stat(path)).mtimeMs, modifiedAt);
  assert.equal((await readdir(base)).length, 1);
  assert.equal((await kiroSetupStatus(options)).needsPreparation, false);
  await assert.rejects(readdir(join(home, '.kiro')), { code: 'ENOENT' });
});

test('Kiro runtime command changes create a separate directory and preserve the previous artifact', async t => {
  const { home, options, base } = await fixture(t), first = await prepareKiroPlugin(options);
  const original = await readFile(join(first.exportedPath, KIRO_HOOK_FILE_NAME));
  const alternate = join(home, 'alternate'); await mkdir(alternate);
  const next = { ...options, nodeExecutable: join(alternate, 'node.exe'), hookScript: join(alternate, 'xisland-hook.cjs'),
    bridgeExecutable: join(alternate, 'xisland-bridge.exe') };
  for (const path of [next.nodeExecutable, next.hookScript, next.bridgeExecutable]) await writeFile(path, 'new runtime');
  assert.equal((await kiroSetupStatus(next)).needsPreparation, true);
  assert.notEqual((await prepareKiroPlugin(next)).exportedPath, first.exportedPath);
  assert.equal((await readdir(base)).length, 2);
  assert.deepEqual(await readFile(join(first.exportedPath, KIRO_HOOK_FILE_NAME)), original);
});

for (const change of ['bytes', 'extra', 'missing', 'symlink'] as const) {
  test(`Kiro ${change} modifications are preserved and produce a fixed error`, async t => {
    const { options } = await fixture(t), prepared = await prepareKiroPlugin(options), path = join(prepared.exportedPath, KIRO_HOOK_FILE_NAME);
    if (change === 'bytes') await writeFile(path, 'user modification');
    if (change === 'extra') await writeFile(join(prepared.exportedPath, 'private-notes'), 'private');
    if (change === 'missing') await unlink(path);
    if (change === 'symlink') { await unlink(path); await symlink(options.hookScript!, path); }
    for (const operation of [kiroSetupStatus, prepareKiroPlugin]) await assert.rejects(operation(options), /^Error: modified_kiro_artifact$/);
    if (change === 'bytes') assert.equal(await readFile(path, 'utf8'), 'user modification');
  });
}

test('Kiro missing runtime and unsafe export directories cannot prepare a file', async t => {
  const first = await fixture(t), second = await fixture(t);
  await unlink(first.options.bridgeExecutable!);
  assert.equal((await kiroSetupStatus(first.options)).runtimeReady, false);
  await assert.rejects(prepareKiroPlugin(first.options), /runtime_missing/);
  await assert.rejects(readdir(first.base), { code: 'ENOENT' });
  await writeFile(first.options.bridgeExecutable!, 'restored runtime');
  await symlink(second.home, first.base, 'dir');
  for (const operation of [kiroSetupStatus, prepareKiroPlugin]) await assert.rejects(operation(first.options), /unsafe_export_directory/);
  assert.deepEqual(await readdir(second.home), ['resources']);
});

test('Kiro test resources cannot escape a temporary home and production is Windows-only', async t => {
  const first = await fixture(t), second = await fixture(t);
  for (const operation of [kiroSetupStatus, prepareKiroPlugin]) {
    await assert.rejects(operation({ nodeExecutable: first.options.nodeExecutable }), /test_override_forbidden/);
    await assert.rejects(operation({ tempHome: homedir() }), /test_home_not_isolated/);
    await assert.rejects(operation({ ...first.options, hookScript: second.options.hookScript }), /test_resource_not_isolated/);
    if (process.platform !== 'win32') await assert.rejects(operation(), /unsupported_platform/);
  }
});
