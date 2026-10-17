import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, unlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { test, type TestContext } from 'node:test';
import { applyIntegration, getIntegrationStatus, IntegrationError, MAX_CONFIG_BYTES, planIntegration, rollbackIntegration, type InstallerOptions } from '../src/integrations/installer';
import { CONFIGURABLE_AGENTS, type ConfigurableAgent } from '../src/adapters/registry';

async function fixture(t: TestContext) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'xisland-installer-test-')));
  t.after(() => rm(home, { recursive: true, force: true }));
  const resources = join(home, 'resources'); await mkdir(resources);
  const node = join(resources, 'node.exe');
  for (const file of [node, join(resources, 'xisland-hook.cjs'), join(resources, 'xisland-bridge.exe')]) await writeFile(file, 'test resource; never executed');
  const options: InstallerOptions = { tempHome: home, resourceDirectory: resources, nodeExecutable: node };
  return { home, resources, options };
}

async function configuration(home: string, value: unknown, agent: ConfigurableAgent = 'claude_code') {
  const directory = join(home, { claude_code: '.claude', codex: '.codex', cursor: '.cursor', gemini_cli: '.gemini', windsurf: '.codeium/windsurf', trae_cn: '.trae-cn', qwen: '.qwen', code_buddy: '.codebuddy', droid: '.factory' }[agent]);
  await mkdir(directory, { recursive: true });
  const path = join(directory, ['codex', 'cursor', 'windsurf', 'trae_cn'].includes(agent) ? 'hooks.json' : 'settings.json');
  const bytes = typeof value === 'string' || Buffer.isBuffer(value) ? value : JSON.stringify(value, null, 2) + '\r\n';
  await writeFile(path, bytes);
  return { path, directory };
}

const rejectsCode = (code: string) => (error: unknown) => error instanceof IntegrationError && error.code === code;

test('Droid preserves standalone hooks and never shadows the legacy file when selecting its target', async t => {
  const {home,options}=await fixture(t);
  const legacy=await configuration(home,{theme:'preserve',hooks:{}},'droid');
  const standalone=join(legacy.directory,'hooks.json');
  const foreign={matcher:'Read',hooks:[{type:'command',command:'user-owned-command'}]};
  await writeFile(standalone,JSON.stringify({PreToolUse:[foreign]}));
  const plan=await planIntegration('droid','install',options);
  assert.equal(plan.configPath,standalone);
  const installed=await applyIntegration('droid','install',plan.revision,options);
  const data=JSON.parse(await readFile(standalone,'utf8'));
  assert.equal(data.hooks,undefined);assert.deepEqual(data.PreToolUse[0],foreign);
  assert.deepEqual(JSON.parse(await readFile(legacy.path,'utf8')),{theme:'preserve',hooks:{}});
  await applyIntegration('droid','uninstall',installed.revision,options);
  assert.deepEqual(JSON.parse(await readFile(standalone,'utf8')),{PreToolUse:[foreign]});
});

test('Droid review is invalidated when the selected configuration changes even with identical bytes', async t => {
  const {home,options}=await fixture(t);const legacy=await configuration(home,'{}','droid');
  const plan=await planIntegration('droid','install',options);
  const standalone=join(legacy.directory,'hooks.json');await writeFile(standalone,'{}');
  await assert.rejects(applyIntegration('droid','install',plan.revision,options),rejectsCode('revision_conflict'));
  assert.equal(await readFile(legacy.path,'utf8'),'{}');assert.equal(await readFile(standalone,'utf8'),'{}');
  await unlink(standalone);
  await assert.rejects(applyIntegration('droid','install',plan.revision,{...options,beforeReplace:()=>writeFile(standalone,'{}')}),rejectsCode('revision_conflict'));
  assert.equal(await readFile(legacy.path,'utf8'),'{}');
});

test('all registered installers read, plan, write, and repeat without duplicate handlers', async t => {
  const { home, options } = await fixture(t);
  for (const agent of CONFIGURABLE_AGENTS) {
    const status = await getIntegrationStatus(agent, options);
    assert.equal(status.installed, false); assert.equal(status.runtimeReady, true);
    const plan = await planIntegration(agent, 'install', options);
    assert.equal(plan.changed, true); assert.equal(plan.backup.required, false);
    assert.match(plan.revision, /^[a-f0-9]{64}$/);
    assert.equal('nextConfig' in plan, false);
    const applied = await applyIntegration(agent, 'install', plan.revision, options);
    assert.equal(applied.applied, true); assert.notEqual(applied.revision, plan.revision);
    assert.equal('nextConfig' in applied, false);
    assert.equal((await getIntegrationStatus(agent, options)).installed, true);
    const again = await planIntegration(agent, 'install', options);
    assert.equal(again.changed, false);
    const noWrite = await applyIntegration(agent, 'install', again.revision, options);
    assert.equal(noWrite.applied, false); assert.equal(noWrite.revision, again.revision);
    assert.equal(applied.configPath.startsWith(home), true);
  }
});

test('existing file is backed up byte-for-byte and summaries contain no secret values', async t => {
  const { home, options } = await fixture(t);
  const raw = '{ "apiKey":"secret-to-preserve", "hooks":{}, "custom":true }\r\n';
  const { path, directory } = await configuration(home, raw);
  const plan = await planIntegration('claude_code', 'install', options);
  assert.equal(plan.backup.required, true); assert.equal(JSON.stringify(plan).includes('secret-to-preserve'), false);
  const result = await applyIntegration('claude_code', 'install', plan.revision, options);
  assert.equal(result.applied, true);
  const backupId = 'backupId' in result ? result.backupId : undefined;
  assert.ok(backupId);
  assert.equal(await readFile(join(directory, backupId), 'utf8'), raw);
  assert.equal(JSON.parse(await readFile(path, 'utf8')).apiKey, 'secret-to-preserve');
  assert.equal(JSON.stringify(result).includes('secret-to-preserve'), false);
  assert.equal(JSON.stringify(await getIntegrationStatus('claude_code', options)).includes('secret-to-preserve'), false);
});

test('uninstall removes only managed entries even when the bridge was removed', async t => {
  const { home, resources, options } = await fixture(t);
  const original = { preferences: { theme: 'dark' }, hooks: { SessionStart: [{ hooks: [{ type: 'command', command: 'echo user-owned' }] }] } };
  const { path } = await configuration(home, original);
  const plan = await planIntegration('claude_code', 'install', options);
  await applyIntegration('claude_code', 'install', plan.revision, options);
  await unlink(join(resources, 'xisland-bridge.exe'));
  const removal = await planIntegration('claude_code', 'uninstall', options);
  assert.equal(removal.runtimeReady, false);
  await applyIntegration('claude_code', 'uninstall', removal.revision, options);
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), original);
  const repeat = await planIntegration('claude_code', 'uninstall', options);
  assert.equal(repeat.changed, false);
});

test('stale plan revision prevents overwriting intervening user changes', async t => {
  const { home, options } = await fixture(t);
  const { path, directory } = await configuration(home, { user: 'before' });
  const plan = await planIntegration('claude_code', 'install', options);
  const changed = '{"user":"after"}'; await writeFile(path, changed);
  await assert.rejects(applyIntegration('claude_code', 'install', plan.revision, options), rejectsCode('revision_conflict'));
  assert.equal(await readFile(path, 'utf8'), changed);
  assert.deepEqual(await readdir(directory), ['settings.json']);
});

test('revision is checked again immediately before replacement', async t => {
  const { home, options } = await fixture(t);
  const { path, directory } = await configuration(home, { user: 'before' });
  const plan = await planIntegration('claude_code', 'install', options);
  const changed = '{"user":"changed-during-commit"}';
  await assert.rejects(applyIntegration('claude_code', 'install', plan.revision, {
    ...options, beforeReplace: async () => { await writeFile(path, changed); },
  }), rejectsCode('revision_conflict'));
  assert.equal(await readFile(path, 'utf8'), changed);
  const names = await readdir(directory);
  assert.equal(names.some(name => name.includes('.xisland-tmp-') || name.endsWith('.xisland-lock')), false);
});

test('Windows-style rename failure leaves the original file and its recoverable backup', async t => {
  const { home, options } = await fixture(t);
  const raw = '{"user":"original"}'; const { path, directory } = await configuration(home, raw);
  const plan = await planIntegration('claude_code', 'install', options);
  await assert.rejects(applyIntegration('claude_code', 'install', plan.revision, {
    ...options, replaceFile: async () => { const error = new Error('file is open'); Object.assign(error, { code: 'EPERM' }); throw error; },
  }), /file is open/);
  assert.equal(await readFile(path, 'utf8'), raw);
  const names = await readdir(directory), backup = names.find(name => name.endsWith('.bak'));
  assert.ok(backup); assert.equal(await readFile(join(directory, backup), 'utf8'), raw);
  assert.equal(names.some(name => name.includes('.xisland-tmp-') || name.endsWith('.xisland-lock')), false);
});

test('backup rollback is explicit, checks revision, and saves the replaced state', async t => {
  const { home, options } = await fixture(t);
  const raw = '{"user":"original","hooks":{}}\r\n'; const { path, directory } = await configuration(home, raw);
  const plan = await planIntegration('claude_code', 'install', options);
  const installed = await applyIntegration('claude_code', 'install', plan.revision, options);
  const backupId = 'backupId' in installed ? installed.backupId : undefined; assert.ok(backupId);
  const installedBytes = await readFile(path);
  await assert.rejects(rollbackIntegration('claude_code', '../escape.bak', installed.revision, options), rejectsCode('invalid_backup'));
  await assert.rejects(rollbackIntegration('claude_code', backupId, plan.revision, options), rejectsCode('revision_conflict'));
  const result = await rollbackIntegration('claude_code', backupId, installed.revision, options);
  assert.equal(await readFile(path, 'utf8'), raw); assert.equal(result.revision, plan.revision);
  assert.ok(result.backupId); assert.notEqual(result.backupId, backupId);
  assert.deepEqual(await readFile(join(directory, result.backupId)), installedBytes);
});

test('malformed JSON, invalid UTF-8 and oversized configurations are never rewritten', async t => {
  const { home, options } = await fixture(t);
  for (const [raw, code] of [[Buffer.from('{"bad"'), 'invalid_json'], [Buffer.from([0xc3, 0x28]), 'invalid_json'],
    [Buffer.alloc(MAX_CONFIG_BYTES + 1, 120), 'config_too_large']] as const) {
    const { path, directory } = await configuration(home, raw);
    await assert.rejects(planIntegration('claude_code', 'install', options), rejectsCode(code));
    await assert.rejects(applyIntegration('claude_code', 'install', 'a'.repeat(64), options), rejectsCode(code));
    assert.deepEqual(await readFile(path), raw);
    assert.deepEqual(await readdir(directory), ['settings.json']);
  }
});

test('install refuses missing runtime and apply requires a revision', async t => {
  const { resources, options } = await fixture(t);
  await unlink(join(resources, 'node.exe'));
  assert.equal((await getIntegrationStatus('claude_code', options)).runtimeReady, false);
  await assert.rejects(planIntegration('claude_code', 'install', options), rejectsCode('runtime_missing'));
  await assert.rejects(applyIntegration('claude_code', 'install', '', options), rejectsCode('revision_required'));
});

test('concurrent installation requests cannot write through the same application lock', async t => {
  const { options } = await fixture(t);
  const plan = await planIntegration('claude_code', 'install', options);
  let signal!: () => void, release!: () => void;
  const entered = new Promise<void>(resolve => { signal = resolve; });
  const blocked = new Promise<void>(resolve => { release = resolve; });
  const first = applyIntegration('claude_code', 'install', plan.revision, { ...options, beforeReplace: async () => { signal(); await blocked; } });
  await entered;
  try { await assert.rejects(applyIntegration('claude_code', 'install', plan.revision, options), rejectsCode('installation_busy')); }
  finally { release(); }
  assert.equal((await first).applied, true);
});

test('test paths cannot use the temporary root or escape to real installed Node', async t => {
  const { options } = await fixture(t);
  await assert.rejects(planIntegration('claude_code', 'install', { ...options, tempHome: tmpdir() }), rejectsCode('test_home_not_isolated'));
  await assert.rejects(planIntegration('claude_code', 'install', { ...options, nodeExecutable: process.execPath }), rejectsCode('test_resource_not_isolated'));
});

test('symlinked configuration directories are rejected without touching the destination', async t => {
  const { home, options } = await fixture(t);
  const target = await mkdtemp(join(tmpdir(), 'xisland-installer-outside-'));
  t.after(() => rm(target, { recursive: true, force: true }));
  await writeFile(join(target, 'settings.json'), '{"outside":true}');
  try { await symlink(target, join(home, '.claude'), process.platform === 'win32' ? 'junction' : 'dir'); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === 'EPERM') { t.skip('host cannot create a test symlink'); return; } throw error; }
  await assert.rejects(planIntegration('claude_code', 'install', options), rejectsCode('unsafe_path'));
  assert.equal(await readFile(join(target, 'settings.json'), 'utf8'), '{"outside":true}');
});
