import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SessionStore, MESSAGE_TYPES, parseDIMessage, encodeMessage, decodeMessage, acceptsAnswers,
  type DIMessage, type Session } from '../src/core/index';
import { ObservationLedger, taskSessionId } from '../src/core/observation';

const fixture = (name: string): unknown => JSON.parse(readFileSync(new URL(`../src/fixtures/${name}`, import.meta.url), 'utf8'));
const epoch = Date.parse('2026-10-13T00:00:00Z');
function setup() {
  let now = epoch, mono = 0, serial = 0;
  const store = new SessionStore({ now: () => now, monotonicNow: () => mono, id: () => `id-${++serial}` });
  const message = (type: DIMessage['type'], extra: Partial<DIMessage> = {}): DIMessage =>
    ({ type, sessionId: 'claude_code-main', agentType: 'claude_code', timestamp: new Date(now).toISOString(), ...extra });
  const apply = (type: DIMessage['type'], extra: Partial<DIMessage> = {}, transportId?: string) =>
    store.apply(message(type, extra), transportId ? { requestId: transportId, expiresAt: now + 290_000 } : undefined);
  const session = (id = 'claude_code-main'): Session => { const result = store.snapshot().sessions.find(item => item.id === id); assert.ok(result); return result; };
  return { store, message, apply, session, advance(ms: number) { now += ms; mono += ms; } };
}

test('all wire event types and full optional field families round trip', () => {
  for (const type of MESSAGE_TYPES) {
    const message: DIMessage = { type, sessionId: '测试-session', timestamp: '2026-10-13T00:00:00Z', agentType: 'claude_code',
      nativeEvent: 'event', nativeAgentId: 'a', nativeTurnId: 't', nativeBackgroundTask: { id: 'b', status: 'running', kind: 'job', description: '后台', startedAtMilliseconds: epoch, result: 'ok' },
      nativeMessageId: 'm', nativeMessagePartial: true, nativeMessageReplay: false, sourceNamespace: 'source', sourceInstanceId: 'instance', nativeTaskId: '任务😀', observationSequence: 1,
      terminal: 'WindowsTerminal', termSessionId: 'tab', workingDir: 'C:\\项目', prompt: '提问', toolCallId: 'call', tool: 'Read', toolInput: '{}', toolResult: '行1\n行2', linesAdded: 1, linesRemoved: 2,
      nativeRequestId: 'req', nativeRequestKind: 'question', permDescription: '权限', diff: '+text', filePath: '\\\\server\\share', approved: false,
      questionText: '问题', options: ['A'], allowsCustomAnswer: true, allowsMultipleAnswers: false, answer: '文本', selectedAnswers: ['A'],
      planMarkdown: '# 计划', planApproved: false, feedback: '修改', status: '就绪', observedState: 'idle', statusIsAssistantReply: false,
      tokensIn: 1, tokensOut: 2, totalTokens: 3, costUSD: 0.01, usageIsCumulative: true, model: 'model', recapText: '摘要', parentSessionId: 'parent', subagentId: 'child', subagentEndIsProvisional: true };
    assert.deepEqual(decodeMessage(encodeMessage(message)), message);
  }
});

test('strict decoder rejects missing, mistyped, unsafe fields and ignores unknown keys', () => {
  const { message } = setup(); const good = message('session_start');
  for (const invalid of [{ ...good, timestamp: undefined }, { ...good, type: 'not_known' }, { ...good, sessionId: '' },
    { ...good, timestamp: '2026-02-30T00:00:00Z' }, { ...good, timestamp: '2026-10-13T24:00:00Z' },
    { ...good, tokensIn: true }, { ...good, tokensIn: Number.MAX_SAFE_INTEGER + 1 }, { ...good, approved: 1 }, { ...good, costUSD: Infinity },
    { ...good, options: [1] }, { ...good, nativeBackgroundTask: { id: 'a', status: false } }]) assert.throws(() => parseDIMessage(invalid));
  assert.equal(parseDIMessage({ ...good, prompt: null, unexpected: 'ignored' }).prompt, undefined);
  assert.ok(!('unexpected' in parseDIMessage({ ...good, unexpected: true })));
  assert.throws(() => decodeMessage('{"type":'));
  assert.throws(() => decodeMessage(encodeMessage(good) + encodeMessage(good)));
});

test('snapshot and subscriptions cannot mutate stored state', () => {
  const { store, apply, session } = setup(); let notifications = 0;
  const unsubscribe = store.subscribe(snapshot => { notifications++; assert.throws(() => snapshot.sessions.push({} as Session), TypeError); });
  apply('session_start', { prompt: 'first' });
  const snapshot = store.snapshot(); assert.throws(() => { snapshot.sessions[0]!.prompt = 'modified'; }, TypeError);
  assert.equal(session().prompt, 'first'); assert.equal(notifications, 2);
  unsubscribe(); apply('status_update', { status: 'next' }); assert.equal(notifications, 2);
});

test('same suffix from independent agents never merges, exact IDs win', () => {
  const { apply, store } = setup();
  for (const agent of ['cursor', 'roo_code', 'pearai', 'codex', 'trae', 'trae_ide_cn', 'traework_cn']) apply('session_start', { sessionId: `${agent}-same`, agentType: agent, prompt: agent });
  assert.equal(store.snapshot().sessions.length, 7);
  apply('status_update', { sessionId: 'codex-same', agentType: 'codex', status: 'codex only' });
  assert.equal(store.snapshot().sessions.find(session => session.agentType === 'cursor')!.agentResponse, '');
});

test('mirrored Claude interactive response retains the original wire session ID', () => {
  const { apply, store, session } = setup();
  apply('session_start', { sessionId: 'cursor-shared', agentType: 'cursor' });
  apply('permission_request', { sessionId: 'claude_code-shared', tool: 'Bash' }, 'channel');
  assert.equal(store.snapshot().sessions.length, 1);
  const request = session('cursor-shared').pendingInteractions[0]!;
  const prepared = store.prepareResponse('cursor-shared', request.id, { kind: 'permission', approved: true });
  assert.equal(prepared?.response.sessionId, 'claude_code-shared');
  assert.equal(prepared?.sessionId, 'cursor-shared');
});

test('WorkBuddy and identified domestic TRAE sources cannot gain interactive controls', () => {
  const { store, apply } = setup();
  for (const agent of ['workbuddy', 'trae_ide_cn', 'traework_cn']) {
    apply('session_start', { sessionId: `${agent}-same`, agentType: agent });
    for (const type of ['permission_request', 'question', 'plan_review'] as const) {
      for (const agentType of [agent, undefined, 'claude_code']) {
        const result = apply(type, { sessionId: `${agent}-same`, agentType }, `${agent}-${type}-${String(agentType)}`);
        assert.equal(result.accepted, false);
        assert.ok(result.cancelRequestIds.length > 0);
      }
    }
  }
  assert.ok(store.snapshot().sessions.every(session => session.pendingInteractions.length === 0));
});

test('rejected mirrors do not mutate ownership and foreign child events cannot attach', () => {
  const { apply, store } = setup(); apply('session_start', { sessionId: 'claude_code-shared' });
  const rejected = apply('status_update', { sessionId: 'cursor-shared', agentType: 'cursor', sourceInstanceId: 'invalid' });
  assert.equal(rejected.accepted, false); assert.equal(store.snapshot().sessions[0]!.agentType, 'claude_code');
  apply('session_start', { sessionId: 'cursor-other', agentType: 'cursor' });
  assert.equal(apply('subagent_start', { sessionId: 'claude_code-shared', parentSessionId: 'cursor-other', subagentId: 'bad' }).accepted, false);
  assert.equal(store.snapshot().sessions.find(session => session.id === 'cursor-other')!.events.length, 0);
});

test('stream replacements retain native identity and replay cannot restart completed session', () => {
  const { apply, session } = setup();
  apply('session_start', { prompt: 'prompt', nativeMessageId: 'user-1' });
  apply('status_update', { status: 'hello', nativeMessageId: 'answer-1', nativeMessagePartial: true, statusIsAssistantReply: true });
  apply('status_update', { status: 'hello world', nativeMessageId: 'answer-1', statusIsAssistantReply: true });
  const id = session().chatHistory[1]!.id; assert.equal(session().chatHistory.length, 2);
  apply('session_end', { observedState: 'completed', statusIsAssistantReply: false });
  apply('status_update', { status: 'historic update', nativeMessageId: 'answer-1', nativeMessageReplay: true, observedState: 'active' });
  assert.equal(session().status, 'completed'); assert.equal(session().chatHistory[1]!.id, id);
  apply('session_start', { prompt: 'prompt', nativeMessageId: 'user-1' }); assert.equal(session().status, 'completed');
});

test('late tool results and Stop preserve terminal state, fresh tool resumes', () => {
  const { apply, session } = setup();
  apply('tool_start', { tool: 'Read', toolCallId: 'read-1' });
  apply('session_end', { observedState: 'completed' }); const endedAt = session().completedAt;
  apply('tool_complete', { tool: 'Read', toolCallId: 'read-1', toolResult: 'late' });
  apply('status_update', { observedState: 'completionUnconfirmed', statusIsAssistantReply: false });
  assert.equal(session().status, 'completed'); assert.equal(session().completedAt, endedAt);
  apply('tool_start', { tool: 'Read', toolCallId: 'read-1' }); assert.equal(session().status, 'completed');
  apply('tool_start', { tool: 'Write', toolCallId: 'write-2' }); assert.equal(session().status, 'active'); assert.equal(session().completedAt, undefined);
});

test('tool completion with unrelated ID or missing name cannot end pending tool', () => {
  const { apply, session } = setup(); apply('tool_start', { tool: 'Read', toolCallId: 'a' });
  apply('tool_complete', { toolCallId: 'b', toolResult: 'different' });
  apply('tool_complete', { toolResult: 'unnamed' });
  assert.equal(session().events[0]!.isComplete, false); assert.equal(session().events.length, 3);
});

test('child identity, provisional finality and unrelated parent stay isolated', () => {
  const { apply, session, store } = setup();
  apply('session_start');
  assert.equal(apply('subagent_start', { parentSessionId: 'absent', subagentId: 'child' }).accepted, false);
  apply('subagent_start', { subagentId: 'child' }); apply('subagent_start', { subagentId: 'child' });
  apply('subagent_end', { subagentEndIsProvisional: true }); assert.equal(session().events[0]!.completionUnconfirmed, false);
  apply('subagent_end', { subagentId: 'child', subagentEndIsProvisional: true });
  assert.equal(session().events[0]!.isComplete, false); assert.deepEqual(session().subagentIds, ['child']);
  apply('status_update', { observedState: 'completionUnconfirmed', statusIsAssistantReply: false });
  assert.equal(session().events[0]!.completionUnconfirmed, true);
  apply('subagent_end', { subagentId: 'child' });
  assert.equal(session().events[0]!.isComplete, true); assert.equal(session().subagentIds.length, 0); assert.equal(store.snapshot().sessions.length, 1);
});

test('cumulative usage never doubles or regresses and incremental total is replacement', () => {
  const { apply, session } = setup();
  for (const tokensIn of [100, 100, 50]) apply('status_update', { tokensIn, tokensOut: 30, totalTokens: 130, costUSD: 0.3, usageIsCumulative: true });
  assert.deepEqual(session().usage, { inputTokens: 100, outputTokens: 30, totalTokens: 130, costUSD: 0.3, model: '' });
  apply('status_update', { tokensIn: 5, totalTokens: 135, costUSD: 0.01 });
  assert.equal(session().usage.inputTokens, 105); assert.equal(session().usage.totalTokens, 135);
});

test('separate child session joins its known parent without linking a foreign agent', () => {
  const { apply, store } = setup(); apply('session_start');
  apply('subagent_start', { subagentId: 'claude_code-child' });
  apply('session_start', { sessionId: 'claude_code-child' });
  apply('session_start', { sessionId: 'codex-child', agentType: 'codex', parentSessionId: 'claude_code-main' });
  assert.equal(store.snapshot().sessions.find(session => session.id === 'claude_code-child')!.parentSessionId, 'claude_code-main');
  assert.equal(store.snapshot().sessions.find(session => session.id === 'codex-child')!.parentSessionId, undefined);
});

test('approval is scoped to a live channel and only resolves after successful confirmation', () => {
  const { store, apply, session } = setup();
  assert.equal(apply('permission_request').accepted, false);
  apply('permission_request', { nativeRequestId: 'native', tool: 'Bash' }, 'pipe-1');
  const request = session().pendingInteractions[0]!;
  const prepared = store.prepareResponse(session().id, request.id, { kind: 'permission', approved: false }); assert.ok(prepared);
  assert.equal(prepared.transportRequestId, 'pipe-1'); assert.equal(session().pendingInteractions[0]!.phase, 'sending');
  assert.equal(store.prepareResponse(session().id, request.id, { kind: 'permission', approved: true }), null);
  assert.equal(store.confirmResponse(request.id, true), true); assert.equal(session().pendingInteractions.length, 0);
  assert.equal(store.confirmResponse(request.id, true), false);
  assert.equal(apply('permission_request', { nativeRequestId: 'native' }, 'pipe-2').accepted, false);
});

test('replacement cancels old request and stale confirmation cannot approve replacement', () => {
  const { store, apply, session } = setup(); apply('permission_request', {}, 'old'); const old = session().pendingInteractions[0]!;
  store.prepareResponse(session().id, old.id, { kind: 'permission', approved: true });
  const result = apply('permission_request', {}, 'new'); assert.deepEqual(result.cancelRequestIds, ['old']);
  assert.equal(store.confirmResponse(old.id, true), false);
  assert.equal(session().pendingInteractions[0]!.transportRequestId, 'new');
});

test('failed delivery, expiration and transport end never auto-approve or allow retry', () => {
  const { store, apply, session, advance } = setup();
  apply('permission_request', {}, 'failed'); let request = session().pendingInteractions[0]!;
  store.prepareResponse(session().id, request.id, { kind: 'permission', approved: true }); store.confirmResponse(request.id, false, 'broken');
  assert.equal(session().pendingInteractions[0]!.error, 'broken'); assert.equal(store.prepareResponse(session().id, request.id, { kind: 'permission', approved: true }), null);
  apply('permission_request', {}, 'expired'); request = session().pendingInteractions[0]!;
  advance(300_000); assert.deepEqual(store.expire(), ['expired']); assert.equal(session().pendingInteractions[0]!.phase, 'failed');
  apply('permission_request', {}, 'disconnected'); request = session().pendingInteractions[0]!;
  assert.equal(store.endTransport('disconnected'), true); assert.equal(store.prepareResponse(session().id, request.id, { kind: 'permission', approved: true }), null);
});

test('native tool activity and foreign resolutions cannot clear unrelated interactions', () => {
  const { apply, session } = setup();
  apply('permission_request', { nativeRequestId: 'p', nativeRequestKind: 'permission' }, 'p');
  apply('question', { questionText: 'Choose', options: ['A'], nativeRequestId: 'q', nativeRequestKind: 'question' }, 'q');
  apply('tool_start', { tool: 'Read', toolCallId: 'tool' }); assert.equal(session().pendingInteractions.length, 2);
  assert.equal(apply('interaction_resolved', { nativeRequestId: 'q', nativeRequestKind: 'permission' }).accepted, false);
  apply('interaction_resolved', { nativeRequestId: 'p', nativeRequestKind: 'permission' });
  assert.equal(session().pendingInteractions.length, 1); assert.equal(session().status, 'waitingAnswer');
});

test('free text is explicit, UTF-8 bounded and rejects empty/NUL input', () => {
  const { apply, session, store } = setup();
  apply('question', { questionText: '输入', options: [], allowsCustomAnswer: true }, 'custom');
  const request = session().pendingInteractions[0]!;
  for (const answer of ['', '  ', '\0', '中'.repeat(2731)]) assert.equal(store.prepareResponse(session().id, request.id, { kind: 'question', answer }), null);
  assert.ok(store.prepareResponse(session().id, request.id, { kind: 'question', answer: 'C:\\项目' }));
  apply('question', { questionText: '请选择', options: ['A'] }, 'fixed'); const fixed = session().pendingInteractions[0]!;
  assert.equal(store.prepareResponse(session().id, fixed.id, { kind: 'question', answer: 'other' }), null);
});

test('multi-select validates UTF-8 total, custom capability and stable selection order', () => {
  const { apply, store, session } = setup();
  apply('question', { questionText: '多选', options: ['A', 'B'], allowsMultipleAnswers: true, allowsCustomAnswer: true }, 'multi');
  const request = session().pendingInteractions[0]!;
  for (const values of [[], ['A', 'A'], ['custom', 'other'], ['中'.repeat(2731)]]) assert.equal(acceptsAnswers(request, values), false);
  assert.equal(store.prepareResponse(session().id, request.id, { kind: 'question', answer: 'A' }), null);
  const prepared = store.prepareResponse(session().id, request.id, { kind: 'question', selectedAnswers: ['B', 'A', '自定义'] });
  assert.deepEqual(prepared?.response.type === 'question_response' ? prepared.response.selectedAnswers : null, ['A', 'B', '自定义']);
});

test('sequential questions sharing native ID receive distinct local tokens and channels', () => {
  const { apply, store, session } = setup();
  for (const [index, option] of ['A', 'B'].entries()) {
    apply('question', { questionText: `[${index + 1}/2] Same`, options: [option], nativeRequestId: 'batch' }, `batch-${index}`);
    const request = session().pendingInteractions[0]!;
    assert.ok(store.prepareResponse(session().id, request.id, { kind: 'question', answer: option }));
    store.confirmResponse(request.id, true);
  }
  assert.equal(session().pendingInteractions.length, 0);
  apply('question', { questionText: 'Same', options: ['A'], nativeRequestId: 'another' }, 'another');
  assert.equal(session().pendingInteractions.length, 1);
});

test('history round trip preserves finality and strips live transport credentials', () => {
  const { store, apply, session } = setup(); apply('session_start', { prompt: 'history' });
  apply('permission_request', { nativeRequestId: 'p' }, 'secret-channel');
  const serialized = store.serialize(); assert.ok(!serialized.includes('secret-channel'));
  const restored = new SessionStore({ now: () => epoch }); restored.restore(serialized);
  const request = restored.snapshot().sessions[0]!.pendingInteractions[0]!;
  assert.equal(request.phase, 'failed'); assert.equal(request.transportRequestId, undefined);
  assert.equal(restored.prepareResponse(session().id, request.id, { kind: 'permission', approved: true }), null);
  assert.throws(() => restored.restore('{"version":1,"sessions":[{}]}'));
  assert.equal(restored.snapshot().sessions[0]!.prompt, 'history');
});

test('closed history cannot be revived by late results after restore or dismissal', () => {
  const { apply, store, session, message } = setup(); apply('session_start'); apply('session_end', { observedState: 'completed' });
  const restored = new SessionStore({ now: () => epoch }); restored.restore(store.serialize());
  restored.apply(message('tool_complete', { tool: 'Read', toolResult: 'late' })); assert.equal(restored.snapshot().sessions[0]!.status, 'completed');
  assert.equal(store.dismiss(session().id), true); assert.equal(store.apply(message('tool_complete')).accepted, false);
  assert.equal(store.apply(message('session_start', { prompt: 'new activity' })).accepted, true);
});

test('restored running history remains unconfirmed until fresh business events', () => {
  const { apply, store, message } = setup(); apply('session_start', { prompt: 'previously running' });
  assert.equal(JSON.parse(store.serialize()).sessions[0].status, 'active');
  const restored = new SessionStore({ now: () => epoch }); restored.restore(store.serialize());
  assert.equal(restored.snapshot().sessions[0]!.status, 'observationUnavailable');
  restored.expire(); assert.equal(restored.snapshot().sessions[0]!.status, 'observationUnavailable');
  restored.apply(message('status_update', { status: 'replay', nativeMessageReplay: true }));
  assert.equal(restored.snapshot().sessions[0]!.status, 'observationUnavailable');
  restored.apply(message('tool_start', { tool: 'Read', toolCallId: 'fresh' }));
  assert.equal(restored.snapshot().sessions[0]!.status, 'active');
});

test('all existing app JSON fixtures load atomically with explicit preview channels', () => {
  const { store } = setup();
  for (const name of ['permission-smoke', 'question-smoke', 'question-custom', 'question-focus', 'plan-smoke', 'session-list', 'empty-interaction', 'update-available']) {
    store.loadFixture(fixture(`app/${name}.json`));
    for (const session of store.snapshot().sessions) for (const request of session.pendingInteractions) assert.ok(request.transportRequestId?.startsWith('preview:'));
  }
  store.loadFixture(fixture('app/session-list.json')); const before = store.snapshot().sessions;
  assert.throws(() => store.loadFixture({ sessions: [{}] })); assert.deepEqual(store.snapshot().sessions, before);
});

test('compiled observer fixture reproduces two isolated unavailable sessions without completing them', () => {
  const source = fixture('companion/observation-events.json') as { messages: DIMessage[] };
  const wall = Math.max(...source.messages.map(message => Date.parse(message.timestamp)));
  const store = new SessionStore({ now: () => wall, monotonicNow: () => 0 });
  for (const message of source.messages) assert.equal(store.apply(message).accepted, true, message.type);
  assert.equal(store.snapshot().sessions.length, 2);
  for (const session of store.snapshot().sessions) {
    assert.equal(session.status, 'observationUnavailable'); assert.equal(session.completedAt, undefined); assert.equal(session.nativeTaskId, '同一任务/😀');
  }
  const restored = new SessionStore({ now: () => wall, monotonicNow: () => 0 }); restored.restore(store.serialize());
  assert.equal(restored.apply({ ...source.messages[0], observationSequence: 99 }).accepted, false, 'ended source cannot reopen after history restore');
});

test('observation sequence, age, source and expiration cannot be bypassed', () => {
  const { store, advance } = setup();
  const sourceId = 'roo_code-0123456789abcdef01234567-00000000-0000-4000-8000-000000000001';
  const message: DIMessage = { type: 'session_start', agentType: 'roo_code', sessionId: taskSessionId(sourceId, '任务/😀'),
    nativeTaskId: '任务/😀', sourceNamespace: '0123456789abcdef01234567', sourceInstanceId: '00000000-0000-4000-8000-000000000001',
    observationSequence: 1, timestamp: new Date(epoch).toISOString() };
  assert.equal(store.apply(message).accepted, true); assert.equal(store.apply(message).accepted, false);
  assert.equal(store.apply({ ...message, observationSequence: 2, sessionId: 'wrong' }).accepted, false);
  assert.equal(store.apply({ type: 'status_update', sessionId: message.sessionId, timestamp: message.timestamp, status: 'forged' }).accepted, false);
  advance(31_000); store.expire(); assert.equal(store.snapshot().sessions[0]!.status, 'observationUnavailable');
  const heartbeat = { ...message, type: 'observation_heartbeat' as const, sessionId: sourceId, nativeTaskId: undefined, observationSequence: 2, timestamp: new Date(epoch + 31_000).toISOString() };
  assert.equal(store.apply(heartbeat).accepted, true); assert.equal(store.snapshot().sessions[0]!.status, 'observationUnavailable');
  assert.equal(store.apply({ ...message, observationSequence: 3, timestamp: heartbeat.timestamp }).accepted, true); assert.equal(store.snapshot().sessions[0]!.status, 'active');
  assert.equal(store.apply({ ...heartbeat, type: 'observation_ended', observationSequence: 4 }).accepted, true);
  assert.equal(store.apply({ ...message, observationSequence: 5, timestamp: heartbeat.timestamp }).accepted, false);
});

test('malformed cross-source child and unsafe sequence rejected without advancing ledger', () => {
  const ledger = new ObservationLedger();
  const source = 'roo_code-0123456789abcdef01234567-00000000-0000-4000-8000-000000000001';
  const sessionId = taskSessionId(source, 'parent');
  const base: DIMessage = { type: 'subagent_start', agentType: 'roo_code', sessionId, parentSessionId: sessionId,
    nativeTaskId: 'parent', sourceNamespace: '0123456789abcdef01234567', sourceInstanceId: '00000000-0000-4000-8000-000000000001',
    observationSequence: 1, timestamp: new Date(epoch).toISOString(), subagentId: taskSessionId(source, 'child') };
  assert.equal(ledger.accept({ ...base, subagentId: taskSessionId('foreign', 'child') }, 0, epoch).kind, 'rejected');
  assert.equal(ledger.accept({ ...base, observationSequence: Number.MAX_SAFE_INTEGER + 1 }, 0, epoch).kind, 'rejected');
  assert.equal(ledger.accept(base, 0, epoch).kind, 'event');
});
