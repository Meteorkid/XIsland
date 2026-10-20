import assert from 'node:assert/strict';
import test from 'node:test';
import { SessionStore } from '../src/core/session-store';
import { messageReservation, SESSION_BUDGET } from '../src/core/session-budget';
import { utf8Length, type DIMessage } from '../src/core/protocol';
import type { Session, StoreSnapshot } from '../src/core/types';
import { taskSessionId } from '../src/core/observation';

const now = Date.parse('2026-10-18T00:00:00Z');
const message = (type: DIMessage['type'], extra: Partial<DIMessage> = {}): DIMessage => ({
  type, sessionId: 'claude_code-capacity', agentType: 'claude_code', timestamp: new Date(now).toISOString(), ...extra });
const store = () => new SessionStore({ now: () => now, ownerInstanceId: 'capacity-owner' });
function history(events: number, padding = '', sessions = 1): string {
  const seed = store(); seed.apply(message('session_start'));
  const row = JSON.parse(seed.serialize()).sessions[0] as Session;
  row.status = 'completed'; row.completedAt = now; row.recapText = padding;
  row.events = Array.from({ length: events }, (_, index) => ({ id: `event-${index}`, toolCallId: `call-${index}`, tool: 'Read',
    input: '文件😀', result: `result-${index}`, timestamp: now, isComplete: index !== events - 1, completionUnconfirmed: false }));
  return JSON.stringify({ version: 1, sessions: Array.from({ length: sessions }, (_, index) => ({ ...row, id: index ? `other-${index}` : row.id })) });
}

test('one immutable detached snapshot is shared by all listeners for each revision and old snapshots stay stable', () => {
  const owner = store(); const received: StoreSnapshot[][] = [[], [], []];
  for (const rows of received) owner.subscribe(snapshot => rows.push(snapshot));
  owner.apply(message('session_start', { prompt: 'original' }));
  const first = owner.snapshot();
  assert.equal(received[0]![1], first); assert.equal(received[1]![1], first); assert.equal(received[2]![1], first);
  assert.equal(owner.snapshot(), first);
  assert.throws(() => { first.sessions[0]!.chatHistory[0]!.content = 'polluted'; }, TypeError);
  assert.throws(() => { first.sessions.push(first.sessions[0]!); }, TypeError);
  owner.apply(message('status_update', { status: 'next' }));
  assert.notEqual(owner.snapshot(), first); assert.equal(first.sessions[0]!.agentResponse, '');
  assert.equal(owner.snapshot().sessions[0]!.prompt, 'original');
  const mirror = new SessionStore({ readOnly: true });
  const wire = JSON.parse(JSON.stringify(owner.snapshotForTransfer())) as StoreSnapshot;
  mirror.receiveSnapshot(wire); wire.sessions[0]!.prompt = 'mutated wire';
  assert.equal(mirror.snapshot().sessions[0]!.prompt, 'original');
  assert.throws(() => { mirror.snapshot().sessions[0]!.pendingInteractions.push({} as never); }, TypeError);
});

test('50000 events and unfinished tools survive full history and mirror recovery without pruning', () => {
  const owner = store(); owner.restore(history(50_000));
  const serialized = owner.serialize(); assert.ok(utf8Length(serialized) < SESSION_BUDGET.boundaryBytes);
  const recovered = store(); recovered.restore(serialized);
  const mirror = new SessionStore({ readOnly: true }); mirror.receiveSnapshot(owner.snapshotForTransfer());
  for (const target of [owner, recovered, mirror]) {
    const events = target.snapshot().sessions[0]!.events;
    assert.equal(events.length, 50_000); assert.equal(events[0]!.result, 'result-0');
    assert.equal(events.at(-1)!.id, 'event-49999'); assert.equal(events.at(-1)!.isComplete, false);
  }
});

test('large escaped Unicode output remains complete and repeated native replay does not accumulate records', () => {
  const owner = store(); owner.apply(message('session_start'));
  owner.apply(message('tool_start', { tool: 'Read', toolCallId: 'large' }));
  const result = '结果😀\n"'.repeat(80_000);
  assert.equal(owner.apply(message('tool_complete', { toolCallId: 'large', toolResult: result })).accepted, true);
  assert.equal(owner.snapshot().sessions[0]!.events[0]!.result, result);
  const reply = message('status_update', { nativeMessageId: 'same-reply', nativeMessageReplay: true, status: 'same' });
  for (let index = 0; index < 2000; index++) assert.equal(owner.apply(reply).accepted, true);
  assert.equal(owner.snapshot().sessions[0]!.chatHistory.length, 1);
  assert.equal(owner.snapshot().sessions[0]!.events.length, 1);
  const restored = store(); restored.restore(owner.serialize());
  assert.equal(restored.snapshot().sessions[0]!.events[0]!.result, result);
});

test('capacity rejection cancels only the incoming channel and existing approval and terminal transitions still work', () => {
  const owner = store(); owner.restore(history(0, 'a'.repeat(SESSION_BUDGET.bytes + 16_384)));
  // 模拟合法旧历史处于软阈值以上，既有审批仍可收尾。
  // restore 不恢复连接凭据；用小库创建真实审批，再把大历史放到第二个会话。
  const live = store(); live.apply(message('permission_request', { nativeRequestId: 'native', tool: 'Bash' }), { requestId: 'existing', expiresAt: now + 60_000 });
  const liveRequest = live.snapshot().sessions[0]!.pendingInteractions[0]!;
  // 累计至接近软阈值，使用已有工具的完整输出而非绕过核心私有状态。
  for (let index = 0; index < 13; index++) assert.equal(live.apply(message('tool_complete', {
    toolCallId: `bulk-${index}`, toolResult: 'x'.repeat(1024 * 1024) })).accepted, true);
  const before = live.snapshot();
  const rejected = live.apply(message('permission_request', { toolInput: 'x'.repeat(2 * 1024 * 1024) }), { requestId: 'new-channel', expiresAt: now + 60_000 });
  assert.equal(rejected.accepted, false); assert.match(rejected.reason!, /已有记录未删除/);
  assert.deepEqual(rejected.cancelRequestIds, ['new-channel']); assert.equal(live.snapshot(), before);
  assert.equal(live.snapshot().sessions[0]!.pendingInteractions[0]!.transportRequestId, 'existing');
  const prepared = live.prepareResponse(message('session_start').sessionId, liveRequest.id, { kind: 'permission', approved: false });
  assert.ok(prepared); assert.equal(live.confirmResponse(liveRequest.id, true), true);
  assert.equal(live.apply(message('session_end', { observedState: 'completed' })).accepted, true);
  assert.equal(live.snapshot().sessions[0]!.events.length, 13);
  assert.ok(utf8Length(live.serialize()) <= SESSION_BUDGET.boundaryBytes);
  const plan = live.prepareHistoryRemoval(); live.commitHistoryRemoval(plan);
  assert.equal(live.apply(message('session_start', { sessionId: 'fresh' })).accepted, true);
  assert.equal(owner.apply(message('session_end', { observedState: 'completed' })).accepted, true);
});

test('session and record count limits reject growth without deleting imported history', () => {
  const owner = store(); owner.restore(history(0, '', SESSION_BUDGET.sessions));
  assert.equal(owner.apply(message('session_start', { sessionId: 'overflow' })).accepted, false);
  assert.equal(owner.snapshot().sessions.length, SESSION_BUDGET.sessions);
  const many = store();
  const data = JSON.parse(history(0));
  data.sessions[0].chatHistory = Array.from({ length: SESSION_BUDGET.records }, (_, index) => ({ id: String(index), role: 'user', content: '', timestamp: now }));
  many.restore(JSON.stringify(data));
  const rejected = many.apply(message('tool_start', { tool: 'Read', toolCallId: 'overflow' }));
  assert.equal(rejected.accepted, false); assert.match(rejected.reason!, /100000/);
  assert.equal(many.apply(message('session_end', { observedState: 'completed' })).accepted, true);
  assert.equal(many.snapshot().sessions[0]!.chatHistory.length, SESSION_BUDGET.records);
});

test('oversized restore and mirror input fail atomically and preserve the previous complete state', () => {
  const owner = store(); owner.apply(message('session_start', { prompt: 'keep' }));
  const before = owner.snapshot(), oversized = history(0, 'z'.repeat(SESSION_BUDGET.boundaryBytes));
  assert.throws(() => owner.restore(oversized), /16 MiB/); assert.equal(owner.snapshot(), before);
  const mirror = new SessionStore({ readOnly: true }); mirror.receiveSnapshot(before);
  const oldMirror = mirror.snapshot();
  const incoming = { ...JSON.parse(oversized), ownerInstanceId: 'new-owner', revision: 100 };
  assert.throws(() => mirror.receiveSnapshot(incoming), /16 MiB/); assert.equal(mirror.snapshot(), oldMirror);
});

test('reservation bounds actual persisted and transfer growth across escaped fields and lifecycle kinds', () => {
  const cases: DIMessage[] = [message('session_start', { prompt: '😀\n"'.repeat(1000), workingDir: '目录'.repeat(500) }),
    message('tool_start', { tool: 'Read', toolCallId: 'tool', toolInput: '\\"\n'.repeat(1000) }),
    message('tool_complete', { toolCallId: 'tool', toolResult: '😀"\n'.repeat(1000) }),
    message('status_update', { status: '😀\n'.repeat(1000), nativeMessageId: 'reply' }),
    message('question', { questionText: '😀'.repeat(1000), options: ['a'.repeat(1000)], nativeRequestId: 'question' }),
    message('plan_review', { planMarkdown: '# plan\n'.repeat(1000) }), message('session_end', { status: 'done'.repeat(1000), observedState: 'completed' })];
  const owner = store();
  for (const [index, event] of cases.entries()) {
    const transport = ['question', 'plan_review'].includes(event.type) ? { requestId: `channel-${index}`, expiresAt: now + 60_000 } : undefined;
    const beforeHistory = utf8Length(owner.serialize()), beforeSnapshot = utf8Length(JSON.stringify(owner.snapshot()));
    assert.equal(owner.apply(event, transport).accepted, true);
    const growth = Math.max(utf8Length(owner.serialize()) - beforeHistory, utf8Length(JSON.stringify(owner.snapshot())) - beforeSnapshot);
    assert.ok(growth <= messageReservation(event, transport), `${event.type}: ${growth}`);
  }
});

test('heartbeat updates serialized observation sequence without invalidating the shared UI snapshot', () => {
  const owner = store(), namespace = 'a'.repeat(24), instance = '11111111-1111-4111-8111-111111111111';
  const sourceId = `roo_code-${namespace}-${instance}`;
  const base = { agentType: 'roo_code', sourceNamespace: namespace, sourceInstanceId: instance, observationSequence: 1 };
  assert.equal(owner.apply(message('session_start', { ...base, sessionId: taskSessionId(sourceId, 'task'), nativeTaskId: 'task' })).accepted, true);
  assert.equal(JSON.parse(owner.serialize()).observations[0].sequence, 1);
  const snapshot = owner.snapshot();
  assert.equal(owner.apply(message('observation_heartbeat', { ...base, sessionId: sourceId, observationSequence: 2 })).accepted, true);
  assert.equal(owner.snapshot(), snapshot);
  assert.equal(JSON.parse(owner.serialize()).observations[0].sequence, 2);
});
