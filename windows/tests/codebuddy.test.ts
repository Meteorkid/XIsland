import assert from 'node:assert/strict';
import test from 'node:test';
import fixture from './fixtures/codebuddy-hooks.json';
import { CODEBUDDY_HOOK_EVENTS, CodeBuddyHookError, codeBuddyHookResponse, normalizeCodeBuddyHook } from '../src/adapters/codebuddy';
import { SessionStore, type DIResponse } from '../src/core';

const timestamp = '2026-10-17T00:00:00Z';
const payload = (event: string, fields: Record<string, unknown> = {}) => ({ ...fixture.session, hook_event_name: event, ...fields });
const base = { sessionId: `code_buddy-${fixture.session.session_id}`, timestamp };

test('CodeBuddy CLI contract fixture has ten explicit events, its own identity and native turn ID', () => {
  assert.deepEqual(fixture.events.map(item => item.hook_event_name), [...CODEBUDDY_HOOK_EVENTS]);
  const types = ['session_start', 'session_start', 'tool_start', 'tool_complete', 'status_update', 'status_update', 'status_update', 'context_compact', 'recap', 'session_end'];
  for (const [index, event] of fixture.events.entries()) {
    const message = normalizeCodeBuddyHook({ ...fixture.session, ...event, agentType: 'workbuddy' }, { timestamp });
    assert.equal(message.type, types[index]); assert.equal(message.agentType, 'code_buddy'); assert.equal(message.sessionId, base.sessionId);
    assert.equal(message.timestamp, timestamp); assert.equal(message.nativeEvent, event.hook_event_name); assert.equal(message.nativeTurnId, 'generation-1');
    assert.equal(message.workingDir, 'C:\\项目 空格'); assert.equal(message.statusIsAssistantReply, false);
  }
  for (const event of ['FinalStop', 'PermissionRequest', 'PostToolUseFailure', 'SubagentStart', 'Elicitation']) {
    assert.throws(() => normalizeCodeBuddyHook(payload(event)), error => error instanceof CodeBuddyHookError && error.code === 'unsupported_event');
  }
});

test('CodeBuddy never turns question tools or permission notifications into local interactions', () => {
  const store = new SessionStore();
  for (const tool_name of ['AskUserQuestion', 'ExitPlanMode', 'Bash']) {
    const message = normalizeCodeBuddyHook(payload('PreToolUse', { tool_name, tool_input: { questions: [{ question: 'A?' }, { question: 'B?' }], multiSelect: true }, call_id: 'not-native-id', tool_use_id: 'not-in-contract' }));
    assert.equal(message.type, 'tool_start'); assert.equal(message.toolCallId, undefined); assert.equal(message.options, undefined);
    assert.equal(store.apply(message).accepted, true);
  }
  store.apply(normalizeCodeBuddyHook(payload('Notification', { message: 'approve in client', notification_type: 'permission_prompt' })));
  const session = store.snapshot().sessions[0]!; assert.equal(session.status, 'waitingPermission'); assert.equal(session.pendingInteractions.length, 0);
});

test('CodeBuddy stop and anonymous child stop cannot claim parent completion or an assistant reply', () => {
  const store = new SessionStore();
  const apply = (event: string, extra = {}) => assert.equal(store.apply(normalizeCodeBuddyHook(payload(event, extra))).accepted, true);
  apply('UserPromptSubmit', { prompt: 'run' }); apply('SubagentStop', { last_assistant_message: 'must not copy', agent_id: 'foreign' });
  assert.equal(store.snapshot().sessions[0]!.status, 'active'); assert.deepEqual(store.snapshot().sessions[0]!.subagentIds, []);
  apply('Stop', { stop_hook_active: true, last_assistant_message: 'must not copy' });
  assert.equal(store.snapshot().sessions[0]!.status, 'completionUnconfirmed'); assert.equal(store.snapshot().sessions[0]!.agentResponse, '');
  apply('SessionEnd', { reason: 'other' }); assert.equal(store.snapshot().sessions[0]!.status, 'completed');
});

test('CodeBuddy preserves native tool response and compaction summary without inventing tool IDs', () => {
  const after = normalizeCodeBuddyHook({ ...fixture.session, ...fixture.events[3] });
  assert.deepEqual(JSON.parse(after.toolResult!), { success: true }); assert.equal(after.toolCallId, undefined);
  const summary = normalizeCodeBuddyHook({ ...fixture.session, ...fixture.events[8] });
  assert.equal(summary.recapText, '保留了项目约束');
  assert.equal(normalizeCodeBuddyHook(payload('SessionStart', { cwd: '' }), { projectDir: '\\\\server\\repo' }).workingDir, '\\\\server\\repo');
});

test('CodeBuddy neutral stdout never injects context and rejects all response types', () => {
  for (const event of fixture.events) assert.deepEqual(codeBuddyHookResponse({ ...fixture.session, ...event }, null), { stdout: '', exitCode: 0 });
  const decisions: DIResponse[] = [{ ...base, type: 'permission_response', approved: true }, { ...base, type: 'permission_response', approved: false },
    { ...base, type: 'question_response', answer: 'A' }, { ...base, type: 'question_response', selectedAnswers: ['A'] }, { ...base, type: 'plan_response', planApproved: true }];
  for (const decision of decisions) assert.throws(() => codeBuddyHookResponse(null, decision), error => error instanceof CodeBuddyHookError && error.code === 'unsupported_interaction');
});

test('CodeBuddy malformed records cannot create ambiguous session or synthetic success', () => {
  for (const session_id of [undefined, '', ' ', 1, 'bad\0id', '中'.repeat(1366)]) assert.throws(() => normalizeCodeBuddyHook(payload('SessionStart', { session_id })), CodeBuddyHookError);
  for (const native of [null, [], payload('PreToolUse', { tool_name: 'Bash', tool_input: [] }), payload('PostToolUse', { tool_name: 'Bash', tool_input: {}, tool_response: 'string' }),
    payload('Stop', { stop_hook_active: 1 }), payload('PostCompact', { compact_summary: 2 }), payload('SessionStart', { generation_id: 1 }),
    payload('Notification', { message: 'hello', notification_type: 1 }), payload('SessionStart', { cwd: null })]) assert.throws(() => normalizeCodeBuddyHook(native), CodeBuddyHookError);
  assert.throws(() => normalizeCodeBuddyHook(payload('SessionStart'), { timestamp: 'bad' }), CodeBuddyHookError);
});
