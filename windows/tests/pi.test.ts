import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizePiHook, PI_HOOK_EVENTS, piHookResponse } from '../src/adapters/pi';
import { SessionStore } from '../src/core';

const timestamp = '2026-10-17T12:00:00.000Z';
const event = (native_event: string, extra = {}) => ({ native_event, session_id: 'session', cwd: 'C:\\项目', model: 'provider/model-id', ...extra });

test('Pi maps all eight native observer events and preserves model ids and tool identities', () => {
  assert.equal(PI_HOOK_EVENTS.length, 8);
  for (const native of PI_HOOK_EVENTS) {
    const message = normalizePiHook(event(native, { tool_name: 'read', tool_use_id: 'call-1', tool_input: { path: '中文.txt' } }), { timestamp, hookEventName: native });
    assert.equal(message.agentType, 'pi'); assert.equal(message.sessionId, 'pi-session');
    assert.equal(message.nativeEvent, native); assert.equal(message.timestamp, timestamp);
    assert.equal(message.model, 'provider/model-id'); assert.equal(message.statusIsAssistantReply, false);
    assert.equal(['permission_request', 'question', 'plan_review'].includes(message.type), false);
  }
  const tool = normalizePiHook(event('tool_execution_end', { tool_name: 'read', tool_use_id: 'call-1', tool_response: { content: [{ type: 'text', text: '中文' }] }, native_status: 'error' }));
  assert.equal(tool.observedState, 'error'); assert.equal(tool.toolCallId, 'call-1'); assert.match(tool.toolResult!, /中文/);
  assert.equal(normalizePiHook(event('before_agent_start', { prompt: '继续' })).prompt, '继续');
});

test('Pi requires matching event routing, usable native session ids, and complete tool identities', () => {
  for (const value of [null, [], {}, event('unknown'), event('agent_start', { session_id: '' }), event('agent_start', { model: 1 }),
    event('agent_start', { session_id: 'bad\0' }), event('tool_execution_start'),
    event('tool_execution_end', { tool_name: 'read', tool_use_id: ' ', native_status: 'done' }),
    event('tool_execution_end', { tool_name: 'read', tool_use_id: 'call-1', native_status: 'unknown' })]) {
    assert.throws(() => normalizePiHook(value));
  }
  assert.throws(() => normalizePiHook(event('agent_settled'), { hookEventName: 'agent_end' }));
  assert.deepEqual(piHookResponse(event('agent_settled'), null), { stdout: '', exitCode: 0 });
  assert.deepEqual(piHookResponse(null, null), { stdout: '', exitCode: 0 });
  assert.throws(() => piHookResponse(event('agent_start'), { type: 'permission_response', approved: true, sessionId: 'pi-session', timestamp }));
});

test('Pi real SessionStore keeps agent_end active, settled idle and shutdown completed', () => {
  const store = new SessionStore();
  const apply = (native: string, data = {}) => store.apply(normalizePiHook(event(native, data)));
  apply('session_start'); apply('before_agent_start', { prompt: '检查文件' }); apply('agent_start');
  apply('tool_execution_start', { tool_name: 'read', tool_use_id: 'one', tool_input: { path: 'file' } });
  apply('tool_execution_end', { tool_name: 'read', tool_use_id: 'one', tool_response: 'ok', native_status: 'done' });
  apply('agent_end');
  assert.equal(store.snapshot().sessions[0]!.status, 'active');
  assert.equal(store.snapshot().sessions[0]!.completedAt, undefined);
  apply('agent_start'); apply('agent_end'); apply('agent_settled');
  assert.equal(store.snapshot().sessions[0]!.status, 'idle');
  assert.equal(store.snapshot().sessions[0]!.completedAt, undefined);
  apply('session_shutdown');
  const session = store.snapshot().sessions[0]!;
  assert.equal(session.status, 'completed'); assert.ok(session.completedAt);
  assert.equal(session.usage.model, 'provider/model-id'); assert.equal(session.pendingInteractions.length, 0);
});
