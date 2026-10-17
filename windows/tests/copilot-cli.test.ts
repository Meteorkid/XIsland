import assert from 'node:assert/strict';
import test from 'node:test';
import { COPILOT_CLI_HOOK_EVENTS, CopilotCliHookError, copilotCliHookResponse, normalizeCopilotCliHook } from '../src/adapters/copilot-cli';
import { SessionStore } from '../src/core/session-store';

const timestamp = 1_792_195_200_000;
const payload = (event: string, extra: Record<string, unknown> = {}) => ({ native_event: event, sessionId: 'native-中文', cwd: 'C:\\项目 空格', timestamp, ...extra });
const rejectCode = (code: string) => (error: unknown) => error instanceof CopilotCliHookError && error.code === code;
const samples: Record<string, Record<string, unknown>> = {
  sessionStart: { source: 'startup', initialPrompt: '检查目录' }, sessionEnd: { reason: 'complete' },
  userPromptSubmitted: { prompt: '读取文档' }, preToolUse: { toolName: 'view', toolArgs: { path: 'README.md' } },
  postToolUse: { toolName: 'view', toolArgs: { path: 'README.md' }, toolResult: { resultType: 'success', textResultForLlm: '内容' } },
  postToolUseFailure: { toolName: 'powershell', toolArgs: '{"command":"exit 1"}', error: 'failed' },
  agentStop: { stopReason: 'end_turn', stop_hook_active: false }, subagentStart: { agentName: 'explore' },
  subagentStop: { agentId: 'child', agentType: 'explore', agentName: 'explore', response: 'child reply' },
  errorOccurred: { error: { message: 'provider unavailable', name: 'NetworkError' } },
  preCompact: { trigger: 'auto', customInstructions: '' },
  notification: { hook_event_name: 'Notification', notification_type: 'permission_prompt', message: 'Permission needed' },
};

test('Copilot CLI twelve camelCase events preserve their independent native identity and milliseconds', () => {
  assert.equal(COPILOT_CLI_HOOK_EVENTS.length, 12);
  for (const event of COPILOT_CLI_HOOK_EVENTS) {
    const message = normalizeCopilotCliHook(payload(event, { ...samples[event], agentType: 'copilot' }), { termSessionId: 'wt:one' });
    assert.equal(message.sessionId, 'copilot_cli-native-中文'); assert.equal(message.agentType, 'copilot_cli');
    assert.equal(message.nativeEvent, event); assert.equal(message.timestamp, new Date(timestamp).toISOString());
    assert.equal(message.workingDir, 'C:\\项目 空格'); assert.equal(message.termSessionId, 'wt:one');
    assert.equal(message.statusIsAssistantReply, false);
  }
});

test('Copilot CLI native command inputs do not invent tool IDs or permission requests', () => {
  const before = normalizeCopilotCliHook(payload('preToolUse', { ...samples.preToolUse, toolCallId: 'unattested', tool_use_id: 'unattested' }));
  assert.equal(before.type, 'status_update'); assert.equal(before.observedState, 'active'); assert.equal(before.toolCallId, undefined);
  assert.equal(before.nativeRequestId, undefined); assert.equal(before.tool, undefined);
  const after = normalizeCopilotCliHook(payload('postToolUse', samples.postToolUse));
  assert.equal(after.type, 'tool_complete'); assert.equal(after.toolCallId, undefined);
  assert.deepEqual(JSON.parse(after.toolResult!), { resultType: 'success', textResultForLlm: '内容' });
  const failure = normalizeCopilotCliHook(payload('postToolUseFailure', samples.postToolUseFailure));
  assert.equal(failure.observedState, 'error'); assert.equal(failure.toolInput, '{"command":"exit 1"}');
  assert.equal(failure.toolResult, 'failed');
});

test('Copilot CLI concurrent same-name preparation does not invent completion pairing', () => {
  const store = new SessionStore();
  for (const path of ['first.md', 'second.md']) {
    store.apply(normalizeCopilotCliHook(payload('preToolUse', { toolName: 'view', toolArgs: { path } })));
  }
  assert.equal(store.snapshot().sessions[0]!.events.length, 0);
  for (const path of ['first.md', 'second.md']) {
    store.apply(normalizeCopilotCliHook(payload('postToolUse', { toolName: 'view', toolArgs: { path },
      toolResult: { resultType: 'success', textResultForLlm: path } })));
  }
  const events = store.snapshot().sessions[0]!.events;
  assert.equal(events.length, 2); assert.ok(events.every(event => event.isComplete && event.toolCallId === undefined));
  assert.deepEqual(events.map(event => JSON.parse(event.input!).path), ['first.md', 'second.md']);
  assert.deepEqual(events.map(event => JSON.parse(event.result!).textResultForLlm), ['first.md', 'second.md']);
});

test('Copilot CLI Stop and background notifications never claim parent completion', () => {
  const stop = normalizeCopilotCliHook(payload('agentStop', samples.agentStop));
  assert.equal(stop.type, 'status_update'); assert.equal(stop.observedState, 'completionUnconfirmed'); assert.equal(stop.status, undefined);
  for (const kind of ['agent_idle', 'agent_completed', 'shell_completed']) {
    const message = normalizeCopilotCliHook(payload('notification', { notification_type: kind, message: 'background only' }));
    assert.equal(message.observedState, undefined); assert.equal(message.statusIsAssistantReply, false);
  }
  for (const event of ['subagentStart', 'subagentStop']) {
    const message = normalizeCopilotCliHook(payload(event, samples[event]));
    assert.equal(message.sessionId, stop.sessionId); assert.equal(message.observedState, undefined);
    assert.equal(message.status, 'explore'); assert.equal(message.parentSessionId, undefined);
  }
  const end = normalizeCopilotCliHook(payload('sessionEnd', samples.sessionEnd));
  assert.equal(end.type, 'session_end'); assert.equal(end.observedState, 'completed');
});

test('Copilot CLI permission and elicitation notifications stay observational', () => {
  for (const [notification_type, state] of [['permission_prompt', 'waitingPermission'], ['elicitation_dialog', 'waitingAnswer']]) {
    const message = normalizeCopilotCliHook(payload('notification', { notification_type, message: 'native UI' }));
    assert.equal(message.type, 'status_update'); assert.equal(message.observedState, state); assert.equal(message.nativeRequestId, undefined);
  }
  assert.deepEqual(copilotCliHookResponse(null, null), { stdout: '', exitCode: 0 });
  assert.throws(() => copilotCliHookResponse(null, { type: 'permission_response', sessionId: 'native', timestamp: new Date(timestamp).toISOString(), approved: true }), rejectCode('unsupported_interaction'));
  for (const event of ['permissionRequest', 'PermissionRequest', 'PreToolUse', 'SessionStart', 'futureEvent']) {
    assert.throws(() => normalizeCopilotCliHook(payload(event)), rejectCode('unsupported_event'));
  }
});

test('Copilot CLI rejects malformed or VS Code envelopes without reading transcripts', () => {
  for (const value of [null, [], 'string', {}, payload('sessionStart', { sessionId: '' }), payload('sessionStart', { cwd: '' }),
    payload('sessionStart', { timestamp: true }), payload('sessionStart', { timestamp: '2026-10-17T00:00:00Z' }),
    payload('sessionStart', { timestamp: Infinity }), payload('sessionStart', { timestamp: -1 }), payload('sessionStart', { timestamp: 1.5 }),
    payload('sessionStart', { timestamp: 8.64e15 + 1 }), payload('sessionStart', { hook_event_name: 'SessionStart' }),
    { hook_event_name: 'PreToolUse', session_id: 'vscode', cwd: 'C:\\x', timestamp },
    payload('preToolUse', { toolName: 'view' }), payload('preToolUse', { toolName: '', toolArgs: {} }),
    payload('postToolUse', { toolName: 'view', toolArgs: {}, toolResult: 'not-object' }),
    payload('postToolUseFailure', { toolName: 'view', toolArgs: {}, error: {} }),
    payload('notification', { notification_type: true, message: 'notice' }), payload('agentStop', { stop_hook_active: 'false' }),
    payload('errorOccurred', { error: 'failed' }), payload('subagentStart', { agentName: '' })]) {
    assert.throws(() => normalizeCopilotCliHook(value), CopilotCliHookError);
  }
  const result = normalizeCopilotCliHook(payload('agentStop', { transcriptPath: 'C:\\must-not-read\\session.jsonl', stop_hook_active: true }));
  assert.equal(result.status, undefined);
});

test('Copilot CLI session pipeline keeps Stop unconfirmed until explicit sessionEnd', () => {
  const store = new SessionStore();
  store.apply(normalizeCopilotCliHook(payload('sessionStart', samples.sessionStart)));
  store.apply(normalizeCopilotCliHook(payload('agentStop', samples.agentStop)));
  const session = store.snapshot().sessions[0]!;
  assert.equal(session.status, 'completionUnconfirmed');
  store.apply(normalizeCopilotCliHook(payload('sessionEnd', samples.sessionEnd)));
  assert.equal(store.snapshot().sessions[0]!.status, 'completed');
});
