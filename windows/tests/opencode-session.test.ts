import assert from 'node:assert/strict';
import test from 'node:test';
import { SessionStore, isArchivedSession } from '../src/core';
import { normalizeOpenCodeHook } from '../src/adapters/opencode';

const event = (native_event: string, extra = {}) => normalizeOpenCodeHook({ native_event, session_id: 'session', cwd: 'C:\\test', ...extra });

test('OpenCode delete closes observations and pending controls without reporting success', () => {
  const store = new SessionStore(); store.apply(event('session.created'));
  store.apply(event('tool.started', { tool_name: 'Bash', tool_use_id: 'tool-1', tool_input: {} }));
  store.apply(event('permission.asked', { native_request_id: 'permission-1', native_request_kind: 'permission', permission: 'bash', patterns: ['test'] }),
    { requestId: 'channel-1', expiresAt: Date.now() + 10000 });
  const result = store.apply(event('session.deleted'));
  assert.deepEqual(result.cancelRequestIds, ['channel-1']);
  const session = store.snapshot().sessions[0]!;
  assert.equal(session.status, 'observationUnavailable'); assert.equal(session.completedAt, undefined);
  assert.equal(session.pendingInteractions.length, 0); assert.ok(session.observationEndedAt);
  assert.equal(session.events[0]!.completionUnconfirmed, true);
  assert.equal(store.apply(event('session.busy')).accepted, false);
});

test('OpenCode failed then archived stays failed, survives restore and can be deleted', () => {
  const store = new SessionStore(); store.apply(event('session.created'));
  store.apply(event('session.error', { error: 'request failed' })); store.apply(event('session.deleted'));
  const session = store.snapshot().sessions[0]!;
  assert.equal(session.status, 'error'); assert.equal(session.statusText, 'request failed');
  assert.equal(session.completedAt, undefined); assert.equal(isArchivedSession(session), true);
  const restored = new SessionStore(); restored.restore(store.serialize());
  assert.equal(restored.snapshot().sessions[0]!.status, 'error');
  assert.equal(restored.apply(event('tool.started', { tool_name: 'Read', tool_use_id: 'late' })).accepted, false);
  assert.equal(restored.dismiss(session.id), true);
  assert.equal(restored.apply(event('session.created')).accepted, false);
  assert.equal(restored.apply(event('prompt.submitted', { prompt: '明确的新问题' })).accepted, true);
  assert.equal(restored.snapshot().sessions[0]!.status, 'active');
});

test('OpenCode orphan closure persists without creating a success row', () => {
  const store = new SessionStore(); assert.equal(store.apply(event('session.deleted')).accepted, true);
  assert.equal(store.snapshot().sessions.length, 0);
  const restored = new SessionStore(); restored.restore(store.serialize());
  assert.equal(restored.apply(event('session.created')).accepted, false);
  assert.equal(restored.snapshot().sessions.length, 0);
});
