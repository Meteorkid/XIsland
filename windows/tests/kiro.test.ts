import assert from 'node:assert/strict';
import test from 'node:test';
import { KIRO_HOOK_EVENTS, kiroHookResponse, normalizeKiroHook } from '../src/adapters/kiro';
import { SessionStore } from '../src/core';

const payload = (event: string, fields: Record<string, unknown> = {}) => ({ hook_event_name: event,
  session_id: 'native/中文', cwd: 'C:\\项目', ...fields });
const tool = { tool_name: 'execute_pwsh', tool_input: { command: 'Get-Location' }, tool_response: { success: true, result: 'C:\\项目' } };

test('Kiro V3 has six explicit observation events and no native decision output', () => {
  assert.deepEqual(KIRO_HOOK_EVENTS, ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd']);
  for (const event of KIRO_HOOK_EVENTS) {
    const message = normalizeKiroHook(payload(event, { ...tool, prompt: '检查项目' }));
    assert.equal(message.agentType, 'kiro'); assert.equal(message.nativeEvent, `kiro_cli_${event}`);
    assert.equal(message.sessionId, 'kiro-cli-' + Buffer.from('native/中文').toString('base64'));
    assert.equal(message.nativeRequestId, undefined); assert.equal(message.toolCallId, undefined);
    assert.ok(!['permission_request', 'question', 'plan_review', 'tool_start'].includes(message.type));
    assert.deepEqual(kiroHookResponse(null, null), { stdout: '', exitCode: 0 });
  }
  assert.throws(() => kiroHookResponse(null, { type: 'permission_response', sessionId: 'native', timestamp: new Date().toISOString(), approved: true }));
});

test('Kiro V3 rejects missing identity, unsupported legacy dialects and malformed tool payloads', () => {
  for (const value of [null, [], payload('PermissionRequest'), payload('agentSpawn'), payload('stop'),
    payload('SessionStart', { session_id: undefined }), payload('SessionStart', { session_id: 'bad\nidentity' }),
    payload('SessionStart', { cwd: '' }), payload('UserPromptSubmit', { prompt: 1 }),
    payload('PreToolUse', { ...tool, tool_input: [] }), payload('PostToolUse', { ...tool, tool_response: 'not an object' }),
    payload('Stop', { assistant_response: null })]) assert.throws(() => normalizeKiroHook(value));
});

test('Kiro tool preparation does not invent execution or pair same-named parallel tools', () => {
  const store = new SessionStore();
  const before = normalizeKiroHook(payload('PreToolUse', { ...tool, call_id: 'unverified-id' }));
  assert.equal(before.type, 'status_update'); assert.equal(before.observedState, 'active'); assert.equal(before.tool, undefined);
  store.apply(before); store.apply(before);
  assert.equal(store.snapshot().sessions[0]!.events.length, 0);
  for (const result of ['first', 'second']) store.apply(normalizeKiroHook(payload('PostToolUse', { ...tool, tool_response: { success: true, result } })));
  const events = store.snapshot().sessions[0]!.events;
  assert.equal(events.length, 2); assert.ok(events.every(event => event.isComplete && event.toolCallId === undefined));
  assert.notEqual(events[0]!.result, events[1]!.result);
});

test('Only boolean false marks a Kiro tool failure', () => {
  for (const success of [0, 'false', null, undefined, true]) {
    assert.equal(normalizeKiroHook(payload('PostToolUse', { ...tool, tool_response: { success } })).observedState, undefined);
  }
  assert.equal(normalizeKiroHook(payload('PostToolUse', { ...tool, tool_response: { success: false } })).observedState, 'error');
});

test('Kiro Stop without answer preserves existing reply and cannot invent assistant history', () => {
  const store = new SessionStore();
  store.apply(normalizeKiroHook(payload('UserPromptSubmit', { prompt: 'read' })));
  store.apply(normalizeKiroHook(payload('Stop', { assistant_response: '真实答案' })));
  const before = store.snapshot().sessions[0]!;
  const stop = normalizeKiroHook(payload('Stop'));
  assert.equal(stop.statusIsAssistantReply, false); assert.equal(stop.observedState, 'completionUnconfirmed');
  store.apply(stop);
  const after = store.snapshot().sessions[0]!;
  assert.equal(after.status, 'completionUnconfirmed'); assert.equal(after.agentResponse, '真实答案');
  assert.deepEqual(after.chatHistory, before.chatHistory); assert.equal(after.completedAt, undefined);
});

test('Kiro SessionEnd closes and SessionStart resumes the same identity while preserving history', () => {
  const store = new SessionStore();
  store.apply(normalizeKiroHook(payload('UserPromptSubmit', { prompt: '保留历史' })));
  store.apply(normalizeKiroHook(payload('SessionEnd')));
  const ended = store.snapshot().sessions[0]!;
  assert.equal(ended.status, 'completed'); assert.ok(ended.completedAt);
  assert.equal(ended.chatHistory.some(chat => chat.content === 'Kiro 会话已结束'), false);
  const restored = new SessionStore(); restored.restore(store.serialize());
  assert.equal(restored.apply(normalizeKiroHook(payload('SessionStart'))).accepted, true);
  const resumed = restored.snapshot().sessions[0]!;
  assert.equal(resumed.id, ended.id); assert.equal(resumed.status, 'active'); assert.equal(resumed.completedAt, undefined);
  assert.deepEqual(resumed.chatHistory, ended.chatHistory);
});

test('Kiro Stop preserves a known error and a new prompt can resume the session', () => {
  const store = new SessionStore();
  store.apply(normalizeKiroHook(payload('SessionStart')));
  store.apply(normalizeKiroHook(payload('PostToolUse', { ...tool, tool_response: { success: false } })));
  store.apply(normalizeKiroHook(payload('Stop')));
  assert.equal(store.snapshot().sessions[0]!.status, 'error');
  store.apply(normalizeKiroHook(payload('UserPromptSubmit', { prompt: '再试' })));
  assert.equal(store.snapshot().sessions[0]!.status, 'active');
});
