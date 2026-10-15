import test from 'node:test';
import assert from 'node:assert/strict';
import { SessionStore } from '../src/core/index';

test('preferences receive live state without restoring it as stale history', () => {
  const owner = new SessionStore();
  owner.apply({ type: 'session_start', sessionId: 's', timestamp: new Date().toISOString(), prompt: '实时任务' });
  const mirror = new SessionStore({ readOnly: true });
  assert.equal(mirror.receiveSnapshot(owner.snapshot()), true);
  assert.equal(mirror.snapshot().sessions[0].status, 'active');
  const old = owner.snapshot();
  owner.apply({ type: 'status_update', sessionId: 's', timestamp: new Date().toISOString(), status: '新状态' });
  mirror.receiveSnapshot(owner.snapshot());
  assert.equal(mirror.receiveSnapshot(old), false);
  assert.equal(mirror.snapshot().sessions[0].statusText, '新状态');
  assert.throws(() => owner.receiveSnapshot(mirror.snapshot()));
});

test('read-only windows cannot retain channels, submit approvals or delete authoritative history', () => {
  const owner = new SessionStore();
  owner.apply({ type: 'permission_request', sessionId: 's', timestamp: new Date().toISOString(), tool: 'Read' },
    { requestId: 'real-channel', expiresAt: Date.now() + 10_000 });
  const mirror = new SessionStore({ readOnly: true });
  const snapshot = owner.snapshot();
  mirror.receiveSnapshot(snapshot);
  const request = mirror.snapshot().sessions[0].pendingInteractions[0];
  assert.equal(request.transportRequestId, undefined);
  assert.equal(snapshot.sessions[0].pendingInteractions[0].transportRequestId, 'real-channel');
  assert.equal(mirror.prepareResponse('s', request.id, { kind: 'permission', approved: true }), null);
  assert.equal(mirror.dismiss('s'), false);
  assert.equal(mirror.clearHistory(), 0);
  assert.equal(mirror.apply({}).accepted, false);
});

test('invalid live snapshots do not replace the last validated preferences state', () => {
  const owner = new SessionStore();
  owner.apply({ type: 'session_start', sessionId: 's', timestamp: new Date().toISOString() });
  const mirror = new SessionStore({ readOnly: true });
  mirror.receiveSnapshot(owner.snapshot());
  const previous = mirror.snapshot();
  assert.throws(() => mirror.receiveSnapshot({ revision: previous.revision + 1, sessions: [{ id: 'broken' }] }));
  assert.deepEqual(mirror.snapshot(), previous);
});
