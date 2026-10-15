import assert from 'node:assert/strict';
import test from 'node:test';
import { CURSOR_HOOK_EVENTS, CursorHookError, cursorHookResponse, normalizeCursorHook } from '../src/adapters/cursor';

const timestamp = '2026-10-13T00:00:00Z';
const event = (name: string, fields: Record<string, unknown> = {}): Record<string, unknown> => ({
  hook_event_name: name, conversation_id: 'conversation', generation_id: 'turn-one',
  workspace_roots: ['C:\\项目'], model: 'model', ...fields,
});
const tool = (name: string, fields: Record<string, unknown> = {}) => event(name, {
  tool_name: 'Shell', tool_use_id: 'call-one', tool_input: { command: 'dir' }, ...fields,
});
const permission = (approved: boolean) => ({ type: 'permission_response' as const, sessionId: 'cursor-conversation', timestamp, approved });

test('Cursor exports only the nine observation and three validated approval events', () => {
  assert.equal(CURSOR_HOOK_EVENTS.length, 12);
  assert.equal((CURSOR_HOOK_EVENTS as readonly string[]).includes('beforeTabFileRead'), false);
});

test('Cursor uses conversation identity across turns and preserves the selected model', () => {
  const first = normalizeCursorHook(event('sessionStart'), { timestamp, terminal: 'Cursor', termSessionId: 'tab' });
  const second = normalizeCursorHook(event('beforeSubmitPrompt', { generation_id: 'turn-two', prompt: '检查😀', model_id: 'structured-model' }));
  assert.equal(first.sessionId, second.sessionId);
  assert.equal(second.sessionId, 'cursor-conversation');
  assert.equal(first.timestamp, timestamp);
  assert.equal(first.workingDir, 'C:\\项目');
  assert.equal(first.terminal, 'Cursor');
  assert.equal(second.prompt, '检查😀');
  assert.equal(second.model, 'structured-model');
});

test('Cursor rejects missing identity, foreign session, mismatched event and unknown schema', () => {
  for (const conversation_id of [undefined, '', ' ', 42, 'id\0suffix']) {
    assert.throws(() => normalizeCursorHook(event('sessionStart', { conversation_id })), CursorHookError);
  }
  assert.throws(() => normalizeCursorHook(event('sessionEnd', { session_id: 'other' })), CursorHookError);
  assert.throws(() => normalizeCursorHook(event('sessionStart'), { hookEventName: 'sessionEnd' }), CursorHookError);
  assert.throws(() => normalizeCursorHook(event('workspaceOpen')), error => error instanceof CursorHookError && error.code === 'unsupported_event');
  assert.throws(() => normalizeCursorHook(event('beforeTabFileRead', { file_path: 'C:\\file' })), CursorHookError);
});

test('generic Cursor tools retain their ID and structured input/result', () => {
  const message = normalizeCursorHook(tool('postToolUse', { tool_output: '{"exitCode":0,"stdout":"完成"}' }));
  assert.equal(message.type, 'tool_complete');
  assert.equal(message.toolCallId, 'call-one');
  assert.deepEqual(JSON.parse(message.toolInput!), { command: 'dir' });
  assert.equal(message.toolResult, '{"exitCode":0,"stdout":"完成"}');
  assert.throws(() => normalizeCursorHook(tool('preToolUse', { tool_use_id: undefined })), CursorHookError);
  assert.throws(() => normalizeCursorHook(tool('preToolUse', { tool_input: '{}' })), CursorHookError);
});

test('question-looking generic tools remain observation, not guessed question takeover', () => {
  const message = normalizeCursorHook(tool('preToolUse', { tool_name: 'AskUserQuestion', workspace_roots: ['C:\\a', 'D:\\b'] }));
  assert.equal(message.type, 'tool_start');
  assert.equal(message.questionText, undefined);
  assert.equal(message.workingDir, undefined);
  assert.throws(() => cursorHookResponse(tool('preToolUse'), { type: 'question_response', sessionId: 'cursor-conversation', timestamp, answer: 'yes' }), CursorHookError);
});

test('assistant text, loop completion and session end stay distinct', () => {
  const reply = normalizeCursorHook(event('afterAgentResponse', { text: 'No errors found' }));
  assert.equal(reply.statusIsAssistantReply, true);
  assert.equal(reply.observedState, undefined);
  for (const status of ['completed', 'aborted', 'error']) {
    const message = normalizeCursorHook(event('stop', { status }));
    assert.equal(message.type, 'status_update');
    assert.equal(message.observedState, status === 'error' ? 'error' : 'idle');
    assert.equal(message.statusIsAssistantReply, false);
  }
  assert.equal(normalizeCursorHook(event('sessionEnd', { session_id: 'conversation' })).observedState, 'completed');
  assert.throws(() => normalizeCursorHook(event('stop', { status: 'success' })), CursorHookError);
});

test('tool cancellation is distinct from failure and compaction is observation', () => {
  assert.equal(normalizeCursorHook(tool('postToolUseFailure', { error_message: 'failed' })).observedState, 'error');
  assert.equal(normalizeCursorHook(tool('postToolUseFailure', { error_message: 'cancelled', is_interrupt: true })).observedState, undefined);
  const compact = normalizeCursorHook(event('preCompact', { context_tokens: 120000 }));
  assert.equal(compact.type, 'context_compact');
  assert.equal(compact.totalTokens, undefined);
});

test('shell and MCP dedicated hooks use their distinct documented payloads', () => {
  const shell = normalizeCursorHook(event('beforeShellExecution', { command: 'npm test', cwd: 'D:\\project', sandbox: true }));
  assert.equal(shell.type, 'permission_request');
  assert.equal(shell.tool, 'Shell');
  assert.equal(shell.permDescription, 'npm test');
  assert.equal(shell.workingDir, 'D:\\project');
  const mcp = normalizeCursorHook(event('beforeMCPExecution', { tool_name: 'search', mcp_server_name: 'docs', tool_input: '{"q":"hooks"}' }));
  assert.equal(mcp.tool, 'MCP:docs/search');
  assert.equal(mcp.toolInput, '{"q":"hooks"}');
  assert.throws(() => normalizeCursorHook(event('beforeMCPExecution', { tool_name: 'search', mcp_server_name: 'docs', tool_input: {} })), CursorHookError);
});

test('file access approval retains path without persisting complete file contents', () => {
  const file = normalizeCursorHook(event('beforeReadFile', { file_path: 'C:\\项目\\private.txt', content: 'not copied to session', attachments: [] }));
  assert.equal(file.type, 'permission_request');
  assert.equal(file.filePath, 'C:\\项目\\private.txt');
  assert.equal(file.permDescription, file.filePath);
  assert.equal(JSON.stringify(file).includes('not copied to session'), false);
  assert.throws(() => normalizeCursorHook(event('beforeReadFile', { file_path: '' })), CursorHookError);
});

test('allow and deny use Cursor JSON, never Claude hookSpecificOutput or exit one', () => {
  const requests = [tool('preToolUse'), event('beforeShellExecution', { command: 'dir' }),
    event('beforeMCPExecution', { tool_name: 'search', mcp_server_name: 'docs', tool_input: '{}' }),
    event('beforeReadFile', { file_path: 'C:\\file' })];
  for (const payload of requests) for (const approved of [true, false]) {
    const result = cursorHookResponse(payload, permission(approved));
    assert.equal(result.exitCode, 0);
    assert.deepEqual(JSON.parse(result.stdout), { permission: approved ? 'allow' : 'deny' });
  }
});

test('unavailable observation output preserves existing Mac hook semantics', () => {
  assert.deepEqual(cursorHookResponse(tool('preToolUse'), null), { stdout: '{"permission":"allow"}', exitCode: 0 });
  assert.deepEqual(cursorHookResponse(event('beforeSubmitPrompt'), null), { stdout: '{"continue":true}', exitCode: 0 });
  assert.deepEqual(cursorHookResponse(event('stop'), null), { stdout: '{}', exitCode: 0 });
});

test('unanswered dedicated approvals never silently become allow', () => {
  for (const name of ['beforeShellExecution', 'beforeMCPExecution']) {
    const output = cursorHookResponse(event(name), null);
    assert.equal(output.exitCode, 0);
    assert.equal(JSON.parse(output.stdout).permission, 'ask');
  }
  const read = cursorHookResponse(event('beforeReadFile'), null);
  assert.equal(JSON.parse(read.stdout).permission, 'deny');
  assert.equal(read.exitCode, 0);
});

test('unknown fallback and mismatched responses do not invent successful native decisions', () => {
  assert.deepEqual(cursorHookResponse(event('futureEvent'), null), { stdout: '', exitCode: 1 });
  assert.deepEqual(cursorHookResponse(null, null), { stdout: '', exitCode: 1 });
  assert.throws(() => cursorHookResponse(event('beforeShellExecution', { command: 'dir' }), { ...permission(true), sessionId: 'cursor-other' }), CursorHookError);
  assert.throws(() => cursorHookResponse(event('stop', { status: 'completed' }), permission(true)), CursorHookError);
});
