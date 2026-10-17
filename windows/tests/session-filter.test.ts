import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeClaudeHook } from '../src/adapters/claude';
import { normalizeOpenCodeHook } from '../src/adapters/opencode';
import { SessionStore } from '../src/core/session-store';
import { GLM_MODEL_FILTER, isGLMModel, matchesSessionFilters, buildFilteredSessionTree } from '../src/core/session-filter';
import type { Session } from '../src/core/types';

const all = { agent: 'all', status: 'all', query: '' };
const glm = { ...all, agent: GLM_MODEL_FILTER };
function session(id: string, model = 'glm-5.3', patch: Partial<Session> = {}): Session {
  return { id, agentType: 'claude_code', status: 'active', prompt: '', statusText: '', agentResponse: '',
    workingDirectory: 'C:\\project', startedAt: 0, lastActivityAt: 0, subagentIds: [], events: [], chatHistory: [],
    pendingInteractions: [], backgroundTasks: [], usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0, costUSD: 0, model }, ...patch };
}

test('GLM model recognition preserves every macOS positive and negative case', () => {
  for (const value of ['glm', 'GLM-5.3', 'glm-4.7-flash', 'z-ai/glm-5', 'openrouter/z-ai/glm-5.2', 'glm-5.2[1m]', 'glm4.7']) assert.equal(isGLMModel(value), true, value);
  for (const value of ['', 'sonnet', 'zai/sonnet', 'my-glm-agent', 'glm client', 'glm-5\nextra', 'glm-', `glm${'x'.repeat(300)}`]) assert.equal(isGLMModel(value), false, value);
  assert.equal(isGLMModel(' \tGLM-5.3\r\n'), true);
  assert.equal(isGLMModel(`glm-${'a'.repeat(252)}`), true);
  assert.equal(isGLMModel(`glm-${'a'.repeat(253)}`), false);
  assert.equal(isGLMModel(` \t${'a'.repeat(252)}/glm\n`), true);
  for (const value of ['glm-5\nextra', 'glm-5\0', 'glm-模型', `glm-${'é'.repeat(127)}`, `glm-${'😀'.repeat(64)}`]) assert.equal(isGLMModel(value), false, value);
});

test('model filter trusts the model only and intersects client, status and search criteria', () => {
  const row = session('same', 'z-ai/GLM-5.3', { status: 'thinking' });
  assert.equal(matchesSessionFilters(row, glm, ''), true);
  assert.equal(matchesSessionFilters(session('alias', 'sonnet', { agentType: 'glm' }), glm, 'GLM'), false);
  assert.equal(matchesSessionFilters(session('empty', '', { agentType: 'zai' }), glm, ''), false);
  assert.equal(matchesSessionFilters(row, { ...glm, status: 'active', query: 'GLM-5.3' }, 'Project A'), true);
  assert.equal(matchesSessionFilters(row, { ...glm, status: 'idle' }, 'Project A'), false);
  assert.equal(matchesSessionFilters(row, { ...all, agent: 'opencode', query: 'glm' }, ''), false);
  assert.equal(matchesSessionFilters(row, { ...all, agent: 'claude_code', query: 'Z-AI/glm' }, ''), true);
  assert.equal(matchesSessionFilters(row, { ...all, query: 'PROJECT a' }, 'Project A Claude Code Reading'), true);
  assert.equal(matchesSessionFilters(row, { ...all, query: 'Reading' }, 'Project A Claude Code Reading'), true);
  assert.equal(matchesSessionFilters(row, { ...all, query: 'other' }, 'Project A'), false);
  assert.equal(matchesSessionFilters(row, { ...glm, status: 'pending' }, ''), false);
});

test('native Claude and OpenCode retain identities and models through history and model changes', () => {
  const timestamp = '2026-10-17T00:00:00Z';
  const store = new SessionStore({ now: () => Date.parse(timestamp) });
  const claude = normalizeClaudeHook({ hook_event_name: 'SessionStart', session_id: 'shared', cwd: 'C:\\project', model: 'glm-5.3' }, { timestamp });
  const openCode = normalizeOpenCodeHook({ native_event: 'session.created', session_id: 'shared', cwd: 'C:\\project', model: 'glm-5.3' }, { timestamp });
  for (const message of [claude, openCode]) assert.equal(store.apply(message).accepted, true);
  const matches = () => store.snapshot().sessions.filter(row => matchesSessionFilters(row, glm, ''));
  assert.deepEqual(matches().map(row => row.agentType).sort(), ['claude_code', 'opencode']);
  assert.equal(store.snapshot().sessions.filter(row => matchesSessionFilters(row, { ...all, agent: 'opencode' }, '')).length, 1);
  store.restore(store.serialize());
  assert.equal(matches().length, 2);
  assert.equal(store.apply({ ...openCode, model: 'other-model' }).accepted, true);
  assert.deepEqual(matches().map(row => row.agentType), ['claude_code']);
  assert.equal(store.snapshot().sessions.length, 2);
  assert.equal(store.snapshot().sessions.find(row => row.id === openCode.sessionId)?.agentType, 'opencode');
});

test('matching children survive filtered parents and tree expansion excludes unmatched children', () => {
  const records = [session('parent', 'other'), session('child', 'glm-5.3', { parentSessionId: 'parent' }),
    session('grandchild', 'glm-5.3', { parentSessionId: 'child' }), session('hidden', 'other', { parentSessionId: 'child' })];
  const before = structuredClone(records);
  const tree = buildFilteredSessionTree(records.filter(row => matchesSessionFilters(row, glm, '')));
  assert.deepEqual(tree.roots.map(node => node.session.id), ['child']);
  assert.deepEqual(tree.roots[0]!.children.map(node => node.session.id), ['grandchild']);
  assert.deepEqual(records, before);
  assert.deepEqual(buildFilteredSessionTree([records[2]!]).roots.map(node => node.session.id), ['grandchild']);
});

test('pending parents do not hide regular children and malformed cycles remain visible', () => {
  const parent = session('pending');
  parent.pendingInteractions.push({ id: 'request', kind: 'permission', phase: 'pending', options: [], allowsCustomAnswer: false, allowsMultipleAnswers: false });
  const tree = buildFilteredSessionTree([parent, session('child', 'glm', { parentSessionId: parent.id })]);
  assert.deepEqual(tree.pending.map(row => row.id), ['pending']);
  assert.deepEqual(tree.roots.map(node => node.session.id), ['child']);
  const cycles = buildFilteredSessionTree([session('self', 'glm', { parentSessionId: 'self' }),
    session('a', 'glm', { parentSessionId: 'b' }), session('b', 'glm', { parentSessionId: 'a' })]);
  assert.deepEqual(cycles.roots.map(node => node.session.id), ['self', 'a', 'b']);
  assert.ok(cycles.roots.every(node => node.children.length === 0));
});
