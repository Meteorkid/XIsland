import assert from 'node:assert/strict';
import test from 'node:test';
import fixture from './fixtures/qwen-hooks.json';
import { QWEN_HOOK_EVENTS, QwenHookError, normalizeQwenHook, qwenHookResponse } from '../src/adapters/qwen';
import { SessionStore, type DIResponse } from '../src/core';

const timestamp = '2026-10-17T00:00:00Z';
const payload = (event: string, fields: Record<string, unknown> = {}) => ({ ...fixture.session, hook_event_name: event, ...fields });
const base = { sessionId: `qwen-${fixture.session.session_id}`, timestamp };
const permission = () => payload('PermissionRequest', { tool_name: 'run_shell_command', tool_input: { command: 'dir' } });

test('Qwen independent fixture covers exactly its declared native events and identity', () => {
  assert.deepEqual(fixture.events.map(item => item.hook_event_name), [...QWEN_HOOK_EVENTS]);
  const types = ['session_start', 'session_start', 'tool_start', 'tool_complete', 'tool_complete', 'permission_request',
    'status_update', 'status_update', 'session_end', 'subagent_start', 'subagent_end', 'context_compact'];
  for (const [index, event] of fixture.events.entries()) {
    const message = normalizeQwenHook({ ...fixture.session, ...event, agentType: 'claude_code' }, { timestamp });
    assert.equal(message.type, types[index]); assert.equal(message.agentType, 'qwen'); assert.equal(message.sessionId, base.sessionId);
    assert.equal(message.nativeEvent, event.hook_event_name); assert.equal(message.workingDir, 'C:\\项目 空格'); assert.equal(message.timestamp, timestamp);
  }
});

test('Qwen distinguishes internal tool ID from API call ID and reports native failures', () => {
  const before = normalizeQwenHook({ ...fixture.session, ...fixture.events[2] });
  assert.equal(before.toolCallId, 'toolu-1'); assert.equal(before.type, 'tool_start');
  const after = normalizeQwenHook({ ...fixture.session, ...fixture.events[3] });
  assert.equal(after.toolCallId, before.toolCallId); assert.deepEqual(JSON.parse(after.toolResult!), { output: 'README.md' });
  const failed = normalizeQwenHook({ ...fixture.session, ...fixture.events[4] });
  assert.equal(failed.observedState, 'error'); assert.equal(failed.toolResult, 'Command not found');
  assert.equal(normalizeQwenHook(permission()).nativeRequestId, undefined);
});

test('Qwen PermissionRequest allows and denies only the actual native pending permission', () => {
  for (const approved of [true, false]) {
    const result = qwenHookResponse(permission(), { ...base, type: 'permission_response', approved });
    assert.equal(result.exitCode, 0);
    assert.deepEqual(JSON.parse(result.stdout), { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: approved ? 'allow' : 'deny' } } });
  }
  assert.deepEqual(qwenHookResponse(null, null), { stdout: '{}', exitCode: 0 });
  assert.throws(() => qwenHookResponse(permission(), { ...base, sessionId: 'claude_code-other', type: 'permission_response', approved: true }), QwenHookError);
  assert.throws(() => qwenHookResponse(permission(), { ...base, type: 'permission_response', approved: 'yes' } as unknown as DIResponse), QwenHookError);
  for (const response of [{ ...base, type: 'question_response', answer: 'A' }, { ...base, type: 'plan_response', planApproved: true }] as DIResponse[]) {
    assert.throws(() => qwenHookResponse(permission(), response), error => error instanceof QwenHookError && error.code === 'invalid_response');
  }
});

test('Qwen question tools and observational events never receive fabricated answers or allow decisions', () => {
  for (const tool_name of ['ask_user_question', 'AskUserQuestion']) {
    for (const questions of [[{ question: 'A?', options: ['yes'] }], [{ question: 'A?' }, { question: 'B?' }]]) {
      const native = payload('PermissionRequest', { tool_name, tool_input: { questions, multiSelect: true } });
      const message = normalizeQwenHook(native);
      assert.equal(message.type, 'status_update'); assert.equal(message.observedState, 'waitingAnswer'); assert.equal(message.options, undefined);
      assert.throws(() => qwenHookResponse(native, { ...base, type: 'question_response', answer: 'yes' }), QwenHookError);
      assert.throws(() => qwenHookResponse(native, { ...base, type: 'permission_response', approved: true }), QwenHookError);
      assert.deepEqual(qwenHookResponse(native, null), { stdout: '{}', exitCode: 0 });
    }
    assert.equal(normalizeQwenHook(payload('PreToolUse', { tool_name, tool_input: {} })).type, 'tool_start');
  }
  assert.throws(() => qwenHookResponse(payload('Stop'), { ...base, type: 'permission_response', approved: true }), QwenHookError);
});

test('Qwen Stop is provisional and child identity is scoped to the native parent', () => {
  const store = new SessionStore();
  const apply = (event: string, extra = {}) => assert.equal(store.apply(normalizeQwenHook(payload(event, extra))).accepted, true);
  apply('UserPromptSubmit', { prompt: 'run' });
  apply('SubagentStart', { agent_id: 'child', agent_type: 'Explorer' });
  apply('SubagentStop', { agent_id: 'child', agent_type: 'Explorer', stop_hook_active: false });
  let session = store.snapshot().sessions[0]!;
  assert.equal(session.status, 'active'); assert.equal(session.events[0]!.completionUnconfirmed, true); assert.equal(session.events[0]!.isComplete, false);
  apply('Stop', { last_assistant_message: 'done', stop_hook_active: true });
  session = store.snapshot().sessions[0]!; assert.equal(session.status, 'completionUnconfirmed'); assert.equal(session.agentResponse, 'done');
  apply('SessionEnd'); assert.equal(store.snapshot().sessions[0]!.status, 'completed');
  const child = (session_id: string) => normalizeQwenHook(payload('SubagentStart', { session_id, agent_id: 'child', agent_type: 'Explorer' })).subagentId;
  assert.notEqual(child('parent-a'), child('parent-b'));
});

test('Qwen child tool, permission and end events share a child identity without mutating the parent', () => {
  const store = new SessionStore();
  store.apply(normalizeQwenHook(payload('UserPromptSubmit', { prompt: 'parent task' })));
  const childStart = normalizeQwenHook(payload('SubagentStart', { agent_id: 'child', agent_type: 'Explorer' }));
  store.apply(childStart);
  const childTool = normalizeQwenHook(payload('PreToolUse', { agent_id: 'child', tool_name: 'read_file', tool_input: { file_path: 'README.md' }, tool_use_id: 'child-call' }));
  assert.equal(childTool.sessionId, childStart.subagentId); assert.equal(childTool.parentSessionId, base.sessionId);
  store.apply(childTool);
  store.apply(normalizeQwenHook(payload('Stop', { agent_id: 'child', last_assistant_message: 'child finished' })));
  let sessions = store.snapshot().sessions;
  assert.equal(sessions.find(session => session.id === base.sessionId)!.status, 'active');
  assert.equal(sessions.find(session => session.id === base.sessionId)!.agentResponse, '');
  assert.equal(sessions.find(session => session.id === childTool.sessionId)!.status, 'completionUnconfirmed');
  store.apply(normalizeQwenHook(payload('SessionEnd', { agent_id: 'child' })));
  sessions = store.snapshot().sessions;
  assert.equal(sessions.find(session => session.id === base.sessionId)!.status, 'active');
  assert.equal(sessions.find(session => session.id === childTool.sessionId)!.status, 'completed');
  const childPermission = { ...permission(), agent_id: 'child' };
  assert.throws(() => qwenHookResponse(childPermission, { ...base, type: 'permission_response', approved: true }), QwenHookError);
  assert.equal(JSON.parse(qwenHookResponse(childPermission, { ...base, sessionId: childTool.sessionId, type: 'permission_response', approved: false }).stdout).hookSpecificOutput.decision.behavior, 'deny');
});

test('Qwen rejects malformed identity, event, tool data and context without an implicit approval', () => {
  for (const session_id of [undefined, '', ' ', 1, 'bad\0id', '中'.repeat(1366)]) assert.throws(() => normalizeQwenHook(payload('SessionStart', { session_id })), QwenHookError);
  for (const native of [null, [], payload('FinalStop'), payload('PermissionRequest', { tool_name: 'Bash', tool_input: [] }),
    payload('Stop', { stop_hook_active: 'true' }), payload('UserPromptSubmit', { prompt: 1 }), payload('Notification', { message: 'hello', notification_type: 1 }),
    payload('SubagentStop', { agent_id: '', agent_type: 'Explorer' }), payload('SessionStart', { cwd: 1 })]) assert.throws(() => normalizeQwenHook(native), QwenHookError);
  assert.throws(() => normalizeQwenHook(payload('SessionStart'), { timestamp: 'invalid' }), QwenHookError);
  assert.equal(normalizeQwenHook(payload('SessionStart', { cwd: '' }), { projectDir: '\\\\server\\project', terminal: 'Windows Terminal' }).workingDir, '\\\\server\\project');
});
