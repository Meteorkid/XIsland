import assert from 'node:assert/strict';
import test from 'node:test';
import { WINDSURF_HOOK_EVENTS, WindsurfHookError, normalizeWindsurfHook, windsurfHookResponse } from '../src/adapters/windsurf';
import { SessionStore, type DIResponse } from '../src/core';

const timestamp = '2026-10-14T01:00:00Z';
const payload = (event: string, info: Record<string, unknown>, fields: Record<string, unknown> = {}) => ({
  agent_action_name: event, trajectory_id: 'conversation-1', execution_id: 'turn-1', timestamp,
  model_name: 'Example model', tool_info: info, ...fields,
});
const mcp = { mcp_server_name: 'sample', mcp_tool_name: 'AskUserQuestion', mcp_tool_arguments: { question: '继续？' } };
const info = (event: string): Record<string, unknown> => event === 'pre_user_prompt' ? { user_prompt: '实现搜索' }
  : event === 'post_cascade_response' ? { response: 'Done' }
  : event.includes('run_command') ? { command_line: 'Get-ChildItem', cwd: 'C:\\项目' }
  : event.includes('mcp_tool_use') ? { ...mcp, ...(event.startsWith('post_') ? { mcp_result: 'still waiting' } : {}) }
  : { file_path: 'C:\\项目\\a.ts', ...(event.includes('write') ? { edits: [{ old_string: 'a', new_string: 'b' }] } : {}) };
const base = { sessionId: 'windsurf-conversation-1', timestamp };

test('Cascade supports the ten Swift events and rejects transcript/worktree and invented lifecycle hooks', () => {
  assert.equal(WINDSURF_HOOK_EVENTS.length, 10);
  for (const event of WINDSURF_HOOK_EVENTS) {
    const message = normalizeWindsurfHook(payload(event, info(event)));
    assert.equal(message.agentType, 'windsurf'); assert.equal(message.nativeEvent, event);
    assert.equal(message.type, event === 'pre_user_prompt' ? 'session_start' : event === 'post_cascade_response' ? 'status_update'
      : event.startsWith('pre_') ? 'tool_start' : 'tool_complete');
  }
  for (const event of ['onIdle', 'SessionStart', 'PermissionRequest', 'post_cascade_response_with_transcript', 'post_setup_worktree']) {
    assert.throws(() => normalizeWindsurfHook(payload(event, {})), error => error instanceof WindsurfHookError && error.code === 'unsupported_event');
    assert.deepEqual(windsurfHookResponse(payload(event, {}), null), { stdout: '', exitCode: 0 });
  }
});

test('trajectory identifies a conversation across turns; execution is never a tool-call ID', () => {
  const first = normalizeWindsurfHook(payload('pre_user_prompt', { user_prompt: 'First' }));
  const second = normalizeWindsurfHook(payload('pre_user_prompt', { user_prompt: 'Second' }, { execution_id: 'turn-2' }));
  const other = normalizeWindsurfHook(payload('pre_user_prompt', { user_prompt: 'Other' }, { trajectory_id: 'other' }));
  assert.equal(first.sessionId, second.sessionId); assert.notEqual(first.sessionId, other.sessionId);
  assert.equal(second.nativeTurnId, 'turn-2'); assert.equal(second.toolCallId, undefined); assert.equal(second.model, 'Example model');
});

test('native ISO timestamps and explicit terminal context are retained without guessed project roots', () => {
  const message = normalizeWindsurfHook(payload('pre_read_code', { file_path: 'C:\\project\\file.ts' },
    { timestamp: '2026-10-14T01:00:00.250Z', cwd: 'C:\\wrong-root', working_dir: 'C:\\wrong-root' }),
  { terminal: 'Windows Terminal', termSessionId: 'wt:1' });
  assert.equal(message.timestamp, '2026-10-14T01:00:00.250Z'); assert.equal(message.workingDir, undefined);
  assert.equal(message.terminal, 'Windows Terminal'); assert.equal(message.termSessionId, 'wt:1');
  for (const value of ['123456', 123456, '2026-02-30T00:00:00Z']) assert.throws(() => normalizeWindsurfHook(payload('pre_user_prompt', { user_prompt: 'x' }, { timestamp: value })), WindsurfHookError);
});

test('native tool_info is preserved and command/file events never invent output or user decisions', () => {
  for (const event of ['pre_run_command', 'post_run_command', 'pre_write_code', 'post_write_code', 'pre_read_code', 'post_read_code']) {
    const native = info(event); const message = normalizeWindsurfHook(payload(event, native));
    assert.deepEqual(JSON.parse(message.toolInput!), native); assert.equal(message.toolResult, undefined);
    assert.equal(message.permDescription, undefined); assert.equal(message.questionText, undefined);
    assert.equal(message.workingDir, event.includes('run_command') ? 'C:\\项目' : undefined);
  }
});

test('MCP tools retain their real name and arbitrary JSON results without claiming question support', () => {
  const question = normalizeWindsurfHook(payload('pre_mcp_tool_use', mcp));
  assert.equal(question.type, 'tool_start'); assert.equal(question.tool, 'mcp__sample__AskUserQuestion'); assert.equal(question.questionText, undefined);
  for (const result of ['text', { content: ['a', 'b'] }, [1, 2], null, false, 12]) {
    const message = normalizeWindsurfHook(payload('post_mcp_tool_use', { ...mcp, mcp_result: result }));
    assert.deepEqual(typeof result === 'string' ? message.toolResult : JSON.parse(message.toolResult!), result);
  }
});

test('Cascade response ends the turn without permanently closing the conversation', () => {
  const store = new SessionStore(); store.apply(normalizeWindsurfHook(payload('pre_user_prompt', { user_prompt: 'First' })));
  const response = normalizeWindsurfHook(payload('post_cascade_response', { response: '### Done' }));
  assert.equal(response.type, 'status_update'); assert.equal(response.observedState, 'idle'); assert.equal(response.statusIsAssistantReply, true);
  store.apply(response); assert.equal(store.snapshot().sessions[0]!.status, 'idle'); assert.equal(store.snapshot().sessions[0]!.completedAt, undefined);
});

test('missing native fields, mismatched events and malformed structured inputs are rejected', () => {
  for (const field of ['trajectory_id', 'execution_id', 'model_name']) assert.throws(() => normalizeWindsurfHook(payload('pre_user_prompt', { user_prompt: 'x' }, { [field]: ' ' })), WindsurfHookError);
  assert.throws(() => normalizeWindsurfHook(payload('pre_user_prompt', { user_prompt: 'x' }), { hookEventName: 'post_cascade_response' }), WindsurfHookError);
  for (const [event, native] of [
    ['pre_user_prompt', {}], ['pre_run_command', { command_line: 'pwd' }], ['pre_read_code', { file_path: 12 }],
    ['pre_write_code', { file_path: 'C:\\x', edits: [{ old_string: 'a' }] }],
    ['pre_mcp_tool_use', { ...mcp, mcp_tool_arguments: '{}' }], ['post_mcp_tool_use', mcp],
  ] as const) assert.throws(() => normalizeWindsurfHook(payload(event, native)), WindsurfHookError);
  assert.throws(() => normalizeWindsurfHook(payload('pre_user_prompt', { user_prompt: 'x' }, { invalid: NaN })), WindsurfHookError);
});

test('default observation never blocks and rejects attempted local approvals, questions or plans', () => {
  for (const event of WINDSURF_HOOK_EVENTS) assert.deepEqual(windsurfHookResponse(payload(event, info(event)), null), { stdout: '', exitCode: 0 });
  for (const response of [{ ...base, type: 'permission_response', approved: true }, { ...base, type: 'question_response', answer: 'yes' },
    { ...base, type: 'plan_response', planApproved: true }] as DIResponse[]) {
    assert.throws(() => windsurfHookResponse(payload('pre_run_command', info('pre_run_command')), response),
      error => error instanceof WindsurfHookError && error.code === 'unsupported_interaction');
  }
});

test('explicit local pre-tool gates use exit 2 to block, never fake a native approval JSON', () => {
  const context = { preToolGate: true };
  for (const event of ['pre_read_code', 'pre_write_code', 'pre_run_command', 'pre_mcp_tool_use']) {
    const native = payload(event, info(event));
    assert.equal(normalizeWindsurfHook(native, context).type, 'permission_request');
    assert.deepEqual(windsurfHookResponse(native, { ...base, type: 'permission_response', approved: true }, context), { stdout: '', exitCode: 0 });
    assert.deepEqual(windsurfHookResponse(native, { ...base, type: 'permission_response', approved: false }, context), { stdout: '', exitCode: 2 });
    assert.deepEqual(windsurfHookResponse(native, null, context), { stdout: '', exitCode: 2 });
  }
  assert.equal(normalizeWindsurfHook(payload('pre_user_prompt', { user_prompt: 'x' }), context).type, 'session_start');
  assert.deepEqual(windsurfHookResponse(payload('pre_user_prompt', { user_prompt: 'x' }), null, context), { stdout: '', exitCode: 0 });
  assert.throws(() => windsurfHookResponse(payload('pre_run_command', info('pre_run_command')), { ...base, sessionId: 'other', type: 'permission_response', approved: true }, context),
    error => error instanceof WindsurfHookError && error.code === 'invalid_response');
});
