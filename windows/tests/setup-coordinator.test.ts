import assert from 'node:assert/strict';
import test from 'node:test';
import type { ManagedAgent } from '../src/adapters/registry';
import type { IntegrationPlatform, IntegrationPlanSummary, IntegrationStatus } from '../src/ui/platform';
import { IntegrationSetupCoordinator, type SetupState, type SetupStorage } from '../src/integrations/setup-coordinator';

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((accept, fail) => { resolve = accept; reject = fail; });
  return { promise, resolve, reject };
}
function status(agent: ManagedAgent, overrides: Partial<IntegrationStatus> = {}): IntegrationStatus {
  return { agent, platformSupported: true, runtimeReady: true, installed: false, managedHandlers: 0, warnings: [],
    revision: 'revision-a', configPath: `C:\\Fixture\\${agent}.json`,
    client: { state: 'detected', executablePath: `C:\\Fixture\\${agent}.exe`, detail: 'fixture' }, ...overrides };
}
function fixture(initial?: unknown) {
  const statuses = new Map<ManagedAgent, IntegrationStatus>([['qwen', status('qwen')]]);
  const calls: { action: string; agent: ManagedAgent; revision?: string }[] = [];
  const saves: SetupState[] = [];
  let persisted = initial, notices = 0;
  const storage: SetupStorage = {
    async load() { return structuredClone(persisted); },
    async save(value) { saves.push(structuredClone(value)); persisted = structuredClone(value); },
  };
  const api: IntegrationPlatform = {
    async status(agent) {
      calls.push({ action: 'status', agent });
      return structuredClone(statuses.get(agent) ?? status(agent, { client: { state: 'not_found', detail: 'fixture absent' } }));
    },
    async plan(agent, operation) {
      calls.push({ action: 'plan', agent });
      const current = statuses.get(agent)!;
      return { agent, operation, configPath: current.configPath!, revision: current.revision!, runtimeReady: true, changed: true,
        addedHandlers: 1, removedHandlers: 0, warnings: [], sources: [],
        backup: { required: false, directory: 'C:\\Fixture', filenamePrefix: 'fixture', exclusive: true } };
    },
    async apply(agent, operation, revision) {
      calls.push({ action: 'apply', agent, revision });
      statuses.set(agent, { ...statuses.get(agent)!, installed: true, revision: 'revision-b', managedHandlers: 1 });
      return { ...await api.plan(agent, operation), applied: true };
    },
  };
  const make = () => new IntegrationSetupCoordinator(api, storage, { needsAttention() { notices++; } });
  return { api, storage, statuses, calls, saves, make, notices: () => notices,
    persisted: () => structuredClone(persisted) as SetupState,
    applications: () => calls.filter(call => call.action === 'apply') };
}
const qwen = (coordinator: IntegrationSetupCoordinator) => coordinator.snapshot().rows.find(row => row.agent === 'qwen')!;

test('startup prepares only detected clients and saves an attempt before any plan or apply', async () => {
  const f = fixture();
  const originalPlan = f.api.plan;
  f.api.plan = async (agent, operation) => {
    assert.ok(f.persisted().attempts[agent], 'attempt must already be durable');
    return originalPlan(agent, operation);
  };
  const coordinator = f.make();
  await coordinator.start();
  assert.equal(coordinator.snapshot().rows.length, 13);
  assert.equal(f.applications().length, 1);
  assert.equal(f.applications()[0].revision, 'revision-a');
  assert.equal(qwen(coordinator).phase, 'waitingForActivity');
  assert.equal(f.persisted().attempts.qwen, undefined);
  assert.equal(coordinator.snapshot().needsAttention, true);
  assert.equal(coordinator.snapshot().attentionCount, 0);
  assert.equal(f.notices(), 1);
  await coordinator.start();
  assert.equal(f.applications().length, 1);
});

test('configuration existence, unknown discovery, missing runtime, foreign plugins and unknown configuration cannot trigger writes', async () => {
  for (const overrides of [
    { installed: true, client: { state: 'not_found', detail: 'absent' } },
    { client: undefined }, { client: { state: 'unconfirmed', detail: 'ambiguous' } },
    { runtimeReady: false }, { platformSupported: false }, { foreignPlugin: true },
    { installed: null }, { configurationKnown: false }, { revision: undefined }, { configPath: undefined },
  ] satisfies Partial<IntegrationStatus>[]) {
    const f = fixture(); f.statuses.set('qwen', status('qwen', overrides));
    const coordinator = f.make(); await coordinator.start();
    assert.equal(f.calls.filter(call => call.action === 'plan').length, 0);
    assert.equal(f.applications().length, 0);
    assert.notEqual(qwen(coordinator).phase, 'connected');
    if (overrides.client?.state === 'not_found') assert.equal(qwen(coordinator).phase, 'notInstalled');
  }
});

test('a current owner-accepted event can confirm a manually configured client outside discovery paths', async () => {
  for (const state of ['not_found', 'unconfirmed'] as const) {
    const f = fixture();
    f.statuses.set('pi', status('pi', { installed: true, client: { state, detail: 'custom installation' } }));
    const coordinator = f.make(); await coordinator.refresh(false);
    f.statuses.get('pi')!.activity = { event: 'session_start', receivedAt: Date.now() };
    await coordinator.refresh(true);
    assert.equal(coordinator.snapshot().rows.find(row => row.agent === 'pi')!.phase, 'connected');
    assert.equal(f.applications().some(call => call.agent === 'pi'), false);
  }
});

test('old or invalid receipts do not replace missing client evidence', async () => {
  for (const receivedAt of [Date.now() - 60_000, Date.now() + 60_000, Number.NaN, 0]) {
    const f = fixture();
    f.statuses.set('pi', status('pi', { installed: true, client: { state: 'not_found', detail: 'absent' },
      activity: { event: 'session_start', receivedAt } }));
    const coordinator = f.make(); await coordinator.refresh(false);
    assert.equal(coordinator.snapshot().rows.find(row => row.agent === 'pi')!.phase, 'notInstalled');
  }
});

test('fresh activity still cannot bypass disabled, configuration, runtime or Codex trust gates', async () => {
  for (const overrides of [{ runtimeReady: false }, { installed: false }, { foreignPlugin: true },
    { platformSupported: false }, { configurationKnown: false }] satisfies Partial<IntegrationStatus>[]) {
    const f = fixture(), coordinator = f.make();
    f.statuses.set('pi', status('pi', { installed: true, client: { state: 'unconfirmed', detail: 'custom' }, ...overrides,
      activity: { event: 'session_start', receivedAt: Date.now() } }));
    await coordinator.refresh(false);
    assert.notEqual(coordinator.snapshot().rows.find(row => row.agent === 'pi')!.phase, 'connected');
  }
  const f = fixture(), coordinator = f.make();
  f.statuses.set('codex', status('codex', { installed: true, client: { state: 'unconfirmed', detail: 'custom' },
    trust: { state: 'required', configuredCount: 1, trustedCount: 0 }, activity: { event: 'SessionStart', receivedAt: Date.now() } }));
  await coordinator.refresh(false);
  assert.equal(coordinator.snapshot().rows.find(row => row.agent === 'codex')!.phase, 'needsAuthorization');
  await coordinator.setEnabled('codex', false);
  assert.equal(coordinator.snapshot().rows.find(row => row.agent === 'codex')!.phase, 'disabled');
});

test('plan revision and selected configuration must match the read status before apply', async () => {
  for (const change of [{ revision: 'changed' }, { configPath: 'C:\\Other\\hooks.json' }, { runtimeReady: false }]) {
    const f = fixture(), plan = f.api.plan;
    f.api.plan = async (agent, operation) => ({ ...await plan(agent, operation), ...change });
    const coordinator = f.make(); await coordinator.start();
    assert.equal(f.applications().length, 0);
    assert.equal(qwen(coordinator).phase, 'checkFailed');
    assert.match(qwen(coordinator).error!, /计划/);
    assert.ok(f.persisted().attempts.qwen);
    const plans = f.calls.filter(call => call.action === 'plan').length;
    await coordinator.refresh(true);
    assert.equal(f.calls.filter(call => call.action === 'plan').length, plans);
  }
});

test('failed attempts persist across restarts and changed inputs permit another attempt', async () => {
  const f = fixture();
  f.api.apply = async (agent, _operation, revision) => { f.calls.push({ action: 'apply', agent, revision }); throw new Error('fixture denied'); };
  const first = f.make(); await first.start();
  assert.equal(qwen(first).phase, 'checkFailed');
  assert.equal(qwen(first).error, 'fixture denied');
  first.dispose();
  const second = f.make(); await second.start(); await second.refresh(true);
  assert.equal(f.applications().length, 1);
  assert.equal(qwen(second).error, 'fixture denied');
  f.statuses.set('qwen', { ...f.statuses.get('qwen')!, revision: 'revision-c' });
  await second.refresh(true);
  assert.equal(f.applications().length, 2);
  f.statuses.set('qwen', { ...f.statuses.get('qwen')!, client: { ...f.statuses.get('qwen')!.client!, executablePath: 'C:\\New\\qwen.exe' } });
  await second.refresh(true);
  assert.equal(f.applications().length, 3);
});

test('successful configuration clears attempts so a client rewrite can be repaired again', async () => {
  const f = fixture(), coordinator = f.make(); await coordinator.start();
  f.statuses.set('qwen', status('qwen'));
  await coordinator.refresh(true);
  assert.equal(f.applications().length, 2);
  assert.equal(f.persisted().attempts.qwen, undefined);
});

test('Codex never connects from activity without granted trust', async () => {
  for (const trust of [undefined, { state: 'unavailable', configuredCount: 1, trustedCount: 0 },
    { state: 'required', configuredCount: 1, trustedCount: 0 },
    { state: 'granted', configuredCount: 1, trustedCount: 1, fingerprint: 'trust-a' }] satisfies IntegrationStatus['trust'][]) {
    const f = fixture(); f.statuses.clear();
    f.statuses.set('codex', status('codex', { installed: true, trust, activity: { event: 'SessionStart', receivedAt: 1 } }));
    const coordinator = f.make(); await coordinator.start();
    const row = coordinator.snapshot().rows.find(row => row.agent === 'codex')!;
    assert.equal(row.phase, trust?.state === 'granted' ? 'connected' : trust?.state === 'required' ? 'needsAuthorization' : 'checkFailed');
    assert.equal(f.applications().length, 0);
  }
});

test('waiting introductions are acknowledged durably and changed fingerprints receive a new reminder', async () => {
  const f = fixture(), coordinator = f.make(); await coordinator.start();
  await coordinator.presented();
  assert.equal(coordinator.snapshot().needsAttention, false);
  await coordinator.refresh(); assert.equal(f.notices(), 1);
  coordinator.dispose();
  const second = f.make(); await second.start();
  assert.equal(second.snapshot().needsAttention, false);
  f.statuses.set('qwen', { ...f.statuses.get('qwen')!, revision: 'new-configuration' });
  await second.refresh(); assert.equal(f.notices(), 2);
  assert.equal(second.snapshot().needsAttention, true);
});

test('connected clears an old authorization reminder and does not reintroduce an already connected configuration', async () => {
  const f = fixture(); f.statuses.clear();
  const codex = status('codex', { installed: true, trust: { state: 'required', configuredCount: 1, trustedCount: 0, fingerprint: 'trust-a' } });
  f.statuses.set('codex', codex);
  const coordinator = f.make(); await coordinator.start(); await coordinator.presented();
  f.statuses.set('codex', { ...codex, trust: { ...codex.trust!, state: 'granted', trustedCount: 1 }, activity: { event: 'Stop', receivedAt: 1 } });
  await coordinator.refresh(); assert.equal(f.persisted().reminders.codex, undefined);
  f.statuses.set('codex', { ...f.statuses.get('codex')!, activity: undefined });
  await coordinator.refresh(); assert.equal(coordinator.snapshot().needsAttention, false);
  f.statuses.set('codex', codex); await coordinator.refresh();
  assert.equal(coordinator.snapshot().needsAttention, true);
  assert.equal(f.notices(), 2);
});

test('approval interaction defers notifications but keeps needsAttention until it ends', async () => {
  const f = fixture(), coordinator = f.make(); coordinator.setInteractionPending(true);
  await coordinator.start();
  assert.equal(f.notices(), 0); assert.equal(coordinator.snapshot().needsAttention, true);
  coordinator.setInteractionPending(false);
  assert.equal(f.notices(), 1);
  await coordinator.refresh(); assert.equal(f.notices(), 1);
});

test('presenting during an in-flight check acknowledges its final results', async () => {
  const f = fixture(), check = deferred<IntegrationStatus>(), entered = deferred<void>(), original = f.api.status;
  f.api.status = async agent => {
    if (agent === 'qwen') { entered.resolve(); return check.promise; }
    return original(agent);
  };
  const coordinator = f.make(), pending = coordinator.refresh(); await entered.promise;
  await coordinator.presented();
  check.resolve(status('qwen', { installed: true })); await pending;
  assert.equal(coordinator.snapshot().needsAttention, false); assert.equal(f.notices(), 0);
});

test('concurrent refresh requests merge into one queued pass and preserve automatic preparation intent', async () => {
  const f = fixture(), check = deferred<IntegrationStatus>(), entered = deferred<void>(), original = f.api.status;
  let reads = 0;
  f.api.status = async agent => {
    if (agent === 'qwen' && ++reads === 1) { entered.resolve(); return check.promise; }
    return original(agent);
  };
  const coordinator = f.make(), first = coordinator.refresh(); await entered.promise;
  const second = coordinator.refresh(), third = coordinator.refresh(true), fourth = coordinator.refresh();
  check.resolve(status('qwen')); await Promise.all([first, second, third, fourth]);
  assert.equal(reads, 3, 'two passes plus post-apply confirmation');
  assert.equal(f.applications().length, 1);
});

test('disabling during a plan cancels the stale write and persists the disabled state', async () => {
  const f = fixture(), plan = deferred<IntegrationPlanSummary>(), entered = deferred<void>(), original = f.api.plan;
  f.api.plan = async (agent, operation) => { entered.resolve(); return plan.promise; };
  const coordinator = f.make(), pending = coordinator.start(); await entered.promise;
  const disabling = coordinator.setEnabled('qwen', false);
  await Promise.resolve();
  plan.resolve(await original('qwen', 'install'));
  await Promise.all([pending, disabling]);
  assert.equal(f.applications().length, 0);
  assert.equal(qwen(coordinator).phase, 'disabled'); assert.equal(f.persisted().enabled.qwen, false);
  coordinator.dispose(); const second = f.make(); await second.start();
  assert.equal(qwen(second).phase, 'disabled'); assert.equal(f.applications().length, 0);
});

test('disabling during status read prevents stale preparation and connected state', async () => {
  const f = fixture(), check = deferred<IntegrationStatus>(), entered = deferred<void>(), original = f.api.status;
  let once = true;
  f.api.status = async agent => {
    if (agent === 'qwen' && once) { once = false; entered.resolve(); return check.promise; }
    return original(agent);
  };
  const coordinator = f.make(), pending = coordinator.start(); await entered.promise;
  const disabling = coordinator.setEnabled('qwen', false); await Promise.resolve();
  check.resolve(status('qwen', { installed: true, activity: { event: 'Stop', receivedAt: 1 } }));
  await Promise.all([pending, disabling]);
  assert.equal(qwen(coordinator).phase, 'disabled'); assert.equal(f.applications().length, 0);
});

test('load failures never overwrite unknown saved state or write client configuration', async () => {
  const f = fixture(); f.storage.load = async () => { throw new Error('disk unavailable'); };
  const coordinator = f.make(); await coordinator.start();
  assert.match(coordinator.snapshot().error!, /disk unavailable/); assert.equal(f.applications().length, 0);
  await assert.rejects(coordinator.presented(), /disk unavailable/);
  await assert.rejects(coordinator.setEnabled('qwen', false), /disk unavailable/);
  assert.equal(f.saves.length, 0); assert.equal(qwen(coordinator).enabled, true);
});

test('attempt persistence failure stops automatic configuration and remains visible', async () => {
  const f = fixture(); f.storage.save = async () => { throw new Error('disk full'); };
  const coordinator = f.make(); await coordinator.start(); await coordinator.refresh(true);
  assert.equal(f.calls.filter(call => call.action === 'plan').length, 0);
  assert.equal(f.applications().length, 0); assert.match(coordinator.snapshot().error!, /disk full/);
});

test('failed preference save restores the actually saved switch and rejects the caller', async () => {
  const f = fixture(); f.statuses.set('qwen', status('qwen', { installed: true }));
  const coordinator = f.make(); await coordinator.start();
  f.storage.save = async () => { throw new Error('permission denied'); };
  await assert.rejects(coordinator.setEnabled('qwen', false), /permission denied/);
  assert.equal(qwen(coordinator).enabled, true);
  assert.match(coordinator.snapshot().error!, /permission denied/);
});

test('invalid persisted state blocks automatic writes and snapshots do not expose mutable internals', async () => {
  const f = fixture({ version: 1, enabled: { qwen: 'yes' } }), coordinator = f.make(); await coordinator.start();
  assert.match(coordinator.snapshot().error!, /无效/); assert.equal(f.applications().length, 0);
  const snapshot = coordinator.snapshot(); snapshot.rows[0].enabled = false;
  qwen(coordinator).status!.warnings.push('external mutation');
  assert.equal(coordinator.snapshot().rows[0].enabled, true);
  assert.ok(!qwen(coordinator).status!.warnings.includes('external mutation'));
});

test('dispose while awaiting a read prevents subsequent writes and notifications', async () => {
  const f = fixture(), check = deferred<IntegrationStatus>(), entered = deferred<void>(), original = f.api.status;
  f.api.status = async agent => { if (agent === 'qwen') { entered.resolve(); return check.promise; } return original(agent); };
  const coordinator = f.make(), pending = coordinator.start(); await entered.promise;
  coordinator.dispose(); check.resolve(status('qwen')); await pending;
  assert.equal(f.applications().length, 0); assert.equal(f.saves.length, 0); assert.equal(f.notices(), 0);
});
