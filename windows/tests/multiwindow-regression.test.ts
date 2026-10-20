import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { Script } from 'node:vm';
import { ModuleKind, ScriptTarget, transpileModule } from 'typescript';
import * as core from '../src/core/index';
import * as audio from '../src/ui/audio';
import { DEFAULT_SETTINGS } from '../src/ui/settings';
import type { IslandSettings } from '../src/ui/platform';
import { AcceptedActivityQueue, acceptedIntegrationActivity } from '../src/platform/setup-owner';

const timestamp = '2026-10-14T00:00:00Z';
const message = (type: core.DIMessage['type'], sessionId: string, extra: Partial<core.DIMessage> = {}): core.DIMessage =>
  ({ type, sessionId, agentType: 'codex', timestamp, ...extra });

test('an open preferences mirror follows a rebuilt owner and rejects late retired-owner snapshots', () => {
  const previousOwner = new core.SessionStore();
  previousOwner.apply(message('session_start', 's', { prompt: 'old owner' }));
  for (let index = 0; index < 20; index++) previousOwner.apply(message('status_update', 's', { status: String(index) }));
  const preferences = new core.SessionStore({ readOnly: true });
  assert.equal(preferences.receiveSnapshot(previousOwner.snapshot()), true);
  const newOwner = new core.SessionStore();
  newOwner.apply(message('session_start', 's', { prompt: 'new owner' }));
  assert.equal(preferences.receiveSnapshot(newOwner.snapshot()), true);
  assert.equal(preferences.snapshot().sessions[0]!.prompt, 'new owner');
  assert.equal(preferences.receiveSnapshot(previousOwner.snapshot()), false);
  assert.equal(preferences.snapshot().sessions[0]!.prompt, 'new owner');
});

function completedHistory(...ids: string[]): string {
  const store = new core.SessionStore();
  for (const id of ids) { store.apply(message('session_start', id, { prompt: id })); store.apply(message('session_end', id, { observedState: 'completed' })); }
  return store.serialize();
}

type Envelope = { message: core.DIMessage; requestId?: string; expiresAt?: number };
type EventHandler = (event: { payload: unknown }) => void;
type Ack = { requestId: string; error: string | null };

/** 执行实际 main.ts；仅替换 IPC、UI 和计时器，不复制其保存/启动编排逻辑。 */
async function bootOwner(options: {
  history?: string;
  save: (content: string) => Promise<unknown>;
  initial?: Envelope[];
  initialEnded?: string[];
  duringReady?: (emit: (name: string, payload: unknown) => void) => void;
  readLocalSettings?: (key: string) => string | null;
  preferences?: IslandSettings;
}) {
  const handlers = new Map<string, EventHandler>();
  const timers = new Map<number, () => void>();
  const errors: string[] = [], acks: Ack[] = [], snapshots: core.StoreSnapshot[] = [];
  const saves: string[] = [];
  const calls: string[] = [], appliedSettings: IslandSettings[] = [];
  let store: core.SessionStore | undefined, timerId = 0, ready = false;
  const emit = (name: string, payload: unknown) => { const handler = handlers.get(name); assert.ok(handler, `listener ${name} must exist`); handler({ payload }); };
  const invoke = async (command: string, args: Record<string, unknown> = {}): Promise<unknown> => {
    calls.push(command);
    if (command === 'read_preferences') return options.preferences ?? null;
    if (command === 'platform_info') return { os: 'windows', capabilities: { monitorFollowing: true, fullscreenHiding: true, horizontalDragging: true } };
    if (command === 'load_history') return options.history ?? null;
    if (command === 'publish_snapshot') { snapshots.push(args.snapshot as core.StoreSnapshot); return; }
    if (command === 'save_history') { saves.push(args.content as string); return options.save(args.content as string); }
    if (command === 'finish_history_action') { acks.push(args as Ack); return; }
    if (command === 'frontend_ready') {
      options.duringReady?.(emit); ready = true;
      return { ownerToken: 'test-owner-token', events: options.initial ?? [], endedRequestIds: options.initialEnded ?? [] };
    }
    if (['protect_interaction', 'cancel_request', 'resize_island', 'configure_window'].includes(command)) return;
    throw new Error(`Unexpected IPC in main.ts regression harness: ${command}`);
  };
  const ui = { showError: (error: unknown) => errors.push(String(error)), applySettings: (settings: IslandSettings) => appliedSettings.push(settings), showSettings() {}, expand() {},
    setCapabilities() {}, applyCapabilities() {} };
  const settingsModule = {};
  const settingsCode = transpileModule(readFileSync(new URL('../src/ui/settings.ts', import.meta.url), 'utf8'), {
    compilerOptions: { module: ModuleKind.CommonJS, target: ScriptTarget.ES2022 },
  }).outputText;
  new Script(settingsCode, { filename: 'settings.ts (storage regression harness)' }).runInNewContext({
    exports: settingsModule,
    require: (name: string) => { assert.equal(name, './audio'); return audio; },
    localStorage: { getItem: options.readLocalSettings ?? (() => null) },
  });
  const compiled = transpileModule(readFileSync(new URL('../src/main.ts', import.meta.url), 'utf8'), {
    compilerOptions: { module: ModuleKind.CommonJS, target: ScriptTarget.ES2022 },
  }).outputText;
  new Script(compiled, { filename: 'main.ts (IPC regression harness)' }).runInNewContext({
    require: (name: string) => {
      if (name === '@tauri-apps/api/core') return { isTauri: () => true, invoke };
      if (name === '@tauri-apps/api/event') return { listen: async (name: string, handler: EventHandler) => { handlers.set(name, handler); return () => handlers.delete(name); } };
      if (name === './core') return core;
      if (name === './ui') return { mountIsland: (_root: unknown, owner: core.SessionStore) => { store = owner; return ui; } };
      if (name === './ui/settings') return settingsModule;
      if (name === './fixtures') return { fixtures: {} };
      if (name === './platform/native-drag') return { installNativeDrag: () => () => {} };
      if (name === './platform/setup-owner') return { startIntegrationSetup: async () => ({ dispose() {}, activityReceived() {} }),
        AcceptedActivityQueue, acceptedIntegrationActivity };
      if (name === './platform/native.css') return {};
      throw new Error(`Unexpected import ${name}`);
    },
    exports: {}, URLSearchParams, location: { search: '' },
    document: { querySelector: () => ({}), documentElement: { classList: { add() {} } } },
    window: { addEventListener() {} },
    setTimeout: (callback: () => void) => { timers.set(++timerId, callback); return timerId; },
    clearTimeout: (id: number) => { timers.delete(id); }, setInterval: () => 0,
  });
  const flush = async () => { for (let count = 0; count < 50; count++) await Promise.resolve(); };
  await flush(); assert.ok(ready, `owner failed to initialize: ${errors.join('; ')}`); assert.ok(store);
  return { store, emit, flush, errors, acks, snapshots, saves, calls, appliedSettings,
    fireTimers() { const pending = [...timers.values()]; timers.clear(); for (const callback of pending) callback(); },
    deleteSession(requestId: string, sessionId: string) { emit('history-action', { requestId, action: { kind: 'dismiss', sessionId } }); },
  };
}

for (const [name, readLocalSettings, error] of [
  ['malformed local settings', () => '{broken', /JSON|SyntaxError/],
  ['unavailable local storage', () => { throw new Error('storage access denied'); }, /storage access denied/],
] as const) {
  test(`${name} does not prevent native preferences or owner event startup`, async () => {
    const preferences: IslandSettings = { ...DEFAULT_SETTINGS, theme: 'light' };
    const owner = await bootOwner({ save: async () => {}, readLocalSettings, preferences });

    assert.equal(owner.errors.length, 1);
    assert.match(owner.errors[0]!, error);
    const preferencesRead = owner.calls.indexOf('read_preferences');
    assert.ok(preferencesRead >= 0);
    assert.ok(preferencesRead < owner.calls.indexOf('frontend_ready'));
    assert.equal(owner.appliedSettings.at(-1), preferences);
    owner.emit('di-message', { message: message('session_start', 'after-settings-error', { prompt: 'startup recovered' }) });
    assert.equal(owner.store.snapshot().sessions[0]?.prompt, 'startup recovered');
    const changed: IslandSettings = { ...preferences, soundEnabled: false };
    owner.emit('preferences-changed', changed);
    assert.equal(owner.appliedSettings.at(-1), changed);
  });
}

test('failed history deletion does not remove the owner or mirrored record before durable acknowledgment', async () => {
  const owner = await bootOwner({ history: completedHistory('keep-on-failure'), save: async () => { throw new Error('disk full'); } });
  owner.deleteSession('delete-fails', 'keep-on-failure'); await owner.flush();
  assert.equal(owner.acks.length, 1); assert.match(owner.acks[0]!.error ?? '', /disk full/);
  assert.equal(owner.store.snapshot().sessions.some(session => session.id === 'keep-on-failure'), true);
  assert.equal(owner.snapshots.at(-1)!.sessions.some(session => session.id === 'keep-on-failure'), true);
});

test('oversized historical file reports capacity failure and is never overwritten by startup or new events', async () => {
  const data = JSON.parse(completedHistory('original'));
  data.sessions[0].recapText = 'x'.repeat(16 * 1024 * 1024);
  const original = JSON.stringify(data);
  const owner = await bootOwner({ history: original, save: async () => {} });
  assert.ok(owner.errors.some(error => /历史载入失败，原文件已保留/.test(error) && /16 MiB/.test(error)));
  owner.emit('di-message', { message: message('session_start', 'new-live', { prompt: 'still usable' }) });
  owner.fireTimers(); await owner.flush();
  assert.equal(owner.saves.length, 0);
  assert.equal(owner.store.snapshot().sessions[0]!.prompt, 'still usable');
});

test('history deletion serializes writes and acknowledges only the matching durable result', async () => {
  const complete: Array<() => void> = [];
  const owner = await bootOwner({ history: completedHistory('first', 'second'), save: () => new Promise<void>(resolve => complete.push(resolve)) });
  owner.deleteSession('one', 'first'); owner.deleteSession('two', 'second'); await owner.flush();
  assert.equal(owner.saves.length, 1); assert.equal(owner.acks.length, 0);
  assert.deepEqual(JSON.parse(owner.saves[0]!).sessions.map((session: { id: string }) => session.id), ['second']);
  complete.shift()!(); await owner.flush();
  assert.equal(owner.saves.length, 2); assert.equal(owner.acks[0]?.requestId, 'one');
  assert.deepEqual(JSON.parse(owner.saves[1]!).sessions, []);
  complete.shift()!(); await owner.flush();
  assert.deepEqual(owner.acks.map(ack => [ack.requestId, ack.error]), [['one', null], ['two', null]]);
});

test('initial ended channels cannot invalidate a new live replacement buffered during frontend_ready', async () => {
  const expiresAt = Date.now() + 60_000;
  const old: Envelope = { message: message('permission_request', 's', { tool: 'Read' }), requestId: 'old', expiresAt };
  const current: Envelope = { message: message('permission_request', 's', { tool: 'Write' }), requestId: 'current', expiresAt };
  const owner = await bootOwner({ save: async () => {}, initial: [old], initialEnded: ['old'], duringReady: emit => emit('di-message', current) });
  const request = owner.store.snapshot().sessions[0]!.pendingInteractions[0]!;
  assert.equal(request.transportRequestId, 'current'); assert.equal(request.phase, 'pending'); assert.equal(request.tool, 'Write');
});

test('business updates received during a durable delete survive transaction completion', async () => {
  let complete: (() => void) | undefined;
  const owner = await bootOwner({ history: completedHistory('remove'), save: () => new Promise<void>(resolve => { complete = resolve; }) });
  owner.deleteSession('delete', 'remove'); await owner.flush();
  owner.emit('di-message', { message: message('session_start', 'new-live', { prompt: 'arrived while disk write pending' }) });
  complete!(); await owner.flush();
  assert.equal(owner.acks[0]?.error, null);
  assert.equal(owner.store.snapshot().sessions.some(session => session.id === 'new-live' && session.status === 'active'), true);
  assert.equal(owner.store.snapshot().sessions.some(session => session.id === 'remove'), false);
});

test('UI approval while delete is awaiting disk cannot queue a snapshot that resurrects the deleted record', async () => {
  const complete: Array<() => void> = [];
  const owner = await bootOwner({ history: completedHistory('remove'), save: () => new Promise<void>(resolve => complete.push(resolve)),
    initial: [{ message: message('permission_request', 'interactive', { tool: 'Read' }), requestId: 'live-channel', expiresAt: Date.now() + 60_000 }] });
  owner.deleteSession('delete', 'remove'); await owner.flush();
  const request = owner.store.snapshot().sessions.find(session => session.id === 'interactive')!.pendingInteractions[0]!;
  assert.ok(owner.store.prepareResponse('interactive', request.id, { kind: 'permission', approved: true }));
  assert.equal(owner.store.confirmResponse(request.id, true), true);
  // 模拟删除磁盘写超过 debounce；UI提交直接调用store，不经过native-event暂缓队列。
  owner.fireTimers(); await owner.flush();
  complete.shift()!(); await owner.flush();
  for (const serialized of owner.saves.slice(1)) {
    assert.equal(JSON.parse(serialized).sessions.some((session: { id: string }) => session.id === 'remove'), false);
  }
  for (const resolve of complete.splice(0)) resolve();
  await owner.flush();
});
