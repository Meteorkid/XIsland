import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, readdir, realpath, rm, stat, symlink, unlink, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { prepareWorkBuddyPlugin, workBuddySetupStatus, type WorkBuddySetupOptions } from '../src/integrations/workbuddy-plugin';

async function fixture(t: TestContext) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'xisland-workbuddy-setup-')));
  t.after(() => rm(home, { recursive: true, force: true }));
  const resources = join(home, 'resources'); await mkdir(resources);
  const options: WorkBuddySetupOptions = { tempHome: home, nodeExecutable: join(resources, 'node.exe'),
    hookScript: join(resources, 'xisland-hook.cjs'), bridgeExecutable: join(resources, 'xisland-bridge.exe'),
    client: { state: 'detected', detail: 'isolated WorkBuddy fixture' } };
  for (const path of [options.nodeExecutable!, options.hookScript!, options.bridgeExecutable!]) await writeFile(path, 'isolated runtime');
  return { home, options, base: join(home, 'XIsland-Plugins') };
}

test('WorkBuddy setup status is read-only and preparation reuses exact content without modifying files', async t => {
  const { home, options, base } = await fixture(t), before = await readdir(home);
  const status = await workBuddySetupStatus(options);
  assert.equal(status.agent, 'workbuddy'); assert.equal(status.client.state, 'detected');
  assert.equal(status.runtimeReady, true); assert.equal(status.needsPreparation, true); assert.equal(status.exportedPath, undefined);
  assert.deepEqual(await readdir(home), before);
  const first = await prepareWorkBuddyPlugin(options);
  assert.match(first.exportedPath, /workbuddy-[a-f0-9]{64}$/);
  assert.equal(first.clientVerified, false); assert.equal(first.observationOnly, true); assert.equal(first.eventCount, 11);
  const path = join(first.exportedPath, 'hooks', 'hooks.json'), original = await readFile(path), modifiedAt = (await stat(path)).mtimeMs;
  const second = await prepareWorkBuddyPlugin(options);
  assert.equal(second.exportedPath, first.exportedPath); assert.equal((await stat(path)).mtimeMs, modifiedAt);
  assert.deepEqual(await readFile(path), original); assert.equal((await readdir(base)).length, 1);
  assert.deepEqual(await workBuddySetupStatus(options), { agent: 'workbuddy', client: options.client, runtimeReady: true,
    needsPreparation: false, exportedPath: first.exportedPath });
});

test('WorkBuddy changed runtime command paths prepare a new content-addressed directory and preserve old exports', async t => {
  const { home, options, base } = await fixture(t);
  const first = await prepareWorkBuddyPlugin(options), oldHooks = await readFile(join(first.exportedPath, 'hooks', 'hooks.json'));
  const alternate = join(home, 'new-runtime'); await mkdir(alternate);
  const next = { ...options, nodeExecutable: join(alternate, 'node.exe'), hookScript: join(alternate, 'xisland-hook.cjs'),
    bridgeExecutable: join(alternate, 'xisland-bridge.exe') };
  for (const path of [next.nodeExecutable, next.hookScript, next.bridgeExecutable]) await writeFile(path, 'next runtime');
  assert.equal((await workBuddySetupStatus(next)).needsPreparation, true);
  const second = await prepareWorkBuddyPlugin(next);
  assert.notEqual(second.exportedPath, first.exportedPath); assert.equal((await readdir(base)).length, 2);
  assert.deepEqual(await readFile(join(first.exportedPath, 'hooks', 'hooks.json')), oldHooks);
});

for (const change of ['bytes', 'extra-file', 'extra-directory', 'missing', 'symlink'] as const) {
  test(`WorkBuddy ${change} changes are reported without replacing user artifacts`, async t => {
    const { home, options } = await fixture(t), prepared = await prepareWorkBuddyPlugin(options);
    const path = join(prepared.exportedPath, 'README.txt');
    if (change === 'bytes') await writeFile(path, 'user modification');
    if (change === 'extra-file') await writeFile(join(prepared.exportedPath, 'my-notes.txt'), 'private notes');
    if (change === 'extra-directory') await mkdir(join(prepared.exportedPath, 'my-notes'));
    if (change === 'missing') await unlink(path);
    if (change === 'symlink') { await unlink(path); await symlink(options.hookScript!, path); }
    for (const operation of [workBuddySetupStatus, prepareWorkBuddyPlugin]) {
      await assert.rejects(operation(options), error => error instanceof Error && error.message === 'modified_workbuddy_artifact'
        && !error.message.includes(home));
    }
    if (change === 'bytes') assert.equal(await readFile(path, 'utf8'), 'user modification');
    if (change === 'extra-file') assert.equal(await readFile(join(prepared.exportedPath, 'my-notes.txt'), 'utf8'), 'private notes');
  });
}

test('WorkBuddy missing runtime does not prepare files and unsafe destinations never follow links', async t => {
  const first = await fixture(t), second = await fixture(t);
  await unlink(first.options.bridgeExecutable!);
  assert.equal((await workBuddySetupStatus(first.options)).runtimeReady, false);
  await assert.rejects(prepareWorkBuddyPlugin(first.options), /runtime_missing/);
  await assert.rejects(readdir(first.base), { code: 'ENOENT' });
  await writeFile(first.options.bridgeExecutable!, 'restored runtime');
  await symlink(second.home, first.base, 'dir');
  for (const operation of [workBuddySetupStatus, prepareWorkBuddyPlugin]) await assert.rejects(operation(first.options), /unsafe_export_directory/);
  assert.deepEqual(await readdir(second.home), ['resources']);
});

test('WorkBuddy setup overrides cannot leave a temporary home or activate on non-Windows production hosts', async t => {
  const first = await fixture(t), second = await fixture(t);
  for (const operation of [workBuddySetupStatus, prepareWorkBuddyPlugin]) {
    await assert.rejects(operation({ nodeExecutable: first.options.nodeExecutable }), /test_override_forbidden/);
    await assert.rejects(operation({ tempHome: homedir() }), /test_home_not_isolated/);
    await assert.rejects(operation({ ...first.options, hookScript: second.options.hookScript }), /test_resource_not_isolated/);
    const link = join(first.home, 'linked-node.exe');
    if (operation === workBuddySetupStatus) await symlink(second.options.nodeExecutable!, link);
    await assert.rejects(operation({ ...first.options, nodeExecutable: link }), /test_resource_not_isolated/);
    if (process.platform !== 'win32') await assert.rejects(operation(), /unsupported_platform/);
  }
});
