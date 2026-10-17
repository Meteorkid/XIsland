import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { adapterFor } from '../src/adapters/registry';
import { windowsHookCommand } from '../src/integrations/plan';
import { configurationRevision } from '../src/integrations/installer';
import { applyKimiCodeIntegration, getKimiCodeStatus, planKimiCodeIntegration } from '../src/integrations/kimi-installation';
import { applyOpenCodeIntegration, getOpenCodeStatus, planOpenCodeIntegration } from '../src/integrations/opencode-installation';
import { connectionIdentity, decorateIntegrationStatus, recordAcceptedIntegrationActivity, recordIntegrationActivity, type ConnectionHealthOptions,
  type ConnectionIdentity, type ConnectionStatus } from '../src/integrations/connection-health';

const now = Date.parse('2026-10-17T00:00:00Z');

test('Droid activity identity binds the selected configuration path as well as its bytes', async t => {
  const {status,options}=await fixture(t,'droid');
  status.revision=configurationRevision('droid',status.configPath!,status.revision!);
  const identity=await connectionIdentity(status,options);assert.ok(identity);
  await recordIntegrationActivity(identity,'SessionStart',options);
  assert.equal((await decorateIntegrationStatus(status,options)).activity?.event,'SessionStart');
  const other=join(options.tempHome!,'hooks.json');await writeFile(other,'{}');
  assert.equal(await connectionIdentity({...status,configPath:other},options),undefined);
});
const revision = (content: string) => createHash('sha256').update('present\0').update(content).digest('hex');
async function fixture(t: TestContext, agent = 'qwen') {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'xisland-connection-health-'))); t.after(() => rm(home, { recursive: true, force: true }));
  const resources = join(home, 'resources'); await mkdir(resources);
  const testRuntime = { nodeExecutable: join(resources, 'node.exe'), hookScript: join(resources, 'xisland-hook.cjs'), bridgeExecutable: join(resources, 'xisland-bridge.exe') };
  for (const path of Object.values(testRuntime)) await writeFile(path, 'fixture runtime ' + path);
  const configPath = join(home, 'settings.json'); await writeFile(configPath, '{}');
  const status: ConnectionStatus = { agent, installed: true, runtimeReady: true, revision: revision('{}'), configPath };
  const options: ConnectionHealthOptions = { tempHome: home, testRuntime, now };
  return { home, status, options, testRuntime, activityPath: join(home, 'runtime', 'connection-activity', agent + '.json') };
}
async function codexServer(home: string, state: 'trusted' | 'untrusted' | 'modified' | 'wrong-command',
  options: { hashSuffix?: string; gate?: { ready: string; release: string } } = {}) {
  const commands = adapterFor('codex').events.map(event => windowsHookCommand('C:\\XIsland-Test-Resources\\node.exe', 'C:\\XIsland-Test-Resources\\xisland-hook.cjs', 'codex', event));
  const hooks = commands.map(command => ({ command: state === 'wrong-command' ? command + ' wrong' : command,
    enabled: true, handlerType: 'command', isManaged: false, trustStatus: state, currentHash: 'hash-' + command.length + (options.hashSuffix ?? '') }));
  const script = join(home, 'codex-probe.mjs');
  await writeFile(script, `import{createInterface}from'node:readline';import{existsSync,writeFileSync}from'node:fs';
import{setTimeout as delay}from'node:timers/promises';createInterface({input:process.stdin}).on('line',async line=>{
const p=JSON.parse(line);if(p.method==='initialize')process.stdout.write(JSON.stringify({id:1,result:{}})+'\\n');
if(p.method==='hooks/list'){const gate=${JSON.stringify(options.gate ?? null)};
if(gate){writeFileSync(gate.ready,'ready');while(!existsSync(gate.release))await delay(10);}
process.stdout.write(JSON.stringify({id:2,result:{data:[{cwd:process.cwd(),hooks:${JSON.stringify(hooks)},errors:[],warnings:[]}]}})+'\\n');}});`);
  return script;
}

async function codexFixture(t: TestContext) {
  const result = await fixture(t, 'codex');
  const executablePath = join(result.home, 'codex.exe'); await writeFile(executablePath, 'MZ fixture');
  result.options.testRuntime = { ...result.testRuntime, client: { state: 'detected', executablePath, detail: 'fixture' },
    codexProbeScript: await codexServer(result.home, 'trusted') };
  const receipt = { ...(await connectionIdentity(result.status, result.options))!, event: 'SessionStart' };
  return { ...result, receipt };
}

async function waitForFile(path: string): Promise<void> {
  const deadline = Date.now() + 3000;
  for (;;) {
    try { await readFile(path); return; } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
    if (Date.now() > deadline) throw new Error('fixture probe did not reach the gate');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}

test('Connection identity binds actual config bytes and all runtime resources', async t => {
  const { status, options, testRuntime, home } = await fixture(t);
  const before = await readdir(home), identity = await connectionIdentity(status, options);
  assert.ok(identity); assert.equal(identity.configurationRevision, status.revision); assert.match(identity.runtimeFingerprint, /^[a-f0-9]{64}$/);
  assert.deepEqual(await readdir(home), before);
  for (const path of Object.values(testRuntime)) {
    const original = await readFile(path); await writeFile(path, Buffer.from(original).fill(65));
    assert.notEqual((await connectionIdentity(status, options))!.runtimeFingerprint, identity.runtimeFingerprint);
    await writeFile(path, original);
  }
  for (const override of [{ installed: false }, { runtimeReady: false }, { revision: 'invalid' }, { revision: '0'.repeat(64) }, { agent: 'foreign' }]) {
    assert.equal(await connectionIdentity({ ...status, ...override }, options), undefined);
  }
  await writeFile(status.configPath!, '{"changed":true}'); assert.equal(await connectionIdentity(status, options), undefined);
});

for (const agent of ['kimi_code', 'opencode'] as const) {
  test(`${agent} activity cannot cross configuration directories with identical installed content`, async t => {
    const { home, options, testRuntime } = await fixture(t, agent);
    const installer = agent === 'kimi_code'
      ? { plan: planKimiCodeIntegration, apply: applyKimiCodeIntegration, status: getKimiCodeStatus, variable: 'KIMI_CODE_HOME', event: 'SessionStart' }
      : { plan: planOpenCodeIntegration, apply: applyOpenCodeIntegration, status: getOpenCodeStatus, variable: 'XDG_CONFIG_HOME', event: 'session.created' };
    const originalOptions = { tempHome: home, nodeExecutable: testRuntime.nodeExecutable };
    const alternateOptions = { ...originalOptions, environment: { [installer.variable]: join(home, 'alternate-config') } };
    for (const configuration of [originalOptions, alternateOptions]) {
      const plan = await installer.plan('install', configuration);
      await installer.apply('install', plan.revision, configuration);
    }
    const original = await installer.status(originalOptions), alternate = await installer.status(alternateOptions);
    assert.ok(original.installed && alternate.installed);
    assert.notEqual(original.configPath, alternate.configPath);
    assert.equal(original.revision, alternate.revision);
    const originalIdentity = await connectionIdentity(original, options), alternateIdentity = await connectionIdentity(alternate, options);
    assert.ok(originalIdentity && alternateIdentity);
    await recordIntegrationActivity(originalIdentity, installer.event, options);
    assert.equal((await decorateIntegrationStatus(original, options)).activity?.event, installer.event);
    assert.equal((await decorateIntegrationStatus(alternate, options)).activity, undefined);
    await recordIntegrationActivity(alternateIdentity, installer.event, options);
    assert.equal((await decorateIntegrationStatus(alternate, options)).activity?.event, installer.event);
    assert.equal((await decorateIntegrationStatus(original, options)).activity, undefined);
  });
}

test('Only bounded metadata is recorded and activity matches the current configuration and runtime', async t => {
  const { status, options, activityPath, testRuntime } = await fixture(t);
  const identity = (await connectionIdentity(status, options))!;
  assert.equal((await decorateIntegrationStatus(status, options)).activity, undefined);
  await recordIntegrationActivity({ ...identity, payload: 'must-not-be-saved' } as ConnectionIdentity, 'SessionStart', options);
  const record = JSON.parse(await readFile(activityPath, 'utf8'));
  assert.deepEqual(Object.keys(record).sort(), ['agent', 'configurationRevision', 'event', 'receivedAt', 'runtimeFingerprint', 'version']);
  assert.ok(!JSON.stringify(record).includes('must-not-be-saved'));
  assert.deepEqual((await decorateIntegrationStatus(status, options)).activity, { event: 'SessionStart', receivedAt: now });
  await writeFile(testRuntime.hookScript, 'updated program'); assert.equal((await decorateIntegrationStatus(status, options)).activity, undefined);
  const latest = (await connectionIdentity(status, options))!; await recordIntegrationActivity(latest, 'Stop', options);
  await writeFile(status.configPath!, '{"newConfig":true}');
  assert.equal((await decorateIntegrationStatus({ ...status, revision: revision('{"newConfig":true}') }, options)).activity, undefined);
});

test('Activity records with foreign identity, unknown events, future time, bad UTF-8 or extra size are hidden', async t => {
  const { status, options, activityPath } = await fixture(t);
  const identity = (await connectionIdentity(status, options))!; await recordIntegrationActivity(identity, 'Stop', options);
  const good = JSON.parse(await readFile(activityPath, 'utf8'));
  for (const changed of [{ agent: 'codex' }, { event: 'inventedEvent' }, { receivedAt: now + 1 }, { receivedAt: -1 }, { receivedAt: 1.5 },
    { configurationRevision: '0'.repeat(64) }, { runtimeFingerprint: '0'.repeat(64) }, { version: 2 }]) {
    await writeFile(activityPath, JSON.stringify({ ...good, ...changed }));
    assert.equal((await decorateIntegrationStatus(status, options)).activity, undefined);
  }
  for (const bytes of [Buffer.from([255]), Buffer.alloc(4097, 65)]) {
    await writeFile(activityPath, bytes); assert.equal((await decorateIntegrationStatus(status, options)).activity, undefined);
  }
  await assert.rejects(recordIntegrationActivity(identity, 'inventedEvent', options));
  await assert.rejects(recordIntegrationActivity({ ...identity, agent: '../outside' }, 'Stop', options));
});

test('Codex activity is visible only after exact currently trusted hook commands are confirmed', async t => {
  const { home, status, options, testRuntime } = await fixture(t, 'codex');
  const executablePath = join(home, 'codex.exe'); await writeFile(executablePath, 'MZ fixture');
  options.testRuntime = { ...testRuntime, client: { state: 'detected', executablePath, detail: 'isolated fixture' }, codexProbeScript: await codexServer(home, 'trusted') };
  const identity = (await connectionIdentity(status, options))!;
  assert.equal(await recordAcceptedIntegrationActivity(status, { ...identity, event: 'SessionStart' }, options), true);
  let decorated = await decorateIntegrationStatus(status, options); assert.equal(decorated.trust!.state, 'granted'); assert.ok(decorated.activity);
  for (const state of ['untrusted', 'modified', 'wrong-command'] as const) {
    await codexServer(home, state); decorated = await decorateIntegrationStatus(status, options);
    assert.notEqual(decorated.trust!.state, 'granted'); assert.equal(decorated.activity, undefined);
  }
  options.testRuntime.client = { state: 'unconfirmed', detail: 'not verified' };
  decorated = await decorateIntegrationStatus(status, options); assert.equal(decorated.trust!.state, 'unavailable'); assert.equal(decorated.activity, undefined);
});

test('Codex missing exe, cmd shim or unavailable probe cannot retain preexisting activity fields', async t => {
  const { home, status, options, testRuntime } = await fixture(t, 'codex');
  const previous = { ...status, activity: { event: 'Stop', receivedAt: now }, trust: { state: 'granted' } };
  for (const executablePath of [join(home, 'missing.exe'), join(home, 'codex.cmd')]) {
    options.testRuntime = { ...testRuntime, client: { state: 'detected', executablePath, detail: 'fixture' } };
    const result = await decorateIntegrationStatus(previous, options); assert.equal(result.activity, undefined); assert.equal(result.trust!.state, 'unavailable');
  }
});

test('Codex revoked authorization cannot revive an old receipt after the same hooks are trusted again', async t => {
  const { home, status, options, testRuntime } = await fixture(t, 'codex');
  const executablePath = join(home, 'codex.exe'); await writeFile(executablePath, 'MZ fixture');
  options.testRuntime = { ...testRuntime, client: { state: 'detected', executablePath, detail: 'fixture' }, codexProbeScript: await codexServer(home, 'trusted') };
  assert.equal(await recordAcceptedIntegrationActivity(status, { ...(await connectionIdentity(status, options))!, event: 'SessionStart' }, options), true);
  assert.ok((await decorateIntegrationStatus(status, options)).activity);
  await codexServer(home, 'untrusted'); assert.equal((await decorateIntegrationStatus(status, options)).trust?.state, 'required');
  await codexServer(home, 'trusted');
  assert.equal((await decorateIntegrationStatus(status, options)).activity, undefined);
  const receipt = { ...(await connectionIdentity(status, options))!, event: 'UserPromptSubmit' };
  assert.equal(await recordAcceptedIntegrationActivity(status, receipt, options), true);
  assert.equal((await decorateIntegrationStatus(status, options)).activity?.event, 'UserPromptSubmit');
});

test('Accepted receipts must still match the actual configuration and runtime before recording', async t => {
  const { status, options, activityPath, testRuntime } = await fixture(t);
  const receipt = { ...(await connectionIdentity(status, options))!, event: 'SessionStart' };
  await writeFile(testRuntime.hookScript, 'updated after delivery');
  assert.equal(await recordAcceptedIntegrationActivity(status, receipt, options), false);
  await assert.rejects(readFile(activityPath), { code: 'ENOENT' });
  await assert.rejects(recordAcceptedIntegrationActivity(status, { ...receipt, agent: 'foreign' }, options));
  await assert.rejects(recordAcceptedIntegrationActivity(status, { ...receipt, event: 'invented' }, options));
  const fresh = { ...(await connectionIdentity(status, options))!, event: 'SessionStart' };
  assert.equal(await recordAcceptedIntegrationActivity(status, fresh, options), true);
  assert.ok((await decorateIntegrationStatus(status, options)).activity);
});

test('Codex activity is bound to native hook hashes and unbound legacy receipts cannot connect', async t => {
  const { home, status, options, receipt, activityPath } = await codexFixture(t);
  await mkdir(join(home, 'runtime', 'connection-activity'), { recursive: true });
  await writeFile(activityPath, JSON.stringify({ version: 1, ...receipt, receivedAt: now }));
  assert.equal((await decorateIntegrationStatus(status, options)).activity, undefined);
  await assert.rejects(recordIntegrationActivity(receipt, receipt.event, options), /requires_authorization/);
  assert.equal(await recordAcceptedIntegrationActivity(status, receipt, options), true);
  await codexServer(home, 'trusted', { hashSuffix: '-updated' });
  assert.equal((await decorateIntegrationStatus(status, options)).activity, undefined);
  assert.equal(await recordAcceptedIntegrationActivity(status, receipt, options), true);
  assert.ok((await decorateIntegrationStatus(status, options)).activity);
});

for (const target of ['configuration', 'runtime'] as const) {
  test(`Codex probe cannot report connection after ${target} changes during the query`, async t => {
    const { home, status, options, receipt, testRuntime } = await codexFixture(t);
    assert.equal(await recordAcceptedIntegrationActivity(status, receipt, options), true);
    const gate = { ready: join(home, 'probe-ready'), release: join(home, 'probe-release') };
    await codexServer(home, 'trusted', { gate });
    const pending = decorateIntegrationStatus(status, options);
    await waitForFile(gate.ready);
    await writeFile(target === 'configuration' ? status.configPath! : testRuntime.hookScript, 'changed while querying');
    await writeFile(gate.release, 'continue');
    const result = await pending;
    assert.equal(result.trust?.state, 'unavailable'); assert.equal(result.activity, undefined);
  });
}

test('A valid short task received during a Codex status query is retained', async t => {
  const { home, status, options, receipt } = await codexFixture(t);
  const gate = { ready: join(home, 'probe-ready'), release: join(home, 'probe-release') };
  await codexServer(home, 'trusted', { gate });
  const pending = decorateIntegrationStatus(status, options);
  await waitForFile(gate.ready);
  await codexServer(home, 'trusted');
  assert.equal(await recordAcceptedIntegrationActivity(status, receipt, options), true);
  await writeFile(gate.release, 'continue');
  assert.equal((await pending).activity?.event, 'SessionStart');
});

test('Codex accepted activity rechecks runtime after the authorization probe', async t => {
  const { home, status, options, receipt, testRuntime, activityPath } = await codexFixture(t);
  const gate = { ready: join(home, 'record-ready'), release: join(home, 'record-release') };
  await codexServer(home, 'trusted', { gate });
  const pending = recordAcceptedIntegrationActivity(status, receipt, options);
  await waitForFile(gate.ready);
  await writeFile(testRuntime.bridgeExecutable, 'updated after acceptance');
  await writeFile(gate.release, 'continue');
  assert.equal(await pending, false);
  await assert.rejects(readFile(activityPath), { code: 'ENOENT' });
});

test('An in-flight trusted activity cannot overwrite a later revocation tombstone', async t => {
  const { home, status, options, receipt } = await codexFixture(t);
  const gate = { ready: join(home, 'record-ready'), release: join(home, 'record-release') };
  await codexServer(home, 'trusted', { gate });
  const pending = recordAcceptedIntegrationActivity(status, receipt, options);
  await waitForFile(gate.ready);
  await codexServer(home, 'untrusted');
  assert.equal((await decorateIntegrationStatus(status, options)).trust?.state, 'required');
  await writeFile(gate.release, 'continue');
  assert.equal(await pending, false);
  await codexServer(home, 'trusted');
  assert.equal((await decorateIntegrationStatus(status, options)).activity, undefined);
});

test('Health test paths cannot escape the isolated home or follow runtime and config symlinks', async t => {
  const first = await fixture(t), second = await fixture(t);
  await assert.rejects(connectionIdentity(first.status, { ...first.options, tempHome: homedir() }));
  await assert.rejects(connectionIdentity(first.status, { ...first.options, testRuntime: { ...first.testRuntime, hookScript: second.testRuntime.hookScript } }));
  const link = join(first.home, 'outside.cjs'); await symlink(second.testRuntime.hookScript, link);
  await assert.rejects(connectionIdentity(first.status, { ...first.options, testRuntime: { ...first.testRuntime, hookScript: link } }));
  const configLink = join(first.home, 'linked.json'); await symlink(second.status.configPath!, configLink);
  assert.equal(await connectionIdentity({ ...first.status, configPath: configLink }, first.options), undefined);
  const identity = (await connectionIdentity(first.status, first.options))!;
  await symlink(second.home, join(first.home, 'runtime'), 'dir');
  await assert.rejects(recordIntegrationActivity(identity, 'Stop', first.options));
  assert.equal((await decorateIntegrationStatus(first.status, first.options)).activity, undefined);
});

test('Non-Windows production paths remain untouched and test overrides require a temp home', async () => {
  const status = { agent: 'qwen', installed: true, runtimeReady: true, revision: '0'.repeat(64), configPath: '/do-not-read' };
  if (process.platform !== 'win32') {
    assert.equal(await connectionIdentity(status), undefined);
    const decorated = await decorateIntegrationStatus(status); assert.equal(decorated.client.state, 'unconfirmed'); assert.equal(decorated.activity, undefined);
  }
  await assert.rejects(connectionIdentity(status, { now }));
});
