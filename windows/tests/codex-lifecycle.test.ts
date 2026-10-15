import test from 'node:test';
import assert from 'node:assert/strict';
import { SessionStore } from '../src/core/index';
import { normalizeCodexHook } from '../src/adapters/codex';

const event = (name: string, turn?: unknown, extra: Record<string, unknown> = {}) => normalizeCodexHook({
  hook_event_name: name, session_id: 'turn-session', turn_id: turn, trigger: 'auto', ...extra,
});

test('Codex compaction observations validate native identities and trigger without inventing completion', () => {
  for (const name of ['PreCompact', 'PostCompact', 'Interrupt']) {
    for (const invalid of [undefined, '', ' ', 3, 'x\0y']) assert.throws(() => event(name, invalid));
    const normalized = event(name, 'turn');
    assert.equal(normalized.nativeTurnId, 'turn');
    assert.equal(normalized.statusIsAssistantReply, false);
    assert.equal(normalized.observedState, name === 'PreCompact' ? undefined : 'completionUnconfirmed');
  }
  assert.throws(() => event('PreCompact', 'a', { trigger: 'unknown' }));
  assert.equal(event('Interrupt', 'a', { trigger: undefined }).observedState, 'completionUnconfirmed');
  assert.equal(event('UserPromptSubmit', undefined).nativeTurnId, undefined);
});

test('unknown or retired Codex turns cannot clear a newer turn or revive terminal sessions', () => {
  const store = new SessionStore();
  assert.equal(store.apply(event('PreCompact', 'a')).accepted, false);
  store.apply(event('UserPromptSubmit', 'a'));
  store.apply(event('UserPromptSubmit', 'b'));
  for (const name of ['UserPromptSubmit', 'PreCompact', 'PostCompact', 'Interrupt']) {
    assert.equal(store.apply(event(name, 'a')).accepted, false, name);
  }
  assert.equal(store.apply(event('PostCompact', 'unknown')).accepted, false);
  assert.equal(store.apply(event('PreCompact', 'new-unknown')).accepted, true);
  assert.equal(store.snapshot().sessions[0].status, 'compacting');
  assert.equal(store.apply(event('PostCompact', 'new-unknown')).accepted, true);
  assert.equal(store.snapshot().sessions[0].status, 'completionUnconfirmed');
  store.apply(event('SessionEnd', 'new-unknown'));
  assert.equal(store.apply(event('PreCompact', 'another')).accepted, false);
  assert.equal(store.snapshot().sessions[0].status, 'completed');
});

test('native observations preserve pending approvals and compaction does not auto-complete on a timer', () => {
  let clock = Date.now();
  const store = new SessionStore({ now: () => clock });
  store.apply(event('UserPromptSubmit', 'a'));
  store.apply(event('PreCompact', 'a')); clock += 10_000; store.expire();
  assert.equal(store.snapshot().sessions[0].status, 'compacting');
  store.apply(event('PermissionRequest', 'a', { tool_name: 'Read' }), { requestId: 'p', expiresAt: clock + 20_000 });
  for (const name of ['Interrupt', 'PreCompact', 'PostCompact']) assert.equal(store.apply(event(name, 'a')).accepted, false);
  assert.equal(store.snapshot().sessions[0].pendingInteractions[0].transportRequestId, 'p');
});

test('turn identity is memory-scoped and legacy hooks remain usable after restoration', () => {
  const first = new SessionStore(); first.apply(event('UserPromptSubmit', 'old')); first.apply(event('UserPromptSubmit', 'new'));
  const store = new SessionStore(); store.restore(first.serialize());
  store.apply(event('SessionStart', undefined));
  assert.equal(store.apply(event('Interrupt', 'new')).accepted, false);
  assert.equal(store.apply(event('PreCompact', 'old')).accepted, true);
  assert.equal(store.apply(event('PostCompact', 'old')).accepted, true);
});

test('owner identity uses getRandomValues when randomUUID is unavailable in a WebView context', () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis.crypto, 'randomUUID');
  try {
    Object.defineProperty(globalThis.crypto, 'randomUUID', { configurable: true, value: undefined });
    const first = new SessionStore().snapshot().ownerInstanceId;
    const second = new SessionStore().snapshot().ownerInstanceId;
    assert.match(first!, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    assert.notEqual(first, second);
  } finally {
    if (descriptor) Object.defineProperty(globalThis.crypto, 'randomUUID', descriptor);
    else Reflect.deleteProperty(globalThis.crypto, 'randomUUID');
  }
});
