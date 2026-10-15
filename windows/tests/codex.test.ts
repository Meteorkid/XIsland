import assert from 'node:assert/strict';
import test from 'node:test';
import { CODEX_HOOK_EVENTS, CodexHookError, codexHookResponse, normalizeCodexHook } from '../src/adapters/codex';
import { SessionStore, type DIResponse } from '../src/core/index';

const timestamp = '2026-10-13T00:00:00Z';
const event = (name: string, extra: Record<string, unknown> = {}) => ({ hook_event_name: name, session_id: 'parent', cwd: 'C:\\项目 A', ...extra });
const base = { sessionId: 'codex-parent', timestamp };

test('Codex supports the native profile including turn-bound interruption and compaction', () => {
  const types = ['session_start', 'session_start', 'tool_start', 'tool_complete', 'permission_request',
    'status_update', 'session_end', 'subagent_start', 'subagent_end', 'status_update', 'context_compact', 'status_update'];
  for (const [index, name] of CODEX_HOOK_EVENTS.entries()) {
    const message = normalizeCodexHook(event(name, { agent_id: 'child', agent_type: 'Explore', turn_id: 'turn-a', trigger: 'manual' }), { timestamp });
    assert.equal(message.type, types[index]); assert.equal(message.agentType, 'codex');
    assert.equal(message.sessionId, 'codex-parent'); assert.equal(message.nativeEvent, name);
  }
  for (const name of ['Notification', 'PostToolUseFailure', 'Question', 'PlanReview', 'stop']) {
    assert.throws(() => normalizeCodexHook(event(name)), error => error instanceof CodexHookError && error.code === 'unsupported_event');
  }
});

test('Codex requires native session identity and never derives it from a shared directory', () => {
  for (const session_id of [undefined, '', ' ', 12, 'id\0other', '中'.repeat(1366)]) {
    assert.throws(() => normalizeCodexHook(event('SessionStart', { session_id })), CodexHookError);
  }
  assert.throws(() => normalizeCodexHook([]), CodexHookError);
  assert.throws(() => normalizeCodexHook(event('SessionStart'), { timestamp: 'invalid' }), CodexHookError);
});

test('Codex prompt extraction retains the last user portion and injectable terminal context', () => {
  const message = normalizeCodexHook(event('UserPromptSubmit', { prompt: 'You are a coding assistant\n\nUser: Old\n\nUser: 检查当前项目😀', terminal: '' }),
    { timestamp, terminal: 'Windows Terminal', termSessionId: 'wt:123' });
  assert.equal(message.prompt, '检查当前项目😀'); assert.equal(message.workingDir, 'C:\\项目 A');
  assert.equal(message.terminal, 'Windows Terminal'); assert.equal(message.termSessionId, 'wt:123');
  assert.equal(message.timestamp, timestamp);
  const fallback = normalizeCodexHook(event('SessionStart', { working_dir: '', cwd: undefined }), { projectDir: '\\\\server\\project' });
  assert.equal(fallback.workingDir, '\\\\server\\project');
});

test('Codex Stop and SessionEnd reproduce native finality fixtures', () => {
  // Sources: NativeHookPipelineTests.swift and Scripts/test-native-hook-bridge.py.
  for (const stop_hook_active of [true, false]) {
    const stop = normalizeCodexHook(event('Stop', { stop_hook_active, last_assistant_message: 'No errors found' }));
    assert.equal(stop.type, 'status_update'); assert.equal(stop.observedState, 'completionUnconfirmed');
    assert.equal(stop.status, 'No errors found'); assert.equal(stop.statusIsAssistantReply, true);
  }
  const ended = normalizeCodexHook(event('SessionEnd'));
  assert.equal(ended.type, 'session_end'); assert.equal(ended.observedState, 'completed');
  const store = new SessionStore();
  store.apply(normalizeCodexHook(event('SessionStart'))); store.apply(ended);
  store.apply(normalizeCodexHook(event('Stop', { last_assistant_message: 'late' })));
  assert.equal(store.snapshot().sessions[0]!.status, 'completed');
});

test('Codex structured tools retain complete input, output and native call IDs', () => {
  const input = { command: 'dir', nested: { z: 2, a: 1 } }, output = { stdout: 'fixture', exit_code: 0 };
  const message = normalizeCodexHook(event('PostToolUse', { tool_name: 'Bash', tool_use_id: 'call', tool_input: input,
    tool_response: output, lines_added: 3, lines_removed: 1, usage: { input_tokens: 20, output_tokens: 5, total_tokens: 25 }, cost_usd: 0.02, model: 'fixture-model' }));
  assert.equal(message.type, 'tool_complete'); assert.equal(message.toolCallId, 'call');
  assert.deepEqual(JSON.parse(message.toolInput!), input); assert.deepEqual(JSON.parse(message.toolResult!), output);
  assert.equal(message.linesAdded, 3); assert.equal(message.tokensIn, 20); assert.equal(message.totalTokens, 25); assert.equal(message.costUSD, 0.02);
  assert.equal(normalizeCodexHook(event('PreToolUse', { tool_input: 'plain text' })).toolInput, 'plain text');
});

test('Codex AskUserQuestion remains a tool observation and has no invented answer contract', () => {
  const payload = event('PreToolUse', { tool_name: 'AskUserQuestion', tool_input: { questions: [{ question: 'A?' }, { question: 'B?' }] } });
  const message = normalizeCodexHook(payload); assert.equal(message.type, 'tool_start');
  assert.equal(message.questionText, undefined); assert.equal(message.allowsCustomAnswer, undefined);
  assert.throws(() => codexHookResponse(payload, { ...base, type: 'question_response', answer: 'A' }),
    error => error instanceof CodexHookError && error.code === 'unsupported_interaction');
  const permission = normalizeCodexHook(event('PermissionRequest', { tool_name: 'AskUserQuestion' }));
  assert.equal(permission.type, 'permission_request'); assert.equal(permission.questionText, undefined);
});

test('Codex subagents require native child/type identities for both start and provisional stop', () => {
  for (const name of ['SubagentStart', 'SubagentStop']) {
    const message = normalizeCodexHook(event(name, { agent_id: 'child', agent_type: 'Explore', subagent_id: 'wrong', parent_session_id: 'wrong', tokens_in: 99 }));
    assert.equal(message.parentSessionId, 'codex-parent'); assert.equal(message.subagentId, 'codex-child'); assert.equal(message.prompt, 'Explore');
    assert.equal(message.tokensIn, undefined); assert.equal(message.statusIsAssistantReply, false);
    assert.equal(message.subagentEndIsProvisional, name === 'SubagentStop' ? true : undefined);
    for (const extra of [{ agent_id: '' }, { agent_type: '' }, { agent_type: undefined }, { agent_id: 'bad\0id' }]) {
      assert.throws(() => normalizeCodexHook(event(name, { agent_id: 'child', agent_type: 'Explore', ...extra })), CodexHookError);
    }
  }
});

test('Codex allow and deny responses match the existing structured stdout fixture', () => {
  const payload = event('PermissionRequest', { tool_name: 'Bash', tool_input: JSON.stringify({ command: 'dir', file_path: 'C:\\项目' }), diff: '+new' });
  const message = normalizeCodexHook(payload); assert.equal(message.permDescription, 'dir'); assert.equal(message.filePath, 'C:\\项目');
  for (const approved of [true, false]) {
    const output = codexHookResponse(payload, { ...base, type: 'permission_response', approved });
    assert.equal(output.exitCode, 0); assert.deepEqual(JSON.parse(output.stdout), {
      hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: approved ? 'allow' : 'deny' } },
    });
    assert.ok(!output.stdout.includes('updatedInput')); assert.ok(!output.stdout.includes('updatedPermissions'));
  }
});

test('Codex neutral fallback never grants permission and rejects foreign/malformed decisions', () => {
  const payload = event('PermissionRequest', { tool_name: 'Bash' });
  assert.deepEqual(codexHookResponse(payload, null), { stdout: '{}', exitCode: 0 });
  assert.deepEqual(codexHookResponse(event('UnverifiedEvent'), null), { stdout: '{}', exitCode: 0 });
  for (const response of [{ ...base, type: 'question_response', answer: 'yes' },
    { ...base, type: 'permission_response', approved: true, sessionId: 'codex-other' },
    { ...base, type: 'permission_response', approved: 'true' }]) {
    assert.throws(() => codexHookResponse(payload, response as DIResponse), error => error instanceof CodexHookError && error.code === 'invalid_response');
  }
});
