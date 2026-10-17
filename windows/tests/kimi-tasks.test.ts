import test from 'node:test';
import assert from 'node:assert/strict';
import { KimiCodeObservationLedger, mergeKimiTask, kimiTaskEventId, parseKimiObservationState, foldKimiCodeObservation } from '../src/core/kimi-tasks';
import type { DIMessage } from '../src/core/protocol';

const request = { id: 'approval-1', agentId: 'agent-1', turnId: 'turn-1', toolCallId: 'tool-1' };

test('Kimi task terminal failure survives late starts and receives missing metadata', () => {
  const failed = { id: 'task', status: 'failed', result: 'Task failed' };
  const merged = mergeKimiTask(failed, { id: 'task', kind: 'agent', status: 'running', description: 'Late start', startedAtMilliseconds: 100 });
  assert.equal(merged?.status, 'failed'); assert.equal(merged?.result, 'Task failed');
  assert.equal(merged?.kind, 'agent'); assert.equal(merged?.description, 'Late start');
  assert.equal(mergeKimiTask(merged, { id: 'task', status: 'completed' })?.status, 'failed');
});

test('running facts after session end become unconfirmed and conflicting kinds cannot replace a task', () => {
  const ledger = new KimiCodeObservationLedger(); ledger.endSession();
  ledger.observeTask({ id: 'task', kind: 'agent', status: 'running' });
  assert.equal(ledger.snapshot().backgroundTasks[0].status, 'unconfirmed');
  assert.equal(ledger.canCreateSessionForTask('task'), false);
  ledger.observeTask({ id: 'task', kind: 'process', status: 'failed' });
  assert.equal(ledger.snapshot().backgroundTasks[0].kind, 'agent');
  assert.equal(ledger.snapshot().backgroundTasks[0].status, 'unconfirmed');
});

test('native result-before-request stays resolved, while mismatched identities never resolve pending approval', () => {
  const early = new KimiCodeObservationLedger(); early.observeResult(request); early.observeRequest(request);
  assert.equal(early.hasPendingApproval, false);
  const ledger = new KimiCodeObservationLedger(); ledger.observeRequest(request);
  ledger.observeResult({ ...request, turnId: 'another-turn' });
  assert.equal(ledger.projection().status, 'waitingPermission');
  ledger.observeInterrupt(); assert.equal(ledger.projection().status, 'completionUnconfirmed');
  ledger.observeResult(request); assert.deepEqual(ledger.projection(), {});
});

test('unidentified approval remains unconfirmed until session end instead of fabricating a channel', () => {
  const ledger = new KimiCodeObservationLedger(); ledger.observeRequest();
  ledger.observeResult(request); assert.equal(ledger.projection().status, 'completionUnconfirmed');
  ledger.endSession(); assert.equal(ledger.hasPendingApproval, false);
  assert.equal(ledger.snapshot().baseStatus, 'completed');
});

test('only running agent tasks can establish visibility and failed projections never look successful', () => {
  const ledger = new KimiCodeObservationLedger();
  ledger.observeTask({ id: 'process', kind: 'process', status: 'running' });
  ledger.observeTask({ id: 'late', status: 'failed', result: 'Failure' });
  assert.equal(ledger.canCreateSessionForTask('process'), false); assert.equal(ledger.canCreateSessionForTask('late'), false);
  ledger.observeTask({ id: 'late', kind: 'agent', status: 'running', startedAtMilliseconds: 100 });
  const events = ledger.taskEvents('session', 300);
  assert.equal(events.length, 1); assert.equal(events[0].isFailed, true); assert.equal(events[0].isComplete, true);
  assert.equal(events[0].toolCallId, undefined);
  assert.equal(events[0].id, kimiTaskEventId('session', 'late'));
  assert.notEqual(kimiTaskEventId('a', 'b\0c'), kimiTaskEventId('a\0b', 'c'));
});

test('ledger snapshots are isolated and malformed duplicate identities are rejected atomically', () => {
  const ledger = new KimiCodeObservationLedger(); ledger.observeRequest(request);
  const snapshot = ledger.snapshot(); snapshot.pending[0].turnId = 'changed';
  assert.equal(ledger.snapshot().pending[0].turnId, request.turnId);
  const bad = ledger.snapshot(); bad.pending.push({ ...request });
  assert.throws(() => parseKimiObservationState(bad));
  assert.equal(ledger.snapshot().pending.length, 1);
  assert.throws(() => parseKimiObservationState({ ...ledger.snapshot(), backgroundTasks: [{ id: 'a', status: 'made-up' }] }));
});

const message = (event: string, fields: Partial<DIMessage> = {}): DIMessage => ({ type: 'status_update', sessionId: 'kimi_code-session',
  timestamp: '2026-10-17T00:00:00Z', agentType: 'kimi', nativeEvent: `kimi_code.${event}`, statusIsAssistantReply: false, ...fields });
const approval = { nativeRequestId: request.id, nativeAgentId: request.agentId, nativeTurnId: request.turnId, toolCallId: request.toolCallId };

test('production fold retains result-before-request orphans across serialized restoration', () => {
  const early = foldKimiCodeObservation(undefined, message('PermissionResult', approval));
  assert.equal(early.handled, true); assert.equal(early.allowCreateSession, false);
  const restored = parseKimiObservationState(JSON.parse(JSON.stringify(early.state)));
  const late = foldKimiCodeObservation(restored, message('PermissionRequest', approval));
  assert.equal(late.allowCreateSession, false); assert.equal(late.state.pending.length, 0);
  assert.equal(late.state.resolved.length, 1);
});

test('production fold preserves native approval projection across tool starts, interruption and unrelated results', () => {
  const pending = foldKimiCodeObservation(undefined, message('PermissionRequest', approval), { status: 'idle' });
  assert.equal(pending.allowCreateSession, true); assert.equal(pending.status, 'waitingPermission');
  const tool = foldKimiCodeObservation(pending.state, message('PreToolUse', { type: 'tool_start' }));
  assert.equal(tool.status, 'waitingPermission'); assert.equal(tool.state.baseStatus, 'active');
  const interrupted = foldKimiCodeObservation(tool.state, message('Interrupt', { observedState: 'completionUnconfirmed' }));
  assert.equal(interrupted.status, 'completionUnconfirmed');
  const unrelated = foldKimiCodeObservation(interrupted.state, message('PermissionResult', { ...approval, nativeTurnId: 'wrong' }));
  assert.equal(unrelated.state.pending.length, 1);
  const done = foldKimiCodeObservation(unrelated.state, message('PermissionResult', approval));
  assert.equal(done.state.pending.length, 0); assert.equal(done.state.wasInterrupted, false);
  assert.equal(done.status, 'completionUnconfirmed');
});

test('production fold never creates unknown terminal task sessions and never resurrects tasks after terminal facts', () => {
  const early = foldKimiCodeObservation(undefined, message('Notification', { nativeBackgroundTask: { id: 'task', status: 'failed', result: 'failure' } }));
  assert.equal(early.allowCreateSession, false); assert.equal(early.handled, true);
  const late = foldKimiCodeObservation(early.state, message('TaskStarted', { nativeBackgroundTask: { id: 'task', kind: 'agent', status: 'running' } }));
  assert.equal(late.allowCreateSession, false); assert.equal(late.state.backgroundTasks[0].status, 'failed');
  const other = foldKimiCodeObservation(late.state, message('TaskStarted', { nativeBackgroundTask: { id: 'other', kind: 'agent', status: 'running' } }));
  assert.equal(other.allowCreateSession, true);
  const projection = new KimiCodeObservationLedger(other.state).taskEvents('kimi_code-session', 100);
  assert.equal(projection.find(event => event.isFailed)?.isComplete, true);
  assert.equal(projection.every(event => event.toolCallId === undefined), true);
});

test('closed orphan ledgers gate submission, requests and late running tasks until a real execution event', () => {
  const ended = foldKimiCodeObservation(undefined, message('SessionEnd', { type: 'session_end', observedState: 'completed' }));
  assert.equal(ended.allowCreateSession, false);
  const late = foldKimiCodeObservation(ended.state, message('TaskStarted', { nativeBackgroundTask: { id: 'task', kind: 'agent', status: 'running' } }));
  assert.equal(late.state.backgroundTasks[0].status, 'unconfirmed'); assert.equal(late.allowCreateSession, false);
  assert.equal(foldKimiCodeObservation(late.state, message('PermissionRequest', approval)).state.pending.length, 0);
  const submit = foldKimiCodeObservation(late.state, message('UserPromptSubmit', { type: 'session_start', prompt: 'blocked prompt' }));
  assert.equal(submit.status, 'completed'); assert.equal(submit.handled, true); assert.equal(submit.canRevive, false);
  const turn = foldKimiCodeObservation(submit.state, message('TurnStarted', { observedState: 'active' }));
  assert.equal(turn.status, 'active'); assert.equal(turn.allowCreateSession, true); assert.equal(turn.canRevive, true);
  assert.equal(turn.state.backgroundTasks[0].status, 'unconfirmed');
});

test('submission does not start execution, heartbeat and replay do not fabricate activity', () => {
  const submit = foldKimiCodeObservation(undefined, message('UserPromptSubmit', { type: 'session_start', prompt: 'text' }));
  assert.equal(submit.status, 'idle'); assert.equal(submit.canRevive, false);
  const heartbeat = foldKimiCodeObservation(submit.state, message('SessionHeartbeat'));
  assert.equal(heartbeat.handled, true); assert.equal(heartbeat.allowCreateSession, false); assert.deepEqual(heartbeat.state, submit.state);
  const replay = foldKimiCodeObservation(submit.state, message('PermissionRequest', { ...approval, nativeMessageReplay: true }));
  assert.equal(replay.allowCreateSession, false); assert.deepEqual(replay.state, submit.state);
  const error = foldKimiCodeObservation(undefined, message('StopFailure', { observedState: 'error', status: 'failure' }));
  assert.equal(foldKimiCodeObservation(error.state, message('Stop', { observedState: 'completionUnconfirmed' })).status, 'error');
});
