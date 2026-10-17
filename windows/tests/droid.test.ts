import assert from 'node:assert/strict';
import test from 'node:test';
import fixture from './fixtures/droid-hooks.json';
import { DROID_HOOK_EVENTS, DroidHookError, droidHookResponse, normalizeDroidHook } from '../src/adapters/droid';
import { SessionStore, type DIResponse } from '../src/core';

const timestamp = '2026-10-17T00:00:00Z';
const payload = (event: string, fields: Record<string, unknown> = {}) => ({ ...fixture.session, hook_event_name: event, ...fields });
const base = { sessionId: `droid-${fixture.session.session_id}`, timestamp };

test('Droid fixture covers nine events and keeps message identity separate from tool identity', () => {
  assert.deepEqual(fixture.events.map(item => item.hook_event_name), [...DROID_HOOK_EVENTS]);
  const types = ['session_start', 'session_start', 'tool_start', 'tool_complete', 'status_update', 'status_update', 'session_end', 'status_update', 'context_compact'];
  for (const [index, event] of fixture.events.entries()) {
    const message = normalizeDroidHook({ ...fixture.session, ...event, agentType: 'claude_code' }, { timestamp });
    assert.equal(message.type, types[index]); assert.equal(message.agentType, 'droid'); assert.equal(message.sessionId, base.sessionId);
    assert.equal(message.nativeMessageId, 'message-1'); assert.equal(message.toolCallId, undefined); assert.equal(message.timestamp, timestamp);
    assert.equal(message.nativeEvent, event.hook_event_name); assert.equal(message.workingDir, 'C:\\项目 空格'); assert.equal(message.statusIsAssistantReply, false);
  }
  for (const event of ['PermissionRequest', 'PostToolUseFailure', 'SubagentStart', 'PostCompact', 'FinalStop']) {
    assert.throws(() => normalizeDroidHook(payload(event)), error => error instanceof DroidHookError && error.code === 'unsupported_event');
  }
});

test('Droid notification cancellation and elicitation remain observations, not approvals or answers', () => {
  const store = new SessionStore();
  for (const [notification_type, status] of [['permission_prompt', 'waitingPermission'], ['elicitation_dialog', 'waitingAnswer'], ['idle_prompt', 'idle']]) {
    const message = normalizeDroidHook(payload('Notification', { notification_type, message: 'native dialog' }));
    assert.equal(message.type, 'status_update'); assert.equal(message.observedState, status);
    assert.equal(store.apply(message).accepted, true); assert.equal(store.snapshot().sessions[0]!.status, status);
    assert.equal(store.snapshot().sessions[0]!.pendingInteractions.length, 0);
  }
  for (const tool_name of ['AskUser', 'AskUserQuestion', 'ExitSpecMode']) {
    const message = normalizeDroidHook(payload('PreToolUse', { tool_name, tool_input: { questions: [{ question: 'A?' }, { question: 'B?' }] } }));
    assert.equal(message.type, 'tool_start'); assert.equal(message.options, undefined);
  }
});

test('Droid Stop and child result cannot declare finality or inject child replies into parent chat', () => {
  const store = new SessionStore();
  const apply = (event: string, extra = {}) => assert.equal(store.apply(normalizeDroidHook(payload(event, extra))).accepted, true);
  apply('UserPromptSubmit', { prompt: 'run' }); apply('SubagentStop', { task_name: 'review', task_error: 'child failed', last_assistant_message: 'child reply' });
  let session = store.snapshot().sessions[0]!; assert.equal(session.status, 'active'); assert.equal(session.agentResponse, ''); assert.deepEqual(session.subagentIds, []);
  apply('Stop', { stop_hook_active: true, last_assistant_message: 'not a Droid contract field' });
  session = store.snapshot().sessions[0]!; assert.equal(session.status, 'completionUnconfirmed'); assert.equal(session.agentResponse, '');
  apply('SessionEnd', { reason: 'other' }); assert.equal(store.snapshot().sessions[0]!.status, 'completed');
});

test('Droid tool response uses native tool shape without interpreting arbitrary error fields', () => {
  for (const tool_response of ['text', { output: ['a'], error: 'data field' }, ['a', 'b'], null]) {
    const message = normalizeDroidHook(payload('PostToolUse', { tool_name: 'Execute', tool_input: { command: 'dir' }, tool_response, tool_use_id: 'not-documented' }));
    assert.equal(message.toolResult, typeof tool_response === 'string' ? tool_response : JSON.stringify(tool_response));
    assert.equal(message.observedState, undefined); assert.equal(message.toolCallId, undefined);
  }
});

test('Droid hook output stays empty and rejects permission, question and spec decisions', () => {
  for (const event of fixture.events) assert.deepEqual(droidHookResponse({ ...fixture.session, ...event }, null), { stdout: '', exitCode: 0 });
  const decisions: DIResponse[] = [{ ...base, type: 'permission_response', approved: true }, { ...base, type: 'permission_response', approved: false },
    { ...base, type: 'question_response', answer: 'A' }, { ...base, type: 'question_response', selectedAnswers: ['A'] }, { ...base, type: 'plan_response', planApproved: true }];
  for (const decision of decisions) assert.throws(() => droidHookResponse(null, decision), error => error instanceof DroidHookError && error.code === 'unsupported_interaction');
});

test('Droid malformed identity and fields do not receive a default session', () => {
  for (const session_id of [undefined, '', ' ', 1, 'bad\0id', '中'.repeat(1366)]) assert.throws(() => normalizeDroidHook(payload('SessionStart', { session_id })), DroidHookError);
  for (const native of [null, [], payload('PreToolUse', { tool_name: 'Execute', tool_input: [] }), payload('Stop', { stop_hook_active: 'true' }),
    payload('UserPromptSubmit', { prompt: 'hello', has_images: 'false' }), payload('SessionStart', { message_id: 3 }),
    payload('Notification', { message: 'hello', notification_type: null }), payload('SessionStart', { cwd: null })]) assert.throws(() => normalizeDroidHook(native), DroidHookError);
  assert.throws(() => normalizeDroidHook(payload('SessionStart'), { timestamp: 'bad' }), DroidHookError);
  assert.equal(normalizeDroidHook(payload('SessionStart', { cwd: '' }), { projectDir: '\\\\server\\repo' }).workingDir, '\\\\server\\repo');
});
