import assert from 'node:assert/strict';
import test from 'node:test';
import { TRAE_HOOK_EVENTS, TRAE_HOOK_PROFILE, TraeHookError, normalizeTraeHook, traeHookResponse } from '../src/adapters/trae';
import { SessionStore, type DIResponse } from '../src/core';

const timestamp = '2026-10-14T01:00:00Z';
const payload = (event: string, fields: Record<string, unknown> = {}) => ({ hook_event_name: event, session_id: 'fixture', cwd: 'C:\\项目', ...fields });
const tool = { tool_name: 'RunCommand', tool_use_id: 'call-1', tool_input: { command: 'Get-ChildItem', path: 'C:\\项目' } };
const base = { sessionId: 'trae-fixture', timestamp };

test('TraeWork CN shares one domestic observation namespace and cannot enable a tool gate', () => {
  const context = { edition: 'work-cn' as const, timestamp };
  const work = normalizeTraeHook(payload('Notification', { notification_type: 'permission_prompt', message: '确认' }), context);
  assert.equal(work.agentType, 'trae'); assert.equal(work.observedState, 'waitingPermission'); assert.equal(work.type, 'status_update');
  assert.equal(work.sessionId, normalizeTraeHook(payload('SessionStart'), { timestamp }).sessionId);
  assert.equal(normalizeTraeHook(payload('Stop', { last_assistant_message: '回复' }), context).observedState, 'completionUnconfirmed');
  assert.deepEqual(traeHookResponse(payload('PreToolUse', tool), null, context), { stdout: '{}', exitCode: 0 });
  assert.throws(() => normalizeTraeHook(payload('PreToolUse', tool), { ...context, preToolGate: true }), TraeHookError);
  assert.throws(() => traeHookResponse(payload('PreToolUse', tool), { ...base, type: 'permission_response', approved: true }, context), TraeHookError);
});

test('Trae CN dialect has exactly six documented events and rejects international/SOLO selection', () => {
  assert.equal(TRAE_HOOK_PROFILE, 'trae_cn'); assert.equal(TRAE_HOOK_EVENTS.length, 6);
  for (const event of TRAE_HOOK_EVENTS) {
    const fields = event === 'UserPromptSubmit' ? { prompt: '' } : event === 'PreToolUse' ? tool
      : event === 'PostToolUse' ? { ...tool, tool_response: {} } : event === 'Stop' ? { last_assistant_message: '' }
      : event === 'Notification' ? { notification_type: 'idle_prompt' } : {};
    assert.equal(normalizeTraeHook(payload(event, fields)).nativeEvent, event);
  }
  for (const edition of ['international', 'solo'] as const) {
    assert.throws(() => normalizeTraeHook(payload('SessionStart'), { edition }), error => error instanceof TraeHookError && error.code === 'unsupported_edition');
    assert.throws(() => traeHookResponse(payload('SessionStart'), null, { edition }), TraeHookError);
  }
  for (const event of ['PermissionRequest', 'SessionEnd', 'beforeSubmitPrompt', 'afterShellExecution', 'stop']) {
    assert.throws(() => normalizeTraeHook(payload(event)), error => error instanceof TraeHookError && error.code === 'unsupported_event');
    assert.deepEqual(traeHookResponse(payload(event), null), { stdout: '{}', exitCode: 0 });
  }
});

test('Trae CN requires real session and cwd, preserves empty user prompts and explicit context', () => {
  const message = normalizeTraeHook(payload('UserPromptSubmit', { prompt: '' }), { timestamp, terminal: 'Trae CN', termSessionId: 'tab-1' });
  assert.equal(message.sessionId, 'trae-fixture'); assert.equal(message.agentType, 'trae'); assert.equal(message.prompt, '');
  assert.equal(message.workingDir, 'C:\\项目'); assert.equal(message.timestamp, timestamp); assert.equal(message.termSessionId, 'tab-1');
  for (const fields of [{ session_id: '' }, { session_id: 'bad\0id' }, { cwd: '' }, { cwd: 7 }]) assert.throws(() => normalizeTraeHook(payload('SessionStart', fields)), TraeHookError);
  assert.throws(() => normalizeTraeHook(payload('Stop', { last_assistant_message: 'done' }), { hookEventName: 'Notification' }), TraeHookError);
});

test('Trae generic tools retain native call IDs and structured outputs without intercepting questions', () => {
  const fields = { tool_name: 'AskUserQuestion', tool_use_id: 'call-question', tool_input: { questions: [{ question: 'A?' }, { question: 'B?' }] },
    tool_response: { content: 'fixture' } };
  const start = normalizeTraeHook(payload('PreToolUse', fields));
  assert.equal(start.type, 'tool_start'); assert.equal(start.toolCallId, 'call-question'); assert.equal(start.questionText, undefined);
  const complete = normalizeTraeHook(payload('PostToolUse', fields));
  assert.equal(complete.type, 'tool_complete'); assert.deepEqual(JSON.parse(complete.toolResult!), fields.tool_response);
  assert.deepEqual(JSON.parse(complete.toolInput!), fields.tool_input);
  assert.throws(() => normalizeTraeHook(payload('PreToolUse', { tool_name: 'Read', tool_input: {} })), TraeHookError);
  assert.throws(() => normalizeTraeHook(payload('PostToolUse', { ...tool, tool_response: 'not an object' })), TraeHookError);
});

test('Trae notifications retain observed waiting states with no locally actionable request', () => {
  for (const [notification_type, expected] of Object.entries({ idle_prompt: 'idle', permission_prompt: 'waitingPermission', document_review: 'waitingPlanReview', ask_user_question: 'waitingAnswer' })) {
    const message = normalizeTraeHook(payload('Notification', { notification_type, message: 'Native action required' }));
    assert.equal(message.type, 'status_update'); assert.equal(message.observedState, expected); assert.equal(message.statusIsAssistantReply, false);
    assert.equal(message.questionText, undefined); assert.equal(message.planMarkdown, undefined);
    const store = new SessionStore(); store.apply(message);
    assert.equal(store.snapshot().sessions[0]!.status, expected); assert.equal(store.snapshot().sessions[0]!.pendingInteractions.length, 0);
  }
  assert.equal(normalizeTraeHook(payload('Notification', { notification_type: 'browser_interaction' })).observedState, undefined);
  assert.equal(normalizeTraeHook(payload('Notification', { notification_type: '__proto__' })).observedState, undefined);
});

test('Trae Stop is provisional regardless of other hook loop flags', () => {
  for (const stop_hook_active of [true, false]) {
    const message = normalizeTraeHook(payload('Stop', { last_assistant_message: 'No errors found', stop_hook_active, loop_count: 1 }));
    assert.equal(message.type, 'status_update'); assert.equal(message.observedState, 'completionUnconfirmed'); assert.equal(message.statusIsAssistantReply, true);
  }
  const store = new SessionStore(); store.apply(normalizeTraeHook(payload('SessionStart')));
  store.apply(normalizeTraeHook(payload('Stop', { last_assistant_message: 'ready' })));
  assert.equal(store.snapshot().sessions[0]!.status, 'completionUnconfirmed');
  store.apply(normalizeTraeHook(payload('Notification', { notification_type: 'idle_prompt' })));
  assert.equal(store.snapshot().sessions[0]!.status, 'idle');
});

test('default Trae observations emit neutral JSON and reject unsupported local decisions', () => {
  const native = payload('PreToolUse', tool);
  assert.deepEqual(traeHookResponse(native, null), { stdout: '{}', exitCode: 0 });
  for (const response of [{ ...base, type: 'permission_response', approved: true }, { ...base, type: 'question_response', answer: 'A' },
    { ...base, type: 'plan_response', planApproved: true }] as DIResponse[]) {
    assert.throws(() => traeHookResponse(native, response), error => error instanceof TraeHookError && error.code === 'unsupported_interaction');
  }
});

test('explicit Trae CN pre-tool gates return documented allow/deny, fallback ask, and never rewrite input', () => {
  const context = { preToolGate: true, edition: 'cn' as const };
  const native = payload('PreToolUse', tool), original = JSON.stringify(native);
  const message = normalizeTraeHook(native, context); assert.equal(message.type, 'permission_request'); assert.equal(message.permDescription, 'Get-ChildItem');
  for (const approved of [true, false]) {
    const output = traeHookResponse(native, { ...base, type: 'permission_response', approved }, context);
    assert.equal(output.exitCode, 0); assert.deepEqual(JSON.parse(output.stdout), {
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: approved ? 'allow' : 'deny' },
    });
  }
  assert.equal(JSON.parse(traeHookResponse(native, null, context).stdout).hookSpecificOutput.permissionDecision, 'ask');
  assert.equal(JSON.stringify(native), original);
  assert.throws(() => traeHookResponse(native, { ...base, sessionId: 'other', type: 'permission_response', approved: true }, context),
    error => error instanceof TraeHookError && error.code === 'invalid_response');
  assert.throws(() => traeHookResponse(native, { ...base, type: 'question_response', answer: 'A' }, context),
    error => error instanceof TraeHookError && error.code === 'invalid_response');
});

test('Trae explicit tool gate does not convert AskUserQuestion into an answered native question', () => {
  const native = payload('PreToolUse', { ...tool, tool_name: 'AskUserQuestion', tool_input: { question: 'Continue?' } });
  const message = normalizeTraeHook(native, { preToolGate: true });
  assert.equal(message.type, 'permission_request'); assert.equal(message.questionText, undefined); assert.equal(message.answer, undefined);
  const output = traeHookResponse(native, { ...base, type: 'permission_response', approved: true }, { preToolGate: true });
  assert.ok(!output.stdout.includes('updatedInput')); assert.ok(!output.stdout.includes('answer'));
});
