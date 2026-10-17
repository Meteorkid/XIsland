import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { normalizeKimiCodeHook } from '../src/adapters/kimi-code';
import { SessionStore } from '../src/core/session-store';
import { kimiTaskEventId } from '../src/core/kimi-tasks';

const fixture = JSON.parse(readFileSync(new URL('../src/fixtures/companion/kimi-code-hooks.json', import.meta.url), 'utf8'));
const time = Date.parse('2026-10-17T00:00:00Z');
const message = (event: string, patch: Record<string, unknown> = {}) => normalizeKimiCodeHook({
  ...fixture.cases.find((row: { event: string }) => row.event === event).input, ...patch,
}, { timestamp: new Date(time).toISOString() });
const sessionId = 'kimi_code-node-fixture';
const makeStore = () => new SessionStore({ now: () => time });
const task = (id: string, kind = 'agent') => message('TaskStarted', { task_id: id, kind });
const result = (id: string, status = 'failed') => message('Notification', { source_id: id, notification_type: `task.${status}` });

test('Kimi production store observes approval without a channel and resolves only exact native tuples', () => {
  const store = makeStore(); store.apply(message('SessionStart')); store.apply(message('TurnStarted'));
  assert.equal(store.apply(message('PermissionRequest')).accepted, true);
  let session = store.snapshot().sessions[0];
  assert.equal(session.status, 'waitingPermission'); assert.deepEqual(session.pendingInteractions, []);
  assert.equal(store.prepareResponse(sessionId, 'approval_fixture', { kind: 'permission', approved: true }), null);
  store.apply(message('PreToolUse')); assert.equal(store.snapshot().sessions[0].status, 'waitingPermission');
  store.apply(message('PermissionResult', { turn_id: 99 })); assert.equal(store.snapshot().sessions[0].status, 'waitingPermission');
  store.apply(message('PermissionResult')); session = store.snapshot().sessions[0];
  assert.equal(session.status, 'active'); assert.deepEqual(session.pendingInteractions, []);
  assert.equal(session.chatHistory.length, 0);
});

test('Kimi result-before-request orphans survive store restart without visible shells', () => {
  const store = makeStore(); store.apply(message('PermissionResult')); store.apply(result('task-late'));
  assert.equal(store.snapshot().sessions.length, 0);
  const restored = makeStore(); restored.restore(store.serialize());
  assert.equal(restored.snapshot().sessions.length, 0);
  restored.apply(message('PermissionRequest')); restored.apply(task('task-late'));
  assert.equal(restored.snapshot().sessions.length, 0);
  restored.apply(message('SessionStart'));
  const session = restored.snapshot().sessions[0];
  assert.equal(session.status, 'idle'); assert.equal(session.events.length, 1);
  assert.equal(session.events[0].isFailed, true); assert.equal(session.events[0].backgroundTaskStatus, 'failed');
});

test('Kimi native agent tasks become flat events and cannot collide with model toolCallId', () => {
  const store = makeStore(); store.apply(task('agent-1')); store.apply(task('agent-2'));
  const fakeId = kimiTaskEventId(sessionId, 'agent-1');
  store.apply(message('PreToolUse', { tool_call_id: fakeId, tool_name: 'Read' }));
  store.apply(result('agent-1')); store.apply(task('agent-1'));
  const session = store.snapshot().sessions[0];
  assert.equal(session.backgroundTasks.length, 2); assert.equal(session.events.length, 3);
  assert.equal(session.events.find(event => event.id === fakeId)?.backgroundTaskStatus, 'failed');
  assert.equal(session.events.find(event => event.toolCallId === fakeId)?.isComplete, false);
  assert.equal(session.events.find(event => event.id === fakeId)?.toolCallId, undefined);
  assert.deepEqual(session.subagentIds, []); assert.equal(session.parentSessionId, undefined);
  store.apply(message('SubagentStart')); store.apply(message('SubagentStop'));
  assert.equal(store.snapshot().sessions.length, 1); assert.deepEqual(store.snapshot().sessions[0].subagentIds, []);
});

test('process and question tasks do not create agent sessions or child trees', () => {
  const store = makeStore(); store.apply(task('process', 'process')); store.apply(task('question', 'question'));
  assert.equal(store.snapshot().sessions.length, 0);
  store.apply(message('SessionStart'));
  assert.equal(store.snapshot().sessions[0].backgroundTasks.length, 2);
  assert.equal(store.snapshot().sessions[0].events.length, 0);
});

test('Kimi submission and queue observations do not start execution or fabricate assistant replies', () => {
  const store = makeStore(); store.apply(message('SessionStart')); store.apply(message('UserPromptSubmit'));
  assert.equal(store.snapshot().sessions[0].status, 'idle');
  assert.deepEqual(store.snapshot().sessions[0].chatHistory.map(row => row.role), ['user']);
  store.apply(message('UserPromptQueued')); store.apply(message('TurnStarted', { origin_kind: 'task' }));
  assert.equal(store.snapshot().sessions[0].status, 'active'); assert.equal(store.snapshot().sessions[0].chatHistory.length, 1);
  store.apply(message('Stop')); assert.equal(store.snapshot().sessions[0].status, 'completionUnconfirmed');
  store.apply(message('PostCompact', { trigger: 'manual' })); assert.equal(store.snapshot().sessions[0].status, 'completionUnconfirmed');
});

test('Kimi heartbeat cannot create activity or change the last activity time', () => {
  let now = time; const store = new SessionStore({ now: () => now });
  store.apply(message('SessionHeartbeat')); assert.equal(store.snapshot().sessions.length, 0);
  assert.deepEqual(JSON.parse(store.serialize()).kimiCodeObservations, []);
  store.apply(message('SessionStart')); const initial = store.snapshot(); now += 1000;
  store.apply(message('SessionHeartbeat')); assert.deepEqual(store.snapshot(), initial);
});

test('Kimi closing leaves running tasks unconfirmed and late results enrich closed history without revival', () => {
  const store = makeStore(); store.apply(task('agent-1')); store.apply(message('SessionEnd'));
  const completedAt = store.snapshot().sessions[0].completedAt;
  assert.equal(store.snapshot().sessions[0].backgroundTasks[0].status, 'unconfirmed');
  store.apply(task('agent-2')); store.apply(result('agent-1')); store.apply(message('UserPromptSubmit'));
  store.apply(message('PermissionRequest')); store.apply(message('PostCompact'));
  const session = store.snapshot().sessions[0];
  assert.equal(session.status, 'completed'); assert.equal(session.completedAt, completedAt);
  assert.equal(session.backgroundTasks.find(task => task.id === 'agent-1')?.status, 'failed');
  assert.equal(session.backgroundTasks.find(task => task.id === 'agent-2')?.status, 'unconfirmed');
  assert.equal(session.chatHistory.length, 0); assert.deepEqual(session.pendingInteractions, []);
  store.apply(message('TurnStarted')); assert.equal(store.snapshot().sessions[0].status, 'active');
  assert.equal(store.snapshot().sessions[0].completedAt, undefined);
});

test('unknown closed session facts survive restart and reject late starts until genuine execution', () => {
  const store = makeStore(); store.apply(message('SessionEnd'));
  const restored = makeStore(); restored.restore(store.serialize());
  restored.apply(task('late')); restored.apply(message('UserPromptSubmit')); restored.apply(message('PermissionRequest'));
  assert.equal(restored.snapshot().sessions.length, 0);
  restored.apply(message('SessionStart')); assert.equal(restored.snapshot().sessions[0].status, 'idle');
  assert.equal(restored.snapshot().sessions[0].backgroundTasks[0].status, 'unconfirmed');
});

test('Kimi restoration marks running tasks unconfirmed and supports old version-one histories', () => {
  const store = makeStore(); store.apply(task('running')); store.apply(message('PermissionRequest'));
  const restored = makeStore(); restored.restore(store.serialize());
  assert.equal(restored.snapshot().sessions[0].status, 'observationUnavailable');
  assert.equal(restored.snapshot().sessions[0].backgroundTasks[0].status, 'unconfirmed');
  restored.apply(message('PermissionResult')); assert.equal(restored.snapshot().sessions[0].status, 'observationUnavailable');
  restored.apply(message('TurnStarted')); assert.equal(restored.snapshot().sessions[0].status, 'active');
  const old = JSON.parse(store.serialize()); delete old.kimiCodeObservations;
  const legacy = makeStore(); legacy.restore(JSON.stringify(old));
  assert.equal(legacy.snapshot().sessions[0].backgroundTasks[0].status, 'unconfirmed');
  legacy.apply(message('TurnStarted'));
  assert.equal(legacy.snapshot().sessions[0].status, 'completionUnconfirmed');
  legacy.apply(message('PermissionResult'));
  assert.equal(legacy.snapshot().sessions[0].status, 'completionUnconfirmed');
  legacy.apply(message('SessionEnd')); assert.equal(legacy.snapshot().sessions[0].status, 'completed');
});

test('Kimi observation restore validates atomically, deduplicates identity, and rejects foreign orphan sources', () => {
  const store = makeStore(); store.apply(message('PermissionResult'));
  assert.equal(store.apply({ ...message('PermissionRequest'), sourceNamespace: 'foreign' }).accepted, false);
  const original = store.serialize(), corrupt = JSON.parse(original);
  corrupt.kimiCodeObservations.push(corrupt.kimiCodeObservations[0]);
  assert.throws(() => store.restore(JSON.stringify(corrupt))); assert.equal(store.serialize(), original);
  corrupt.kimiCodeObservations.pop(); corrupt.kimiCodeObservations[0].state.backgroundTasks = [{ id: 'bad', status: 'unknown' }];
  assert.throws(() => store.restore(JSON.stringify(corrupt))); assert.equal(store.serialize(), original);
});

test('Kimi history removal clears ledgers and cannot recreate deleted rows from passive events', () => {
  for (const remove of ['dismiss', 'clear', 'commit'] as const) {
    const store = makeStore(); store.apply(task('task')); store.apply(message('SessionEnd'));
    if (remove === 'dismiss') store.dismiss(sessionId);
    else if (remove === 'clear') store.clearHistory();
    else {
      const plan = store.prepareHistoryRemoval(sessionId);
      assert.deepEqual(JSON.parse(plan.serialized).kimiCodeObservations, []); store.commitHistoryRemoval(plan);
    }
    assert.deepEqual(JSON.parse(store.serialize()).kimiCodeObservations, []);
    assert.equal(store.apply(result('task')).accepted, false);
    assert.equal(store.apply(message('UserPromptSubmit')).accepted, false);
    assert.equal(store.apply(message('PermissionRequest')).accepted, false);
    assert.equal(store.snapshot().sessions.length, 0);
    assert.equal(store.apply(message('TurnStarted')).accepted, true); assert.equal(store.snapshot().sessions.length, 1);
  }
});

test('reserved observation-only sources cannot acquire generic incoming approval channels', () => {
  for (const agent of ['kimi', 'kimi_code', 'code_buddy', 'droid']) {
    const store = makeStore();
    const request = { type: 'permission_request', sessionId: `${agent}-session`, agentType: agent,
      timestamp: new Date(time).toISOString(), nativeRequestId: 'request' };
    assert.equal(store.apply(request, { requestId: 'transport', expiresAt: time + 5000 }).accepted, false);
    assert.equal(store.apply({ ...request, agentType: 'claude_code' }, { requestId: 'transport', expiresAt: time + 5000 }).accepted, false);
    assert.equal(store.snapshot().sessions.length, 0);
  }
  for (const agent of ['qwen', 'opencode']) {
    const store = makeStore();
    assert.equal(store.apply({ type: 'permission_request', sessionId: `${agent}-session`, agentType: agent,
      timestamp: new Date(time).toISOString(), nativeRequestId: 'request' }, { requestId: 'transport', expiresAt: time + 5000 }).accepted, true);
  }
});

test('clear-all history removes completed orphan facts while retaining active invisible processes', () => {
  for (const mode of ['clear', 'commit'] as const) {
    const store = makeStore(); store.apply(result('failed')); store.apply(message('PermissionResult'));
    store.apply(task('process', 'process'));
    store.apply(message('SessionEnd', { session_id: 'other-closed' }));
    if (mode === 'clear') store.clearHistory();
    else {
      const plan = store.prepareHistoryRemoval();
      assert.deepEqual(plan.sessionIds, []); assert.deepEqual(plan.kimiObservationIds, ['kimi_code-other-closed']);
      store.commitHistoryRemoval(plan);
    }
    let rows = JSON.parse(store.serialize()).kimiCodeObservations;
    assert.equal(rows.length, 1); assert.equal(rows[0].sessionId, sessionId);
    store.apply(result('process', 'completed'));
    if (mode === 'clear') store.clearHistory(); else store.commitHistoryRemoval(store.prepareHistoryRemoval());
    rows = JSON.parse(store.serialize()).kimiCodeObservations; assert.deepEqual(rows, []);
    assert.equal(store.apply(result('failed')).accepted, false); assert.equal(store.snapshot().sessions.length, 0);
  }
});
