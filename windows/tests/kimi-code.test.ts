import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { KIMI_CODE_HOOK_EVENTS, KimiCodeHookError, kimiCodeHookResponse, normalizeKimiCodeHook } from '../src/adapters/kimi-code';

const fixture = JSON.parse(readFileSync(new URL('../src/fixtures/companion/kimi-code-hooks.json', import.meta.url), 'utf8'));
const context = { timestamp: '2026-10-17T00:00:00Z', terminal: 'Windows Terminal', termSessionId: 'terminal-1' };
const payload = (event: string, patch: Record<string, unknown> = {}): Record<string, unknown> => ({
  ...fixture.cases.find((row: { event: string }) => row.event === event).input, ...patch,
});

test('Kimi Code Node 2.1.1 preserves all 20 pinned synthetic event mappings', () => {
  assert.equal(fixture.package, '@moonshot-ai/kimi-code'); assert.equal(fixture.version, '2.1.1');
  assert.equal(fixture.synthetic, true); assert.equal(fixture.sourceCommit, 'f67e6398fb3210ad8ace970e2dfd5bcc984ed61f');
  assert.deepEqual(new Set(fixture.cases.map((row: { event: string }) => row.event)), new Set(KIMI_CODE_HOOK_EVENTS));
  for (const row of fixture.cases) {
    const message = normalizeKimiCodeHook(row.input, { ...context, event: row.event });
    assert.equal(message.type, row.expectedType, row.event); assert.equal(message.observedState ?? null, row.expectedState, row.event);
    assert.equal(message.sessionId, 'kimi_code-node-fixture'); assert.equal(message.agentType, 'kimi');
    assert.equal(message.nativeEvent, `kimi_code.${row.event}`); assert.equal(message.statusIsAssistantReply, false);
    assert.equal(message.terminal, context.terminal); assert.equal(message.termSessionId, context.termSessionId);
    assert.equal(message.timestamp, context.timestamp);
  }
});

test('permission observations preserve exact native identity and cannot become control requests', () => {
  for (const event of ['PermissionRequest', 'PermissionResult']) {
    const message = normalizeKimiCodeHook(payload(event), context);
    assert.equal(message.type, 'status_update'); assert.equal(message.nativeRequestId, 'approval_fixture');
    assert.equal(message.nativeAgentId, 'agent-main'); assert.equal(message.nativeTurnId, '0');
    assert.equal(message.toolCallId, 'call-1'); assert.equal(message.approved, undefined);
    assert.equal(message.observedState, undefined);
    assert.deepEqual(kimiCodeHookResponse(payload(event), null), { stdout: '', exitCode: 0 });
    assert.throws(() => kimiCodeHookResponse(payload(event), { type: 'permission_response', sessionId: message.sessionId,
      timestamp: context.timestamp, approved: true }), (error: unknown) => error instanceof KimiCodeHookError && error.code === 'unsupported_interaction');
  }
  const missing = payload('PermissionRequest'); delete missing.id;
  assert.equal(normalizeKimiCodeHook(missing, context).nativeRequestId, undefined);
});

test('task notifications use source_id and cannot invent kind, tool identity, or parent tree', () => {
  const started = normalizeKimiCodeHook(payload('TaskStarted', { task_id: 'real-task', kind: 'agent' }), context);
  assert.equal(started.nativeBackgroundTask?.id, 'real-task'); assert.equal(started.nativeBackgroundTask?.startedAtMilliseconds, 1780000000000);
  assert.equal(started.toolCallId, undefined); assert.equal(started.subagentId, undefined); assert.equal(started.parentSessionId, undefined);
  for (const status of ['completed', 'failed', 'timed_out', 'killed', 'lost']) {
    const done = normalizeKimiCodeHook(payload('Notification', { source_id: 'real-task', notification_type: `task.${status}` }), context);
    assert.deepEqual(done.nativeBackgroundTask, { id: 'real-task', status, result: 'Fixture task\nObserved result' });
  }
  assert.equal(normalizeKimiCodeHook(payload('Notification', { source_kind: 'timer' }), context).nativeBackgroundTask, undefined);
  assert.equal(normalizeKimiCodeHook(payload('Notification', { notification_type: 'task.unknown' }), context).nativeBackgroundTask, undefined);
  for (const event of ['SubagentStart', 'SubagentStop']) {
    const message = normalizeKimiCodeHook(payload(event), context);
    assert.equal(message.type, 'status_update'); assert.equal(message.subagentId, undefined); assert.equal(message.parentSessionId, undefined);
  }
});

test('only UserPromptSubmit carries user text and manual compaction stays unconfirmed', () => {
  assert.equal(normalizeKimiCodeHook(payload('UserPromptSubmit'), context).prompt, 'Inspect fixture');
  assert.equal(normalizeKimiCodeHook(payload('TurnStarted', { origin_kind: 'task', prompt: 'Background injection' }), context).prompt, undefined);
  assert.equal(normalizeKimiCodeHook(payload('UserPromptQueued'), context).prompt, undefined);
  assert.equal(normalizeKimiCodeHook(payload('PostCompact', { trigger: 'manual' }), context).observedState, 'completionUnconfirmed');
  assert.equal(normalizeKimiCodeHook(payload('Stop'), context).observedState, 'completionUnconfirmed');
});

test('malformed Node fields, Python payloads and mismatched hook names fail closed', () => {
  const bad: [string, Record<string, unknown>][] = [
    ['SessionStart', { source: 'unknown' }], ['SessionStart', { session_id: 'a\nb' }], ['SessionStart', { session_id: '你'.repeat(342) }],
    ['SessionStart', { client_type: '' }], ['SessionStart', { cwd: 'x\0y' }], ['SessionStart', { model: null }],
    ['UserPromptSubmit', { prompt: 'Python prompt' }], ['UserPromptSubmit', { prompt: [{ type: 'text' }] }],
    ['UserPromptSubmit', { is_steer: 1 }], ['TurnStarted', { turn_id: true }], ['TurnStarted', { turn_id: -1 }],
    ['TaskStarted', { started_at: Number.MAX_SAFE_INTEGER + 1 }], ['TaskStarted', { started_at: 1.5 }],
    ['TaskStarted', { kind: 'subagent' }], ['TaskStarted', { status: 'unconfirmed' }], ['TaskStarted', { detached: 1 }],
    ['PermissionRequest', { display: [] }], ['PermissionRequest', { id: '' }], ['PermissionResult', { decision: 'allow' }],
    ['PermissionResult', { scope: 'global' }], ['PreToolUse', { tool_input: [] }], ['PostToolUseFailure', { error: 'failed' }],
    ['Notification', { sink: 'popup' }], ['SessionHeartbeat', { uptime_ms: NaN }],
  ];
  for (const [event, patch] of bad) assert.throws(() => normalizeKimiCodeHook(payload(event, patch), context), KimiCodeHookError, `${event}: ${JSON.stringify(patch)}`);
  assert.throws(() => normalizeKimiCodeHook(payload('SessionStart'), { ...context, event: 'Stop' }), KimiCodeHookError);
  assert.throws(() => normalizeKimiCodeHook(payload('SessionStart', { hook_event_name: 'TaskNotifications' }), context),
    (error: unknown) => error instanceof KimiCodeHookError && error.code === 'unsupported_event');
  assert.throws(() => normalizeKimiCodeHook({ event: 'TurnBegin', session_id: 'python' }, context), KimiCodeHookError);
});
