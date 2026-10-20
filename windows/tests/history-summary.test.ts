import test from 'node:test';
import assert from 'node:assert/strict';
import { aggregateHistoryUsage, compareHistorySessions, historyDate } from '../src/core/history-summary';
import { SessionStore } from '../src/core/session-store';
import type { Session } from '../src/core/types';

function session(id: string, patch: Partial<Session> = {}): Session {
  return { id, agentType: 'roo_code', status: 'observationUnavailable', prompt: '', statusText: '', agentResponse: '',
    workingDirectory: '', startedAt: 0, lastActivityAt: 0, observationEndedAt: 60_000,
    subagentIds: [], events: [], chatHistory: [], pendingInteractions: [], backgroundTasks: [],
    usage: { inputTokens: 100, outputTokens: 0, totalTokens: 0, costUSD: 1, model: '' },
    sourceNamespace: 'a'.repeat(24), sourceInstanceId: id, nativeTaskId: 'native-task', ...patch };
}

test('native task snapshots use maxima and union intervals without altering history', () => {
  const records = [session('a'), session('b', { startedAt: 30_000, observationEndedAt: 90_000,
    usage: { inputTokens: 120, outputTokens: 30, totalTokens: 0, costUSD: 1.5, model: '' } }),
  session('reload', { startedAt: 120_000, observationEndedAt: 150_000,
    usage: { inputTokens: 140, outputTokens: 30, totalTokens: 170, costUSD: 1.7, model: '' } })];
  const before = structuredClone(records);
  assert.deepEqual(aggregateHistoryUsage(records), [{ agentType: 'roo_code', startedAt: 0, durationMs: 120_000,
    inputTokens: 140, outputTokens: 30, totalTokens: 170, costUSD: 1.7, active: false }]);
  assert.deepEqual(records, before);
});

test('agent, namespace, opaque task identity and legacy sessions remain separate', () => {
  const records = [session('original'), session('profile', { sourceNamespace: 'b'.repeat(24) }),
    session('task', { nativeTaskId: 'other' }), session('agent', { agentType: 'pearai' }),
    session('legacy', { sourceInstanceId: undefined, usage: { inputTokens: 0, outputTokens: 0, totalTokens: 50, costUSD: 0, model: '' } })];
  const summaries = aggregateHistoryUsage(records);
  assert.equal(summaries.length, 5); assert.equal(summaries.reduce((sum, row) => sum + row.totalTokens, 0), 450);
  assert.equal(aggregateHistoryUsage([session('composed', { nativeTaskId: 'é' }), session('decomposed', { nativeTaskId: 'e\u0301' })]).length, 2);
  assert.equal(aggregateHistoryUsage([session('no-namespace', { sourceNamespace: undefined }), session('no-task', { nativeTaskId: undefined })]).length, 2);
});

test('duration freezes at completion or observation end and clamps invalid intervals', () => {
  assert.deepEqual(aggregateHistoryUsage([]), []);
  const summary = aggregateHistoryUsage([session('completed', { completedAt: 20_000 }),
    session('running', { startedAt: 10_000, observationEndedAt: undefined, status: 'thinking' }),
    session('future', { startedAt: 90_000, observationEndedAt: 50_000 })], 30_000)[0]!;
  assert.equal(summary.durationMs, 30_000); assert.equal(summary.active, true);
});

test('history orders actual endings ahead of last activity and has a stable ID tie break', () => {
  let now = 1000;
  const store = new SessionStore({ now: () => now });
  const send = (type: 'session_start' | 'session_end', id: string) => {
    assert.equal(store.apply({ type, sessionId: id, agentType: 'claude_code', timestamp: new Date(now).toISOString(),
      ...(type === 'session_end' ? { observedState: 'completed' } : {}) }).accepted, true);
  };
  send('session_start', 'a'); now = 2000; send('session_start', 'b');
  now = 3000; send('session_end', 'b'); now = 4000; send('session_end', 'a');
  assert.deepEqual([...store.snapshot().sessions].sort(compareHistorySessions).map(row => row.id), ['a', 'b']);
  const interrupted = session('interrupted', { observationEndedAt: 5000, lastActivityAt: 1 });
  assert.equal(historyDate(interrupted), 5000);
  assert.equal(historyDate(session('start', { startedAt: 100, observationEndedAt: undefined })), 100);
  assert.deepEqual([session('z'), session('a')].sort(compareHistorySessions).map(row => row.id), ['a', 'z']);
  assert.deepEqual([...store.snapshot().sessions, interrupted].sort(compareHistorySessions).map(row => row.id), ['interrupted', 'a', 'b']);
});
