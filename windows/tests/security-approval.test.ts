import assert from 'node:assert/strict';
import test from 'node:test';
import { ClaudeHookError, claudeHookResponse, normalizeClaudeHook } from '../src/adapters/claude';
import { codexHookResponse, normalizeCodexHook } from '../src/adapters/codex';
import { qwenHookResponse, normalizeQwenHook } from '../src/adapters/qwen';
import { SessionStore } from '../src/core/session-store';
import { ProtocolError, type DIMessage } from '../src/core/protocol';

const now = Date.parse('2026-10-18T00:00:00Z');
const timestamp = new Date(now).toISOString();
const command = "printf 'approval-evidence\\n'";
const input = { description: '只读检查项目，安全可执行', command, extra: { text: '<img src=x onerror=alert(1)>', values: ['保留', 2] } };
const payload = (fields: Record<string, unknown>) => ({ hook_event_name: 'PermissionRequest', session_id: 'approval', tool_name: 'Bash', ...fields });
const normalizers = [['Claude', normalizeClaudeHook], ['Codex', normalizeCodexHook]] as const;

function pending(message: DIMessage) {
  const store = new SessionStore({ now: () => now });
  assert.equal(store.apply(message, { requestId: 'live', expiresAt: now + 60_000 }).accepted, true);
  return { store, request: store.snapshot().sessions[0]!.pendingInteractions[0]! };
}

for (const [name, normalize] of normalizers) {
  for (const alias of ['tool_input', 'input', 'parameters', 'params', 'args', 'tool.input']) {
    for (const encoded of [false, true]) {
      test(`${name} permission ${alias} ${encoded ? 'JSON string' : 'object'} exposes command and retains all input`, () => {
        const value = encoded ? JSON.stringify(input, null, 2) : input;
        const fields = alias === 'tool.input' ? { tool: { input: value } } : { [alias]: value };
        const message = normalize(payload(fields), { timestamp });
        const { request } = pending(message);
        assert.equal(message.permDescription, command);
        assert.equal(request.description, command);
        assert.deepEqual(JSON.parse(request.toolInput!), input);
        if (encoded) assert.equal(request.toolInput, value);
      });
    }
  }
  for (const alias of ['tool_input', 'input', 'parameters', 'params', 'args']) {
    test(`${name} permission ${alias} plain text remains visible despite a friendly description`, () => {
      const { request } = pending(normalize(payload({ [alias]: command, description: input.description }), { timestamp }));
      assert.equal(request.description, command);
      assert.equal(request.toolInput, command);
    });
  }
  for (const alias of ['tool_input', 'input', 'parameters', 'params', 'args', 'tool.input']) {
    for (const [shape, value] of [
      ['plain text', input.description],
      ['array', [input.description, input.extra]],
      ['JSON array', JSON.stringify([input.description, input.extra], null, 2)],
      ['object', { description: input.description, extra: input.extra }],
      ['JSON object', JSON.stringify({ description: input.description, extra: input.extra }, null, 2)],
      ['empty command', { description: input.description, command: '' }],
      ['non-string command', { description: input.description, command: ['friendly'] }],
    ] as const) {
      test(`${name} top-level command retains the full envelope with ${alias} ${shape}`, () => {
        const fields = alias === 'tool.input' ? { tool: { input: value } } : { [alias]: value };
        const native = payload({ ...fields, command, description: input.description, extra: input.extra });
        const { request } = pending(normalize(native, { timestamp }));
        assert.equal(request.description, command);
        assert.deepEqual(JSON.parse(request.toolInput!), native);
      });
    }
  }
  for (const encoded of [false, true]) {
    test(`${name} selected command keeps precedence and original ${encoded ? 'JSON string' : 'object'} input`, () => {
      const value = encoded ? JSON.stringify(input, null, 2) : input;
      const { request } = pending(normalize(payload({ tool_input: value, command: 'printf top-level-command' }), { timestamp }));
      assert.equal(request.description, command);
      assert.deepEqual(JSON.parse(request.toolInput!), input);
      if (encoded) assert.equal(request.toolInput, value);
    });
  }
  test(`${name} later aliases cannot replace a primary plain-text input`, () => {
    const message = normalize(payload({ tool_input: command, input: { description: input.description, command: 'printf later-alias' } }), { timestamp });
    const { request } = pending(message);
    assert.equal(request.description, command);
    assert.equal(request.toolInput, command);
  });
  test(`${name} top-level input fallback retains every field`, () => {
    const native = payload({ command, description: input.description, extra: input.extra });
    const { request } = pending(normalize(native, { timestamp }));
    assert.equal(request.description, command);
    assert.deepEqual(JSON.parse(request.toolInput!), native);
  });
}

test('Qwen permission retains the full native object and prioritizes its command', () => {
  const message = normalizeQwenHook(payload({ tool_name: 'run_shell_command', tool_input: input }), { timestamp });
  const { request } = pending(message);
  assert.equal(request.description, command);
  assert.deepEqual(JSON.parse(request.toolInput!), input);
});

test('approval input survives history and read-only snapshots without reviving response channels', () => {
  const message = normalizeQwenHook(payload({ tool_input: input }), { timestamp });
  const { store, request } = pending(message);
  const serialized = store.serialize();
  const restored = new SessionStore({ now: () => now }); restored.restore(serialized);
  const historyRequest = restored.snapshot().sessions[0]!.pendingInteractions[0]!;
  assert.deepEqual(JSON.parse(historyRequest.toolInput!), input);
  assert.equal(historyRequest.transportRequestId, undefined);
  assert.equal(restored.prepareResponse(message.sessionId, request.id, { kind: 'permission', approved: true }), null);
  const mirror = new SessionStore({ readOnly: true, now: () => now });
  assert.equal(mirror.receiveSnapshot(store.snapshot()), true);
  const mirrorRequest = mirror.snapshot().sessions[0]!.pendingInteractions[0]!;
  assert.deepEqual(JSON.parse(mirrorRequest.toolInput!), input);
  assert.equal(mirrorRequest.transportRequestId, undefined);
  const legacy = JSON.parse(serialized); delete legacy.sessions[0].pendingInteractions[0].toolInput;
  assert.doesNotThrow(() => restored.restore(JSON.stringify(legacy)));
  for (const invalid of [null, 1, false, [], {}]) {
    const corrupt = JSON.parse(serialized); corrupt.sessions[0].pendingInteractions[0].toolInput = invalid;
    assert.throws(() => restored.restore(JSON.stringify(corrupt)), ProtocolError);
    assert.throws(() => mirror.receiveSnapshot({ ...corrupt, revision: 100, ownerInstanceId: 'new-owner' }), ProtocolError);
  }
});

test('allow, deny and no-decision native responses preserve their exact contract', () => {
  for (const [normalize, respond] of [[normalizeClaudeHook, claudeHookResponse], [normalizeCodexHook, codexHookResponse], [normalizeQwenHook, qwenHookResponse]] as const) {
    const native = payload({ tool_input: input });
    const sessionId = normalize(native, { timestamp }).sessionId;
    for (const approved of [true, false]) assert.deepEqual(respond(native, { type: 'permission_response', sessionId, timestamp, approved }), {
      stdout: JSON.stringify({ hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: approved ? 'allow' : 'deny' } } }), exitCode: 0,
    });
    assert.deepEqual(respond(native, null), { stdout: '{}', exitCode: 0 });
    assert.throws(() => respond(native, { type: 'permission_response', sessionId: 'different-session', timestamp, approved: true }));
  }
});

test('Windows Claude does not fabricate an answer for a second question', () => {
  const native = payload({ tool_name: 'AskUserQuestion', tool_input: { questions: [
    { question: '第一题', options: [{ label: 'A' }] }, { question: '第二题', options: [{ label: 'B' }] },
  ] } });
  assert.throws(() => normalizeClaudeHook(native, { timestamp }), error => error instanceof ClaudeHookError && error.code === 'unsupported_question');
  assert.throws(() => claudeHookResponse(native, { type: 'question_response', sessionId: 'claude_code-approval', timestamp, answer: 'A' }), ClaudeHookError);
  const single = (question: string, label: string) => payload({ tool_name: 'AskUserQuestion', tool_input: { question, options: [label] } });
  const first = normalizeClaudeHook(single('第一题', 'A'), { timestamp });
  const { store, request } = pending(first);
  assert.ok(store.prepareResponse(first.sessionId, request.id, { kind: 'question', answer: 'A' }));
  assert.equal(store.confirmResponse(request.id, true), true);
  assert.equal(store.apply(normalizeClaudeHook(single('第二题', 'B'), { timestamp }), { requestId: 'second', expiresAt: now + 60_000 }).accepted, true);
  const second = store.snapshot().sessions[0]!.pendingInteractions[0]!;
  assert.equal(second.phase, 'pending'); assert.equal(second.text, '第二题');
  assert.equal(second.transportRequestId, 'second');
  // 第一题完成不会自行完成或回传第二题。
  assert.equal(store.snapshot().sessions[0]!.pendingInteractions.length, 1);
});
