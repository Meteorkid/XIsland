import assert from 'node:assert/strict';
import test from 'node:test';
import { GEMINI_HOOK_EVENTS, GeminiHookError, geminiHookResponse, normalizeGeminiHook } from '../src/adapters/gemini';
import { SessionStore, type DIResponse } from '../src/core/index';

const timestamp = '2026-10-13T00:00:00Z';
const event = (name: string, extra: Record<string, unknown> = {}) => ({ hook_event_name: name, session_id: 'native-test', cwd: 'C:\\Gemini 项目', ...extra });
const base = { sessionId: 'gemini_cli-native-test', timestamp };

test('Gemini supports exactly the eight NativeHookProfile observation events', () => {
  const types = ['session_start', 'session_start', 'tool_start', 'tool_complete', 'status_update', 'status_update', 'session_end', 'context_compact'];
  for (const [index, name] of GEMINI_HOOK_EVENTS.entries()) {
    const message = normalizeGeminiHook(event(name), { timestamp });
    assert.equal(message.type, types[index]); assert.equal(message.agentType, 'gemini_cli');
    assert.equal(message.sessionId, base.sessionId); assert.equal(message.nativeEvent, name); assert.equal(message.timestamp, timestamp);
  }
  for (const name of ['PermissionRequest', 'Question', 'SubagentStart', 'Stop', 'BeforeModel', 'AfterModel', 'BeforeToolSelection', 'PreCompact']) {
    assert.throws(() => normalizeGeminiHook(event(name)), error => error instanceof GeminiHookError && error.code === 'unsupported_event');
  }
});

test('Gemini invalid native identities never collapse into one cwd-derived session', () => {
  for (const session_id of [undefined, '', ' ', 4, 'bad\0id', '中'.repeat(1366)]) {
    assert.throws(() => normalizeGeminiHook(event('BeforeAgent', { session_id })), GeminiHookError);
  }
  assert.throws(() => normalizeGeminiHook(null), GeminiHookError);
  assert.throws(() => normalizeGeminiHook(event('BeforeAgent'), { timestamp: 'invalid' }), GeminiHookError);
});

test('Gemini BeforeAgent carries prompt, terminal and Windows paths from explicit context', () => {
  const message = normalizeGeminiHook(event('BeforeAgent', { prompt: '检查工程😀', terminal: '' }),
    { timestamp, terminal: 'Windows Terminal', termSessionId: 'wt:gemini' });
  assert.equal(message.prompt, '检查工程😀'); assert.equal(message.workingDir, 'C:\\Gemini 项目');
  assert.equal(message.terminal, 'Windows Terminal'); assert.equal(message.termSessionId, 'wt:gemini');
  const fallback = normalizeGeminiHook(event('SessionStart', { cwd: '' }), { projectDir: '\\\\server\\share' });
  assert.equal(fallback.workingDir, '\\\\server\\share');
});

test('Gemini AfterAgent follows prompt_response fixture without declaring completion', () => {
  // Sources: NativeHookPipelineTests.swift:95 and Scripts/test-native-hook-bridge.py.
  const message = normalizeGeminiHook(event('AfterAgent', { prompt_response: 'No errors found', message: 'old message' }));
  assert.equal(message.type, 'status_update'); assert.equal(message.status, 'No errors found');
  assert.equal(message.observedState, 'completionUnconfirmed'); assert.equal(message.statusIsAssistantReply, true);
  const empty = normalizeGeminiHook(event('AfterAgent', { prompt_response: '', message: 'must not replace empty native reply' }));
  assert.equal(empty.status, '');
  assert.equal(normalizeGeminiHook(event('SessionEnd')).observedState, 'completed');
});

test('Gemini permission notifications remain noninteractive and unknown idle notices prove no finality', () => {
  for (const notification_type of ['ToolPermission', 'permission_prompt']) {
    const message = normalizeGeminiHook(event('Notification', { notification_type, message: 'Approve in Gemini' }));
    assert.equal(message.type, 'status_update'); assert.equal(message.observedState, 'waitingPermission');
    assert.equal(message.statusIsAssistantReply, false); assert.equal(message.approved, undefined);
  }
  for (const notification_type of ['idle_prompt', 'unknown']) {
    const message = normalizeGeminiHook(event('Notification', { notification_type, message: 'Unknown notice' }));
    assert.equal(message.observedState, undefined); assert.equal(message.statusIsAssistantReply, false);
  }
  const store = new SessionStore(); store.apply(normalizeGeminiHook(event('SessionStart')));
  store.apply(normalizeGeminiHook(event('Notification', { notification_type: 'ToolPermission', message: 'Approve in Gemini' })));
  assert.equal(store.snapshot().sessions[0]!.status, 'waitingPermission'); assert.equal(store.snapshot().sessions[0]!.pendingInteractions.length, 0);
});

test('Gemini BeforeTool never converts a question-like tool into local question handling', () => {
  const input = { questions: [{ question: 'First?' }, { question: 'Second?' }], multiple: true };
  const message = normalizeGeminiHook(event('BeforeTool', { tool_name: 'AskUserQuestion', tool_use_id: 'tool-1', tool_input: input }));
  assert.equal(message.type, 'tool_start'); assert.equal(message.questionText, undefined); assert.equal(message.allowsMultipleAnswers, undefined);
  assert.equal(message.toolCallId, 'tool-1'); assert.deepEqual(JSON.parse(message.toolInput!), input);
});

test('Gemini structured output and usage are preserved without borrowing Tabnine error semantics', () => {
  const tool_response = { error: 'operational detail', output: ['a', 'b'] };
  const message = normalizeGeminiHook(event('AfterTool', { tool_name: 'run_shell_command', tool_use_id: 'call-1', tool_input: { command: 'dir' },
    tool_response, lines_added: 2, usage: { input_tokens: 10, output_tokens: 4, total_tokens: 14 }, cost_usd: 0.01, model: 'fixture' }));
  assert.equal(message.type, 'tool_complete'); assert.deepEqual(JSON.parse(message.toolResult!), tool_response); assert.equal(message.observedState, undefined);
  assert.equal(message.toolCallId, 'call-1'); assert.equal(message.tokensIn, 10); assert.equal(message.totalTokens, 14); assert.equal(message.costUSD, 0.01);
  assert.equal(normalizeGeminiHook(event('PreCompress')).status, 'Context window compacting...');
});

test('Gemini output is neutral and rejects every attempted local decision', () => {
  for (const name of GEMINI_HOOK_EVENTS) assert.deepEqual(geminiHookResponse(event(name), null), { stdout: '{}', exitCode: 0 });
  const decisions: DIResponse[] = [{ ...base, type: 'permission_response', approved: true }, { ...base, type: 'permission_response', approved: false },
    { ...base, type: 'question_response', answer: 'text' }, { ...base, type: 'question_response', selectedAnswers: ['A'] },
    { ...base, type: 'plan_response', planApproved: true }];
  for (const decision of decisions) assert.throws(() => geminiHookResponse(event('Notification'), decision),
    error => error instanceof GeminiHookError && error.code === 'unsupported_interaction');
});
