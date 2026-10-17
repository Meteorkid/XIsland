import assert from 'node:assert/strict';
import test from 'node:test';
import { SessionStore, type DIMessage } from '../src/core';
import type { ManagedAgent } from '../src/adapters/registry';
import type { ConnectionActivityReceipt } from '../src/integrations/connection-health';
import type { SetupSnapshot, SetupState } from '../src/integrations/setup-coordinator';
import type { IntegrationPlatform, IntegrationStatus } from '../src/ui/platform';
import type { WorkBuddyExportResult, WorkBuddySetupStatus } from '../src/integrations/workbuddy-plugin';
import { AcceptedActivityQueue, acceptedIntegrationActivity, startIntegrationSetup, type SetupAction } from '../src/platform/setup-owner';

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((accept, fail) => { resolve = accept; reject = fail; });
  return { promise, resolve, reject };
}
async function flush() { for (let count = 0; count < 100; count++) await Promise.resolve(); }
function status(agent: ManagedAgent, detected = false): IntegrationStatus {
  return { agent, installed: true, platformSupported: true, runtimeReady: true, managedHandlers: 1, warnings: [],
    configPath: `C:\\Fixture\\${agent}.json`, revision: 'a'.repeat(64),
    client: { state: detected ? 'detected' : 'not_found', detail: 'isolated fixture' } };
}
function harness() {
  const store = new SessionStore({ ownerInstanceId: 'fixture-owner' });
  const handlers = new Map<string, (event: { payload: unknown }) => void>();
  const timers = new Map<number, { handler(): void; milliseconds: number }>();
  const snapshots: SetupSnapshot[] = [], reports: string[] = [], opened: string[] = [], calls: string[] = [];
  const statuses = new Map<ManagedAgent, IntegrationStatus>();
  const actions = new Map<string, ReturnType<typeof deferred<void>>>();
  let state: SetupState | undefined, timerId = 0, requestId = 0;
  const ports: Parameters<typeof startIntegrationSetup>[3] = {
    async invoke<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
      calls.push(command);
      if (command === 'read_setup_state') return structuredClone(state) as T;
      if (command === 'save_setup_state') { assert.equal(args.ownerToken, 'fixture-token'); state = structuredClone(args.state) as SetupState; return undefined as T; }
      if (command === 'publish_setup_snapshot') { assert.equal(args.ownerToken, 'fixture-token'); snapshots.push(structuredClone(args.snapshot) as SetupSnapshot); return undefined as T; }
      if (command === 'open_preferences') { opened.push(String(args.pane)); return undefined as T; }
      if (command === 'finish_setup_action') {
        assert.equal(args.ownerToken, 'fixture-token');
        const action = actions.get(String(args.requestId)); assert.ok(action);
        if (args.error) action.reject(new Error(String(args.error))); else action.resolve();
        return undefined as T;
      }
      throw new Error(`Unexpected fixture command: ${command}`);
    },
    async listen<T>(event: string, handler: (event: { payload: T }) => void) {
      handlers.set(event, handler as (event: { payload: unknown }) => void);
      return () => { handlers.delete(event); };
    },
    setInterval(handler, milliseconds) { timers.set(++timerId, { handler, milliseconds }); return timerId; },
    clearInterval(handle) { timers.delete(handle as number); },
  };
  const api: IntegrationPlatform = {
    async status(agent) { calls.push(`status:${agent}`); return structuredClone(statuses.get(agent) ?? status(agent)); },
    async plan(agent, operation) {
      calls.push(`plan:${agent}:${operation}`);
      return { agent, operation, configPath: statuses.get(agent)?.configPath ?? status(agent).configPath!, revision: 'a'.repeat(64), runtimeReady: true,
        changed: true, addedHandlers: operation === 'install' ? 1 : 0, removedHandlers: operation === 'uninstall' ? 1 : 0,
        backup: { required: true, directory: 'C:\\Fixture', filenamePrefix: 'backup', exclusive: true }, warnings: [], sources: [] };
    },
    async apply(agent, operation, _revision) {
      calls.push(`apply:${agent}:${operation}`);
      const previous = statuses.get(agent) ?? status(agent);
      statuses.set(agent, { ...previous, installed: operation === 'install', managedHandlers: operation === 'install' ? 1 : 0 });
      return { ...await api.plan(agent, operation), applied: true };
    },
  };
  const emit = (name: string, payload?: unknown) => { const listener = handlers.get(name); assert.ok(listener, `missing ${name}`); listener({ payload }); };
  return { store, ports, api, statuses, snapshots, reports, opened, calls, handlers, timers, emit, state: () => state,
    start: () => startIntegrationSetup(api, store, 'fixture-token', ports, error => reports.push(String(error))),
    action(action: SetupAction) {
      const request = String(++requestId), result = deferred<void>(); actions.set(request, result);
      emit('setup-action', { requestId: request, action }); return result.promise;
    },
    tick(milliseconds: number) { for (const timer of timers.values()) if (timer.milliseconds === milliseconds) timer.handler(); },
  };
}

test('real setup owner does not open preferences before the initial scan or for absent clients', async () => {
  const h = harness(), gate = deferred<IntegrationStatus>(), original = h.api.status;
  h.api.status = agent => agent === 'qwen' ? gate.promise : original(agent);
  const owner = await h.start(); await flush();
  assert.deepEqual(h.opened, [], 'store.subscribe initial empty snapshot must not trigger unknown-state reminders');
  gate.resolve(status('qwen')); await flush();
  assert.deepEqual(h.opened, []); assert.equal(h.snapshots.at(-1)?.needsAttention, false);
  owner.dispose();
});

test('dismissal while the actual owner scans acknowledges the eventual result without reopening', async () => {
  const h = harness(), gate = deferred<IntegrationStatus>(), original = h.api.status;
  h.api.status = agent => agent === 'qwen' ? gate.promise : original(agent);
  const owner = await h.start(); await flush();
  h.emit('setup-dismissed'); await flush();
  const previousOpens = h.opened.length;
  gate.resolve(status('qwen', true)); await flush();
  assert.equal(h.opened.length, previousOpens);
  assert.equal(h.snapshots.at(-1)?.needsAttention, false);
  assert.ok(h.state()?.introductions.qwen);
  owner.dispose();
});

test('pending native approval defers the actual owner reminder until interaction ends', async () => {
  const h = harness(); h.statuses.set('qwen', status('qwen', true));
  const message: DIMessage = { type: 'permission_request', sessionId: 'pending', agentType: 'qwen', tool: 'Read', timestamp: new Date().toISOString() };
  h.store.apply(message, { requestId: 'native-request', expiresAt: Date.now() + 60_000 });
  const owner = await h.start(); await flush();
  assert.equal(h.opened.length, 0); assert.equal(h.snapshots.at(-1)?.needsAttention, true);
  h.store.endTransport('native-request', 'fixture ended'); await flush();
  assert.deepEqual(h.opened, ['agents']);
  owner.dispose();
});

test('settings action persists disable before acknowledgment and periodic checks do not reinstall an explicit removal', async () => {
  const h = harness(); h.statuses.set('qwen', status('qwen', true));
  const owner = await h.start(); await flush();
  await h.action({ kind: 'setEnabled', agent: 'qwen', enabled: false });
  assert.equal(h.state()?.enabled.qwen, false);
  await h.api.apply('qwen', 'uninstall', 'a'.repeat(64));
  h.tick(300_000); await flush();
  assert.equal(h.calls.filter(value => value === 'apply:qwen:install').length, 0);
  assert.equal(h.snapshots.at(-1)?.rows.find(row => row.agent === 'qwen')?.phase, 'disabled');
  owner.dispose();
});

test('settings action receives persistence failure instead of a success acknowledgment', async () => {
  const h = harness(), original = h.ports.invoke;
  const owner = await h.start(); await flush();
  h.ports.invoke = async (command, args) => {
    if (command === 'save_setup_state') throw new Error('fixture disk full');
    return original(command, args);
  };
  await assert.rejects(h.action({ kind: 'setEnabled', agent: 'qwen', enabled: false }), /fixture disk full/);
  await flush();
  assert.equal(h.snapshots.at(-1)?.rows.find(row => row.agent === 'qwen')?.enabled, true);
  owner.dispose();
});

test('concurrent settings refresh actions share the in-flight scan and keep automatic intent', async () => {
  const h = harness(), gate = deferred<IntegrationStatus>(), original = h.api.status;
  let first = true;
  h.statuses.set('qwen', { ...status('qwen', true), installed: false, managedHandlers: 0 });
  h.api.status = agent => { if (agent === 'qwen' && first) { first = false; return gate.promise; } return original(agent); };
  const owner = await h.start(); await flush();
  const left = h.action({ kind: 'refresh', prepareAutomatically: false });
  const right = h.action({ kind: 'refresh', prepareAutomatically: true });
  gate.resolve(h.statuses.get('qwen')!); await Promise.all([left, right]); await flush();
  assert.equal(h.calls.filter(value => value === 'apply:qwen:install').length, 1);
  assert.equal(h.snapshots.at(-1)?.rows.find(row => row.agent === 'qwen')?.phase, 'waitingForActivity');
  owner.dispose();
});

test('owner disposal removes listeners and timers and prevents late scan notification or writes', async () => {
  const h = harness(), gate = deferred<IntegrationStatus>(), original = h.api.status;
  h.api.status = agent => agent === 'qwen' ? gate.promise : original(agent);
  const owner = await h.start(); await flush();
  const priorOpens = h.opened.length, priorSaves = h.calls.filter(value => value === 'save_setup_state').length;
  owner.dispose(); gate.resolve({ ...status('qwen', true), installed: false }); await flush();
  assert.equal(h.handlers.size, 0); assert.equal(h.timers.size, 0);
  assert.equal(h.opened.length, priorOpens); assert.equal(h.calls.filter(value => value === 'save_setup_state').length, priorSaves);
});

const workBuddyStatus = (overrides: Partial<WorkBuddySetupStatus> = {}): WorkBuddySetupStatus => ({
  agent: 'workbuddy', client: { state: 'detected', detail: 'fixture WorkBuddy' }, runtimeReady: true, needsPreparation: true, ...overrides,
});
const workBuddyArtifact = (): WorkBuddyExportResult => ({ agent: 'workbuddy', exportedPath: 'C:\\Fixture\\WorkBuddy',
  eventCount: 11, observationOnly: true, clientVerified: false, runtimeReady: true });

test('WorkBuddy automatic preparation requires detected client, ready runtime and a missing artifact', async () => {
  for (const candidate of [workBuddyStatus(), workBuddyStatus({ client: { state: 'not_found', detail: 'absent' } }),
    workBuddyStatus({ client: { state: 'unconfirmed', detail: 'ambiguous' } }), workBuddyStatus({ runtimeReady: false }),
    workBuddyStatus({ needsPreparation: false })]) {
    const h = harness(); let preparations = 0;
    h.api.workBuddyStatus = async () => candidate;
    h.api.prepareWorkBuddy = async () => { preparations++; return workBuddyArtifact(); };
    const owner = await h.start(); await flush();
    assert.equal(preparations, candidate.client.state === 'detected' && candidate.runtimeReady && candidate.needsPreparation ? 1 : 0);
    assert.ok(h.snapshots.some(snapshot => !snapshot.refreshing), 'managed coordinator must still complete startup');
    h.tick(300_000); await flush();
    assert.ok(preparations <= 1, 'periodic checks must not repeatedly prepare the same artifact');
    owner.dispose();
  }
});

test('WorkBuddy preparation failure is reported once and does not block managed startup or retry every five minutes', async () => {
  const h = harness(); let preparations = 0;
  h.api.workBuddyStatus = async () => workBuddyStatus();
  h.api.prepareWorkBuddy = async () => { preparations++; throw new Error('fixture WorkBuddy write denied'); };
  const owner = await h.start(); await flush();
  assert.equal(preparations, 1);
  assert.equal(h.reports.filter(error => error.includes('fixture WorkBuddy write denied')).length, 1);
  assert.ok(h.snapshots.some(snapshot => !snapshot.refreshing));
  h.tick(300_000); await flush(); h.tick(300_000); await flush();
  assert.equal(preparations, 1);
  assert.equal(h.reports.filter(error => error.includes('fixture WorkBuddy write denied')).length, 1);
  owner.dispose();
});

test('WorkBuddy preparation completes before normal managed startup and is not repeated by later polls', async () => {
  const h = harness(), prepared = deferred<WorkBuddyExportResult>(); let preparations = 0;
  h.api.workBuddyStatus = async () => workBuddyStatus();
  h.api.prepareWorkBuddy = async () => { preparations++; return prepared.promise; };
  const owner = await h.start(); await flush();
  assert.equal(preparations, 1); assert.equal(h.calls.includes('read_setup_state'), false);
  prepared.resolve(workBuddyArtifact()); await flush();
  assert.ok(h.snapshots.some(snapshot => !snapshot.refreshing));
  assert.equal(h.snapshots.at(-1)?.rows.length, 13);
  h.tick(300_000); await flush(); assert.equal(preparations, 1);
  owner.dispose();
});

test('WorkBuddy discovery can become eligible on a later owner poll without an earlier speculative write', async () => {
  const h = harness(); let detected = false, preparations = 0;
  h.api.workBuddyStatus = async () => workBuddyStatus({ client: { state: detected ? 'detected' : 'not_found', detail: 'fixture' } });
  h.api.prepareWorkBuddy = async () => { preparations++; return workBuddyArtifact(); };
  const owner = await h.start(); await flush(); assert.equal(preparations, 0);
  detected = true; h.tick(300_000); await flush(); assert.equal(preparations, 1);
  owner.dispose();
});

const receipt = (event: string, agent = 'qwen'): ConnectionActivityReceipt => ({ agent, event,
  configurationRevision: 'a'.repeat(64), runtimeFingerprint: 'b'.repeat(64) });

test('activity queue immediately records a short task and coalesces later events without delaying the first receipt', async () => {
  const calls: ConnectionActivityReceipt[] = [], gate = deferred<void>(), errors: unknown[] = [];
  const queue = new AcceptedActivityQueue(async value => { calls.push(value); if (calls.length === 1) await gate.promise; }, error => errors.push(error));
  queue.push(receipt('SessionStart')); queue.push(receipt('BeforeTool')); queue.push(receipt('Stop'));
  assert.deepEqual(calls.map(value => value.event), ['SessionStart']);
  gate.resolve(); await flush();
  assert.deepEqual(calls.map(value => value.event), ['SessionStart', 'Stop']); assert.deepEqual(errors, []);
  queue.dispose();
});

test('activity queue isolates agents and drains the latest event even when the earlier confirmation fails', async () => {
  const calls: string[] = [], gate = deferred<void>(), errors: unknown[] = [];
  const queue = new AcceptedActivityQueue(async value => {
    calls.push(`${value.agent}:${value.event}`);
    if (value.agent === 'qwen' && value.event === 'SessionStart') { await gate.promise; throw new Error('fixture failure'); }
  }, error => errors.push(error));
  queue.push(receipt('SessionStart')); queue.push(receipt('Stop')); queue.push(receipt('SessionStart', 'codex'));
  assert.deepEqual(calls, ['qwen:SessionStart', 'codex:SessionStart']);
  gate.resolve(); await flush();
  assert.deepEqual(calls, ['qwen:SessionStart', 'codex:SessionStart', 'qwen:Stop']); assert.equal(errors.length, 1);
  queue.dispose();
});

test('activity queue refreshes the real owner after accepted short-task confirmation, not merely on enqueue', async () => {
  const h = harness(); h.statuses.set('qwen', status('qwen', true));
  const owner = await h.start(); await flush();
  const gate = deferred<void>();
  const queue = new AcceptedActivityQueue(async value => {
    await gate.promise;
    h.statuses.set('qwen', { ...status('qwen', true), activity: { event: value.event, receivedAt: Date.now() } });
    owner.activityReceived();
  }, error => h.reports.push(String(error)));
  queue.push(receipt('Stop'));
  h.tick(2000); await flush();
  assert.equal(h.snapshots.at(-1)?.rows.find(row => row.agent === 'qwen')?.phase, 'waitingForActivity');
  gate.resolve(); await flush(); h.tick(2000); await flush();
  assert.equal(h.snapshots.at(-1)?.rows.find(row => row.agent === 'qwen')?.phase, 'connected');
  const reads = h.calls.filter(value => value === 'status:qwen').length;
  h.tick(2000); await flush(); assert.equal(h.calls.filter(value => value === 'status:qwen').length, reads);
  queue.dispose(); owner.dispose();
});

test('activity queue disposal drops queued receipts while allowing the already started confirmation to settle', async () => {
  const calls: string[] = [], gate = deferred<void>();
  const queue = new AcceptedActivityQueue(async value => { calls.push(value.event); await gate.promise; }, () => {});
  queue.push(receipt('SessionStart')); queue.push(receipt('Stop')); queue.dispose(); queue.push(receipt('SessionEnd'));
  gate.resolve(); await flush(); assert.deepEqual(calls, ['SessionStart']);
});

test('activity eligibility uses actual store mutation and excludes replay and heartbeat observations', () => {
  const store = new SessionStore({ ownerInstanceId: 'fixture-activity' });
  const message: DIMessage = { type: 'session_start', sessionId: 'short-task', agentType: 'qwen', timestamp: new Date().toISOString() };
  const before = store.snapshot().revision, result = store.apply(message), after = store.snapshot().revision;
  assert.equal(acceptedIntegrationActivity(message, result.accepted, before, after), true);
  assert.equal(acceptedIntegrationActivity(message, true, after, after), false);
  assert.equal(acceptedIntegrationActivity({ ...message, nativeMessageReplay: true }, true, before, after), false);
  assert.equal(acceptedIntegrationActivity({ ...message, type: 'observation_heartbeat' }, true, before, after), false);
  assert.equal(acceptedIntegrationActivity({ ...message, observedState: 'completionUnconfirmed' }, true, before, after), false);
});
