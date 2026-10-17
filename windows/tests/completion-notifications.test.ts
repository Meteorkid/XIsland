import test from 'node:test';
import assert from 'node:assert/strict';
import { SessionStore } from '../src/core/session-store';
import type { DIMessage } from '../src/core/protocol';

function setup() {
  let now = Date.parse('2026-10-17T00:00:00Z'), mono = 0;
  const store = new SessionStore({ now: () => now, monotonicNow: () => mono });
  const notifications: string[] = [];
  const unsubscribe = store.subscribeCompletion(id => notifications.push(id));
  const send = (patch: Partial<DIMessage> = {}) => store.apply({ type: 'status_update', agentType: 'claude_code',
    sessionId: 'claude_code-main', timestamp: new Date(now).toISOString(), status: 'Final answer',
    statusIsAssistantReply: true, observedState: 'idle', nativeMessageId: 'reply-1', ...patch });
  send({ type: 'session_start', prompt: 'Question', status: undefined, nativeMessageId: 'user-1', observedState: undefined });
  return { store, notifications, send, unsubscribe, advance(ms: number) { now += ms; mono += ms; } };
}

test('only accepted latest final replies notify, partial/replay and old message updates stay quiet', () => {
  const { send, notifications, advance } = setup();
  send({ nativeMessagePartial: true }); send({ nativeMessageReplay: true });
  send({ statusIsAssistantReply: false }); send({ status: '' });
  send({ observedState: 'active' }); send({ observedState: 'error' });
  assert.equal(notifications.length, 0);
  send(); assert.deepEqual(notifications, ['claude_code-main']);
  advance(1800); send({ nativeMessageId: 'reply-2' }); assert.equal(notifications.length, 2);
  advance(1800); send({ nativeMessageId: 'reply-1', status: 'Old answer corrected' });
  send({ nativeMessageId: 'reply-2' }); assert.equal(notifications.length, 2);
  assert.equal(send({ agentType: 'foreign' }).accepted, false); assert.equal(notifications.length, 2);
});

test('reply notification is debounced for 1800ms per session using monotonic time', () => {
  const { send, notifications, advance } = setup();
  send(); advance(1799); send({ nativeMessageId: 'reply-2' }); assert.equal(notifications.length, 1);
  send({ sessionId: 'claude_code-other', nativeMessageId: 'reply-1' }); assert.equal(notifications.length, 2);
  advance(1); send({ nativeMessageId: 'reply-3' }); assert.equal(notifications.length, 3);
  advance(1800); send({ nativeMessageId: 'reply-2' }); assert.equal(notifications.length, 3);
});

test('user messages and stale timestamps cannot turn older replies into completion sounds', () => {
  const { send, notifications, advance } = setup();
  send({ nativeMessagePartial: true }); advance(2000);
  send({ type: 'session_start', prompt: 'Next question', status: undefined, nativeMessageId: 'user-2', observedState: undefined });
  send(); assert.equal(notifications.length, 0);
  send({ nativeMessageId: 'delayed-unknown', timestamp: '2026-10-17T00:00:00Z' }); assert.equal(notifications.length, 0);
  send({ nativeMessageId: 'current' }); assert.equal(notifications.length, 1);
});

test('completion signals never replay from restore, fixtures or settings snapshots', () => {
  const { store, send, notifications, advance } = setup();
  send();
  send({ type: 'session_end', status: undefined, statusIsAssistantReply: false, observedState: 'completed', nativeMessageId: undefined });
  assert.equal(notifications.length, 1);
  const saved = store.serialize(); store.restore(saved); assert.equal(notifications.length, 1);
  advance(2000); send({ status: 'Late reply', observedState: undefined }); assert.equal(notifications.length, 1);
  const mirror = new SessionStore({ readOnly: true }); const mirrored: string[] = [];
  mirror.subscribeCompletion(id => mirrored.push(id)); mirror.receiveSnapshot(store.snapshot());
  assert.deepEqual(mirrored, []);
  store.loadFixture({ sessions: [{ id: 'fixture', agentType: 'codex', status: 'completed' }] });
  assert.equal(notifications.length, 1);
});

test('explicit completion emits once, while interruption is never completion', () => {
  const { send, notifications, advance, unsubscribe } = setup();
  send({ type: 'session_end', observedState: 'observationUnavailable', status: 'Disconnected', statusIsAssistantReply: false });
  assert.equal(notifications.length, 0);
  send({ type: 'session_start', prompt: 'Resume', status: undefined, nativeMessageId: 'user-2', observedState: undefined });
  send({ type: 'session_end', observedState: 'completed', status: undefined, nativeMessageId: undefined, statusIsAssistantReply: false });
  assert.equal(notifications.length, 1);
  advance(2000); send({ type: 'session_end', observedState: 'completed', status: undefined, nativeMessageId: undefined });
  assert.equal(notifications.length, 1); unsubscribe();
  send({ sessionId: 'claude_code-other' }); assert.equal(notifications.length, 1);
});

test('completion-unconfirmed needs an explicit assistant final, not a provisional stop', () => {
  const { send, notifications } = setup();
  send({ observedState: 'completionUnconfirmed', statusIsAssistantReply: undefined });
  send({ observedState: 'completionUnconfirmed', nativeMessagePartial: true });
  assert.equal(notifications.length, 0);
  send({ observedState: 'completionUnconfirmed' }); assert.equal(notifications.length, 1);
});

test('a session end carrying an older reply cannot sound for that outdated message', () => {
  const { send, notifications, advance } = setup();
  send({ nativeMessagePartial: true }); advance(2000); send({ nativeMessageId: 'newer-reply' });
  assert.equal(notifications.length, 1);
  advance(2000); send({ type: 'session_end', observedState: 'completed' });
  assert.equal(notifications.length, 1);
});
