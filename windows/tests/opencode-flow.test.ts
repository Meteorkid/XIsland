import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createServer, type Socket } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { pathToFileURL } from 'node:url';
import { normalizeOpenCodeHook, openCodeHookResponse } from '../src/adapters/opencode';
import { SessionStore } from '../src/core/session-store';
import type { ApplyResult, InteractionDecision } from '../src/core/types';
import { openCodePluginSource } from '../src/integrations/opencode-plugin';

type Data = Record<string, unknown>;
interface NativeHooks {
  dispose(): Promise<void>;
  event(input: { event: { type: string; properties: Data } }): Promise<void>;
}
interface BridgeEvent { payload: Data; result: ApplyResult; transportRequestId?: string }

async function until(check: () => boolean): Promise<void> {
  const deadline = Date.now() + 5000;
  while (!check()) {
    assert.ok(Date.now() < deadline, 'isolated OpenCode flow did not reach expected state');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}

/** 隔离合成合同：真实生成插件与 Node 子进程接入单一 Store；不连接 OpenCode 或 Windows 原生层。 */
async function fixture(t: TestContext) {
  const directory = await mkdtemp(join(tmpdir(), 'xisland-opencode-flow-'));
  const store = new SessionStore({ ownerInstanceId: 'opencode-flow-test' });
  const events: BridgeEvent[] = [], errors: unknown[] = [];
  const calls: { method: string; input: Data }[] = [];
  const connections = new Set<Socket>();
  const expectedDisconnects = new WeakSet<Socket>();
  const channels = new Map<string, { socket: Socket; payload: Data }>();
  let sequence = 0;
  const server = createServer(socket => {
    connections.add(socket);
    socket.setEncoding('utf8');
    let input = '', transportRequestId: string | undefined;
    socket.on('close', () => {
      connections.delete(socket);
      if (transportRequestId && channels.delete(transportRequestId)) store.endTransport(transportRequestId);
    });
    socket.on('error', error => {
      if ((error as NodeJS.ErrnoException).code === 'ECONNRESET' && expectedDisconnects.has(socket)) return;
      errors.push(error);
    });
    socket.on('data', chunk => {
      input += chunk;
      if (!input.includes('\n')) return;
      socket.removeAllListeners('data');
      try {
        const payload: Data = JSON.parse(input.trim());
        const message = normalizeOpenCodeHook(payload);
        const interactive = message.type === 'permission_request' || message.type === 'question';
        transportRequestId = interactive ? `flow-${++sequence}` : undefined;
        if (transportRequestId) channels.set(transportRequestId, { socket, payload });
        const result = store.apply(message, transportRequestId ? { requestId: transportRequestId, expiresAt: Date.now() + 120000 } : undefined);
        events.push({ payload, result, transportRequestId });
        for (const requestId of result.cancelRequestIds) {
          const cancelled = channels.get(requestId);
          if (cancelled) {
            channels.delete(requestId);
            cancelled.socket.end(JSON.stringify(openCodeHookResponse(cancelled.payload, null)) + '\n');
          }
        }
        if (!interactive) socket.end(JSON.stringify(openCodeHookResponse(payload, null)) + '\n');
      } catch (error) {
        errors.push(error);
        socket.end(JSON.stringify({ stdout: '', exitCode: 1 }) + '\n');
      }
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => { server.off('error', reject); resolve(); });
  });
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  const hook = join(directory, 'isolated-hook.mjs');
  await writeFile(hook, `import { createConnection } from 'node:net';
let input = ''; for await (const chunk of process.stdin) input += chunk;
const socket = createConnection({ host: '127.0.0.1', port: ${address.port} });
socket.setEncoding('utf8');
socket.on('error', () => process.exit(1));
socket.on('connect', () => socket.write(input + '\\n'));
let output = ''; for await (const chunk of socket) output += chunk;
const response = JSON.parse(output);
process.stdout.write(response.stdout);
process.exitCode = response.exitCode;
`);
  const plugin = join(directory, 'plugin.mjs');
  await writeFile(plugin, openCodePluginSource(process.execPath, hook));
  const capture = (method: string) => async (input: Data) => { calls.push({ method, input }); return { data: true }; };
  const module = await import(pathToFileURL(plugin).href);
  const hooks: NativeHooks = await module.default({ directory: 'C:\\隔离工作区', client: {
    permission: { reply: capture('permission.reply') }, question: { reply: capture('question.reply') },
  } });
  t.after(async () => {
    for (const socket of connections) expectedDisconnects.add(socket);
    await hooks.dispose();
    for (const socket of connections) socket.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
    assert.deepEqual(errors, []);
  });
  const emit = (type: string, properties: Data) => {
    // 原生已回答会主动终止对应桥接子进程；Windows 可对这条连接返回 reset。
    if (type === 'permission.replied') {
      for (const { socket, payload } of channels.values()) {
        if (payload.session_id === properties.sessionID && payload.native_request_id === properties.requestID) {
          expectedDisconnects.add(socket);
        }
      }
    }
    return hooks.event({ event: { type, properties } });
  };
  const seen = (type: string) => events.filter(event => event.payload.native_event === type);
  const pending = (sessionID: string) => store.snapshot().sessions.find(session => session.id === `opencode-${sessionID}`)?.pendingInteractions ?? [];
  const respond = async (sessionID: string, decision: InteractionDecision) => {
    const request = pending(sessionID)[0];
    assert.ok(request, `missing interaction for ${sessionID}`);
    const prepared = store.prepareResponse(`opencode-${sessionID}`, request.id, decision);
    assert.ok(prepared, `invalid response for ${sessionID}`);
    const channel = channels.get(prepared.transportRequestId);
    assert.ok(channel, 'response must use the live request channel');
    const response = openCodeHookResponse(channel.payload, prepared.response);
    channels.delete(prepared.transportRequestId);
    await new Promise<void>(resolve => channel.socket.end(JSON.stringify(response) + '\n', () => {
      assert.equal(store.confirmResponse(prepared.interactionId, true), true);
      resolve();
    }));
  };
  const fail = (sessionID: string) => {
    const request = pending(sessionID)[0];
    assert.ok(request?.transportRequestId);
    const channel = channels.get(request.transportRequestId);
    assert.ok(channel);
    assert.equal(store.endTransport(request.transportRequestId, 'isolated transport failure'), true);
    channels.delete(request.transportRequestId);
    channel.socket.end(JSON.stringify(openCodeHookResponse(channel.payload, null)) + '\n');
  };
  return { store, events, calls, emit, seen, pending, respond, fail };
}

const branch = { question: '选择分支', options: [{ label: 'main' }, { label: 'dev' }], custom: false };
const question = (id: string, questions: Data[] = [branch]) => ({ id, sessionID: 'ses_1', questions });
const permission = (id: string, sessionID: string) => ({ id, sessionID, permission: 'bash', patterns: ['npm test'], metadata: {}, always: [] });

test('isolated OpenCode flow handles two queued questions in one SessionStore without blocking the second', async t => {
  const f = await fixture(t);
  await f.emit('question.asked', question('que_first'));
  await f.emit('question.asked', question('que_second'));
  await until(() => f.seen('question.asked').length === 1);
  assert.equal(f.pending('ses_1')[0]?.nativeRequestId, 'que_first');
  assert.equal(f.calls.length, 0);
  await f.respond('ses_1', { kind: 'question', answer: 'main' });
  await until(() => f.seen('question.asked').length === 2);
  assert.equal(f.seen('question.asked')[1]?.result.accepted, true);
  assert.equal(f.pending('ses_1')[0]?.nativeRequestId, 'que_second');
  await f.respond('ses_1', { kind: 'question', answer: 'dev' });
  await until(() => f.calls.length === 2);
  assert.deepEqual(f.calls.map(call => call.input), [
    { requestID: 'que_first', directory: 'C:\\隔离工作区', answers: [['main']] },
    { requestID: 'que_second', directory: 'C:\\隔离工作区', answers: [['dev']] },
  ]);
  assert.deepEqual(f.pending('ses_1'), []);
  assert.equal(f.store.snapshot().sessions.length, 1);
});

test('isolated OpenCode flow preserves every answer row through generated plugin, adapter and SessionStore', async t => {
  const f = await fixture(t);
  await f.emit('question.asked', question('que_batch', [branch,
    { question: '选择功能', options: [{ label: 'A' }, { label: 'B' }], multiple: true, custom: true },
    { question: '补充说明', options: [], custom: true },
  ]));
  const decisions: InteractionDecision[] = [
    { kind: 'question', answer: 'dev' },
    { kind: 'question', selectedAnswers: ['B', 'A', '自定义😀'] },
    { kind: 'question', answer: '中文自由文本' },
  ];
  for (const [index, decision] of decisions.entries()) {
    await until(() => f.seen('question.asked').length === index + 1);
    const event = f.seen('question.asked')[index]!;
    assert.equal(event.result.accepted, true, event.result.reason);
    assert.equal(event.payload.native_request_id, 'que_batch');
    assert.equal(f.pending('ses_1').length, 1);
    assert.equal(f.calls.length, 0, 'SDK must wait for every question');
    await f.respond('ses_1', decision);
  }
  await until(() => f.calls.length === 1);
  assert.deepEqual(f.calls[0], { method: 'question.reply', input: { requestID: 'que_batch', directory: 'C:\\隔离工作区',
    answers: [['dev'], ['A', 'B', '自定义😀'], ['中文自由文本']] } });
  const requests = f.seen('question.asked');
  assert.deepEqual(requests.map(event => event.payload.question), ['[1/3] 选择分支', '[2/3] 选择功能', '[3/3] 补充说明']);
  assert.equal(new Set(requests.map(event => event.transportRequestId)).size, 3);
  assert.deepEqual(f.pending('ses_1'), []);
});

test('isolated OpenCode native permission resolution cannot answer another session or the next queued request', async t => {
  const f = await fixture(t);
  await f.emit('permission.asked', permission('shared', 'session_a'));
  await f.emit('permission.asked', permission('next', 'session_a'));
  await f.emit('permission.asked', permission('shared', 'session_b'));
  await until(() => f.seen('permission.asked').length === 2);
  const otherRequest = f.pending('session_b')[0]!.id;
  await f.emit('permission.replied', { sessionID: 'session_a', requestID: 'shared' });
  await until(() => f.seen('permission.asked').length === 3);
  assert.equal(f.pending('session_a')[0]?.nativeRequestId, 'next');
  assert.equal(f.pending('session_b')[0]?.id, otherRequest);
  await f.emit('permission.replied', { sessionID: 'session_a', requestID: 'shared' });
  assert.equal(f.pending('session_a')[0]?.nativeRequestId, 'next');
  assert.equal(f.pending('session_b')[0]?.id, otherRequest);
  assert.equal(f.calls.length, 0);
  await f.respond('session_a', { kind: 'permission', approved: false });
  await f.respond('session_b', { kind: 'permission', approved: true });
  await until(() => f.calls.length === 2);
  assert.deepEqual(f.calls.map(call => call.input).sort((a, b) => String(a.requestID).localeCompare(String(b.requestID))), [
    { requestID: 'next', directory: 'C:\\隔离工作区', reply: 'reject' },
    { requestID: 'shared', directory: 'C:\\隔离工作区', reply: 'once' },
  ]);
  assert.deepEqual(f.pending('session_a'), []);
  assert.deepEqual(f.pending('session_b'), []);
});

test('isolated OpenCode partial question failure never submits a complete SDK result', async t => {
  const f = await fixture(t);
  await f.emit('question.asked', question('que_partial', [branch, branch]));
  await until(() => f.seen('question.asked').length === 1);
  await f.respond('ses_1', { kind: 'question', answer: 'main' });
  await until(() => f.seen('question.asked').length === 2);
  assert.equal(f.seen('question.asked')[1]?.result.accepted, true);
  f.fail('ses_1');
  await until(() => f.seen('interaction.unavailable').length === 1);
  assert.equal(f.calls.length, 0);
  assert.deepEqual(f.pending('ses_1'), []);
  const session = f.store.snapshot().sessions[0]!;
  assert.equal(session.status, 'waitingAnswer');
  assert.equal(session.statusText, '请在 OpenCode 中继续处理此请求。');
  assert.deepEqual(f.events.slice(-2).map(event => event.payload.native_event), ['interaction.resolved', 'interaction.unavailable']);
});
