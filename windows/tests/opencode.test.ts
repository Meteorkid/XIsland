import assert from 'node:assert/strict';
import test from 'node:test';
import { OPENCODE_HOOK_EVENTS, normalizeOpenCodeHook, openCodeHookResponse } from '../src/adapters/opencode';
import type { DIResponse } from '../src/core/protocol';

const timestamp = '2026-10-17T00:00:00Z';
const event = (name: string, fields: Record<string, unknown> = {}) => ({
  native_event: name, session_id: 'ses_native', cwd: 'C:\\项目', ...fields,
});
const permission = (fields: Record<string, unknown> = {}) => event('permission.asked', {
  native_request_id: 'per_123', native_request_kind: 'permission', permission: 'edit', patterns: ['C:\\项目\\a.ts'], metadata: { diff: 'change' }, ...fields,
});
const question = (fields: Record<string, unknown> = {}) => event('question.asked', {
  native_request_id: 'que_123', native_request_kind: 'question', question: '选择分支？', options: ['main', 'dev'], ...fields,
});
const response = (approved: boolean): DIResponse => ({ type: 'permission_response', sessionId: 'opencode-ses_native', timestamp, approved });
const answer = (value: string): DIResponse => ({ type: 'question_response', sessionId: 'opencode-ses_native', timestamp, answer: value });
const answers = (selectedAnswers: string[]): DIResponse => ({ type: 'question_response', sessionId: 'opencode-ses_native', timestamp, selectedAnswers });

test('OpenCode native identity and event whitelist reject malformed payloads', () => {
  assert.equal(OPENCODE_HOOK_EVENTS.length, 15);
  for (const session_id of [undefined, '', ' ', 3, 'id\0suffix']) assert.throws(() => normalizeOpenCodeHook(event('session.created', { session_id })));
  assert.throws(() => normalizeOpenCodeHook(null));
  assert.throws(() => normalizeOpenCodeHook(event('permission.v2.asked')));
  assert.throws(() => normalizeOpenCodeHook(event('session.created'), { hookEventName: 'session.deleted' }));
  const result = normalizeOpenCodeHook(event('prompt.submitted', { prompt: '检查😀', model: 'model' }), { timestamp });
  assert.equal(result.sessionId, 'opencode-ses_native'); assert.equal(result.agentType, 'opencode');
  assert.equal(result.nativeEvent, 'prompt.submitted'); assert.equal(result.prompt, '检查😀');
  assert.equal(result.workingDir, 'C:\\项目'); assert.equal(result.model, 'model'); assert.equal(result.timestamp, timestamp);
});

test('OpenCode tool lifecycle preserves native call ID and structured input', () => {
  for (const name of ['tool.started', 'tool.completed', 'tool.failed']) {
    const result = normalizeOpenCodeHook(event(name, { tool_name: 'bash', tool_use_id: 'call', tool_input: { command: 'dir' }, tool_response: { ok: true } }));
    assert.equal(result.type, name === 'tool.started' ? 'tool_start' : 'tool_complete');
    assert.equal(result.toolCallId, 'call'); assert.equal(result.toolInput, '{"command":"dir"}'); assert.equal(result.toolResult, '{"ok":true}');
    assert.equal(result.observedState, name === 'tool.failed' ? 'error' : undefined);
  }
  assert.throws(() => normalizeOpenCodeHook(event('tool.started', { tool_name: 'bash' })));
});

test('OpenCode permission and question IDs retain their original request kinds', () => {
  const normalized = normalizeOpenCodeHook(permission());
  assert.equal(normalized.nativeRequestId, 'per_123'); assert.equal(normalized.nativeRequestKind, 'permission');
  assert.equal(normalized.filePath, 'C:\\项目\\a.ts'); assert.equal(normalized.toolInput, '{"diff":"change"}');
  for (const path of ['/tmp/a', '\\\\server\\share\\file']) assert.equal(normalizeOpenCodeHook(permission({ patterns: [path] })).filePath, path);
  assert.equal(normalizeOpenCodeHook(permission({ patterns: ['*.ts'] })).filePath, undefined);
  for (const invalid of [{ native_request_id: '' }, { native_request_kind: 'question' }, { patterns: [42] }]) {
    assert.throws(() => normalizeOpenCodeHook(permission(invalid)));
  }
  assert.throws(() => normalizeOpenCodeHook(question({ native_request_kind: 'permission' })));
  for (const name of ['interaction.resolved', 'interaction.unavailable']) {
    assert.throws(() => normalizeOpenCodeHook(event(name)));
    const result = normalizeOpenCodeHook(event(name, { native_request_id: 'same', native_request_kind: 'question' }));
    assert.equal(result.nativeRequestId, 'same'); assert.equal(result.observedState, name === 'interaction.unavailable' ? 'waitingAnswer' : undefined);
  }
});

test('OpenCode question options and multiplicity are validated without invented protocol fields', () => {
  for (const invalid of [{ options: [] }, { options: ['same', 'same'] }, { options: [''] }, { options: ['bad\0'] },
    { allow_custom_answer: 1 }, { allow_multiple_answers: 'yes' }]) assert.throws(() => normalizeOpenCodeHook(question(invalid)));
  const free = normalizeOpenCodeHook(question({ options: [], allow_custom_answer: true }));
  assert.deepEqual(free.options, []); assert.equal(free.allowsCustomAnswer, true);
  assert.equal('questions' in free, false); assert.equal('requestID' in free, false);
  assert.equal(normalizeOpenCodeHook(question({ allow_multiple_answers: true })).allowsMultipleAnswers, true);
});

test('OpenCode explicit lifecycle signals distinguish idle, errors, compaction and deletion', () => {
  assert.equal(normalizeOpenCodeHook(event('session.idle')).observedState, 'idle');
  assert.equal(normalizeOpenCodeHook(event('session.busy')).observedState, 'active');
  assert.equal(normalizeOpenCodeHook(event('session.error', { error: 'failed' })).status, 'failed');
  assert.equal(normalizeOpenCodeHook(event('session.compacted')).type, 'recap');
  assert.equal(normalizeOpenCodeHook(event('session.deleted')).observedState, 'observationUnavailable');
  const reply = normalizeOpenCodeHook(event('assistant.message', { message: 'No errors' }));
  assert.equal(reply.statusIsAssistantReply, true); assert.equal(reply.observedState, undefined);
});

test('OpenCode permissions only relay explicit same-session boolean decisions', () => {
  for (const approved of [true, false]) assert.deepEqual(openCodeHookResponse(permission(), response(approved)),
    { stdout: JSON.stringify({ decision: approved ? 'allow' : 'deny' }), exitCode: 0 });
  assert.throws(() => openCodeHookResponse(permission(), { ...response(true), sessionId: 'opencode-other' }));
  assert.throws(() => openCodeHookResponse(permission(), answer('yes')));
  assert.throws(() => openCodeHookResponse(event('session.idle'), response(true)));
});

test('OpenCode single answers enforce choices, Unicode byte limits, and free-answer policy', () => {
  assert.deepEqual(JSON.parse(openCodeHookResponse(question(), answer('main')).stdout), { answer: 'main' });
  assert.throws(() => openCodeHookResponse(question(), answer('other')));
  assert.throws(() => openCodeHookResponse(question(), answers(['main'])));
  const custom = question({ allow_custom_answer: true });
  assert.equal(JSON.parse(openCodeHookResponse(custom, answer('中文😀')).stdout).answer, '中文😀');
  for (const value of ['', ' ', 'bad\0', '中'.repeat(2731)]) assert.throws(() => openCodeHookResponse(custom, answer(value)));
});

test('OpenCode multiple answers preserve arrays with at most one custom value', () => {
  const multi = question({ allow_multiple_answers: true });
  assert.deepEqual(JSON.parse(openCodeHookResponse(multi, answers(['main', 'dev'])).stdout), { answers: ['main', 'dev'] });
  for (const value of [[], ['main', 'main'], ['unknown'], ['bad\0']]) assert.throws(() => openCodeHookResponse(multi, answers(value)));
  assert.throws(() => openCodeHookResponse(multi, answer('main')));
  const custom = question({ allow_multiple_answers: true, allow_custom_answer: true });
  assert.deepEqual(JSON.parse(openCodeHookResponse(custom, answers(['main', 'custom'])).stdout), { answers: ['main', 'custom'] });
  assert.throws(() => openCodeHookResponse(custom, answers(['custom one', 'custom two'])));
  assert.throws(() => openCodeHookResponse(custom, answers(['中'.repeat(2731)])));
});

test('OpenCode fallback never turns missing bridge output into approval or an answer', () => {
  for (const native_event of ['permission.asked', 'question.asked']) {
    assert.deepEqual(openCodeHookResponse({ native_event }, null), { stdout: '', exitCode: 1 });
  }
  assert.deepEqual(openCodeHookResponse(event('session.idle'), null), { stdout: '{}', exitCode: 0 });
  assert.deepEqual(openCodeHookResponse(event('unknown'), null), { stdout: '', exitCode: 1 });
  assert.deepEqual(openCodeHookResponse(null, null), { stdout: '', exitCode: 1 });
});
