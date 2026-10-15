import assert from 'node:assert/strict';
import test from 'node:test';
import { ClaudeHookError, claudeHookResponse, normalizeClaudeHook } from '../src/adapters/claude';
import type { DIResponse } from '../src/core/protocol';

const timestamp = '2026-10-13T00:00:00Z';
const event = (name: string, fields: Record<string, unknown> = {}): Record<string, unknown> => ({
  hook_event_name: name, session_id: 'parent', cwd: 'C:\\项目 A', ...fields,
});
const responseBase = { sessionId: 'claude_code-parent', timestamp };
const question = (hook = 'PreToolUse', fields: Record<string, unknown> = {}) => event(hook, {
  tool_name: 'AskUserQuestion', tool_input: { questions: [{
    header: '选择', question: 'How to proceed?', options: [{ label: 'Refactor' }, { label: 'Test' }], ...fields,
  }] },
});

test('native lifecycle retains identity, terminal context and user prompt', () => {
  const message = normalizeClaudeHook(event('UserPromptSubmit', { prompt: '检查项目😀' }), {
    timestamp, terminal: 'Windows Terminal', termSessionId: 'wt:tab-one',
  });
  assert.equal(message.sessionId, 'claude_code-parent');
  assert.equal(message.type, 'session_start');
  assert.equal(message.nativeEvent, 'UserPromptSubmit');
  assert.equal(message.workingDir, 'C:\\项目 A');
  assert.equal(message.prompt, '检查项目😀');
  assert.equal(message.terminal, 'Windows Terminal');
  assert.equal(message.termSessionId, 'wt:tab-one');
  assert.equal(message.timestamp, timestamp);
});

test('missing native session identity is rejected rather than fabricated', () => {
  for (const session_id of ['', ' ', 'id\0suffix', 7, undefined]) {
    assert.throws(() => normalizeClaudeHook(event('SessionStart', { session_id })), ClaudeHookError);
  }
  assert.throws(() => normalizeClaudeHook(null), ClaudeHookError);
  assert.throws(() => normalizeClaudeHook(event('InventedEvent')), error => error instanceof ClaudeHookError && error.code === 'unsupported_event');
});

test('Stop never manufactures final completion, SessionEnd does', () => {
  for (const stop_hook_active of [true, false]) {
    const message = normalizeClaudeHook(event('Stop', { stop_hook_active, last_assistant_message: 'Ready' }));
    assert.equal(message.type, 'status_update');
    assert.equal(message.observedState, 'completionUnconfirmed');
    assert.equal(message.status, 'Ready');
    assert.equal(message.statusIsAssistantReply, true);
  }
  assert.equal(normalizeClaudeHook(event('SessionEnd')).observedState, 'completed');
});

test('native child identity ignores misleading legacy parent and subagent fields', () => {
  const start = normalizeClaudeHook(event('SubagentStart', {
    agent_id: 'child', agent_type: 'Explore', parent_session_id: 'wrong', subagent_id: 'wrong',
  }));
  assert.equal(start.parentSessionId, 'claude_code-parent');
  assert.equal(start.subagentId, 'claude_code-child');
  const stop = normalizeClaudeHook(event('SubagentStop', { agent_id: 'child', agent_type: '', tokens_in: 500 }));
  assert.equal(stop.subagentEndIsProvisional, true);
  assert.equal(stop.statusIsAssistantReply, false);
  assert.equal(stop.tokensIn, undefined);
  assert.throws(() => normalizeClaudeHook(event('SubagentStart', { subagent_id: 'legacy', agent_type: 'Explore' })), ClaudeHookError);
});

test('tool input and results retain structured data and call identity', () => {
  const message = normalizeClaudeHook(event('PostToolUse', {
    tool_name: 'Read', tool_use_id: 'call-1', tool_input: { path: 'C:\\中文.txt', range: [1, 3] },
    tool_response: { lines: ['a', 'b'], ok: true }, usage: { input_tokens: 10, output_tokens: 4, total_tokens: 14 },
  }));
  assert.equal(message.type, 'tool_complete');
  assert.equal(message.toolCallId, 'call-1');
  assert.deepEqual(JSON.parse(message.toolInput!), { path: 'C:\\中文.txt', range: [1, 3] });
  assert.deepEqual(JSON.parse(message.toolResult!), { lines: ['a', 'b'], ok: true });
  assert.equal(message.totalTokens, 14);
  assert.equal(normalizeClaudeHook(event('PostToolUseFailure', { error: 'Failed' })).observedState, 'error');
  assert.equal(normalizeClaudeHook(event('PreToolUse', { tool_name: 'Bash', tool_input: { command: 'dir' } })).type, 'tool_start');
});

test('notification and compaction preserve observation semantics', () => {
  assert.equal(normalizeClaudeHook(event('Notification', { notification_type: 'permission_prompt' })).observedState, 'waitingPermission');
  assert.equal(normalizeClaudeHook(event('Notification', { notification_type: 'idle_prompt' })).observedState, 'idle');
  assert.equal(normalizeClaudeHook(event('Notification', { notification_type: 'unknown' })).observedState, undefined);
  assert.equal(normalizeClaudeHook(event('PreCompact')).type, 'context_compact');
});

test('permission decisions use structured allow/deny JSON and successful hook exit', () => {
  const payload = event('PermissionRequest', { tool_name: 'Bash', tool_input: JSON.stringify({ command: 'dir', file_path: 'C:\\项目' }) });
  const message = normalizeClaudeHook(payload);
  assert.equal(message.permDescription, 'dir');
  assert.equal(message.filePath, 'C:\\项目');
  for (const approved of [true, false]) {
    const output = claudeHookResponse(payload, { ...responseBase, type: 'permission_response', approved });
    assert.equal(output.exitCode, 0);
    assert.deepEqual(JSON.parse(output.stdout), { hookSpecificOutput: {
      hookEventName: 'PermissionRequest', decision: { behavior: approved ? 'allow' : 'deny' },
    } });
  }
});

test('no decision falls back to native processing without an implicit allow', () => {
  assert.deepEqual(claudeHookResponse(question(), null), { stdout: '{}', exitCode: 0 });
  assert.throws(() => claudeHookResponse(event('PermissionRequest'), {
    ...responseBase, sessionId: 'claude_code-another', type: 'permission_response', approved: true,
  }), error => error instanceof ClaudeHookError && error.code === 'invalid_response');
});

test('AskUserQuestion options and custom answers follow the Swift single-question response', () => {
  const payload = question();
  const before = JSON.stringify(payload);
  const message = normalizeClaudeHook(payload);
  assert.equal(message.type, 'question');
  assert.equal(message.questionText, '选择: How to proceed?');
  assert.deepEqual(message.options, ['Refactor', 'Test']);
  assert.equal(message.allowsCustomAnswer, true);
  for (const answer of ['Refactor', '自定义😀']) {
    const output = JSON.parse(claudeHookResponse(payload, { ...responseBase, type: 'question_response', answer }).stdout).hookSpecificOutput;
    assert.equal(output.hookEventName, 'PreToolUse');
    assert.equal(output.permissionDecision, 'allow');
    assert.equal(output.updatedInput.answer, answer);
    assert.deepEqual(output.updatedInput.answers, { 'How to proceed?': answer });
    assert.equal(output.updatedInput.questions[0].answer, answer);
    assert.deepEqual(output.updatedInput.questions[0].answers, [answer]);
  }
  assert.equal(JSON.stringify(payload), before);
});

test('PermissionRequest question preserves the existing Swift output event shape', () => {
  const output = claudeHookResponse(question('PermissionRequest'), { ...responseBase, type: 'question_response', answer: 'Test' });
  assert.equal(JSON.parse(output.stdout).hookSpecificOutput.hookEventName, 'PermissionRequest');
});

test('single question object and empty options allow a custom answer', () => {
  const payload = event('PreToolUse', { tool_name: 'AskUserQuestion', tool_input: { question: '项目路径？', options: [] } });
  assert.deepEqual(normalizeClaudeHook(payload).options, []);
  const output = JSON.parse(claudeHookResponse(payload, { ...responseBase, type: 'question_response', answer: 'C:\\项目😀' }).stdout);
  assert.deepEqual(output.hookSpecificOutput.updatedInput.answers, { '项目路径？': 'C:\\项目😀' });
});

test('multiple questions and multi-select explicitly remain in the native client', () => {
  const payload = question();
  payload.tool_input = { questions: [{ question: 'A' }, { question: 'B' }] };
  for (const unsupported of [payload, question('PreToolUse', { multiSelect: true })]) {
    assert.throws(() => normalizeClaudeHook(unsupported), error => error instanceof ClaudeHookError && error.code === 'unsupported_question');
    assert.throws(() => claudeHookResponse(unsupported, { ...responseBase, type: 'question_response', answer: 'A' }), ClaudeHookError);
  }
});

test('invalid or mismatched responses never emit an allow', () => {
  const responses = [
    { ...responseBase, type: 'question_response', answer: '' },
    { ...responseBase, type: 'question_response', selectedAnswers: ['A', 'B'] },
    { ...responseBase, type: 'permission_response', approved: true },
  ];
  for (const response of responses) assert.throws(() => claudeHookResponse(question(), response as DIResponse), ClaudeHookError);
});
