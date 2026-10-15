import test from 'node:test';
import assert from 'node:assert/strict';
import { KimiCodeObservationLedger, mergeKimiTask, kimiTaskEventId, parseKimiObservationState } from '../src/core/kimi-tasks';

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
