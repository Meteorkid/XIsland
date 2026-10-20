import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test, { type TestContext } from 'node:test';
import { isOwnedPiPlugin, piPluginPath, piPluginSource } from '../src/integrations/pi-plugin';
import { normalizePiHook, PI_HOOK_EVENTS } from '../src/adapters/pi';
import { SessionStore } from '../src/core';

type Data = Record<string, unknown>;
interface RecordedEvent { payload: Data; argv: string[] }
type Handler = (event: Data, context: Data) => Promise<unknown>;

async function fixture(t: TestContext, mode: 'normal' | 'failure' | 'hang' = 'normal') {
  const directory = await mkdtemp(join(tmpdir(), 'xisland-pi-plugin-'));
  const log = join(directory, 'events.jsonl'), hook = join(directory, '中文 hook $(unused) &.mjs');
  await writeFile(log, '');
  await writeFile(hook, `import {appendFileSync} from 'node:fs';
let input = ''; for await (const chunk of process.stdin) input += chunk;
appendFileSync(${JSON.stringify(log)},JSON.stringify({payload:JSON.parse(input),argv:process.argv.slice(2)})+'\\n');
if (${JSON.stringify(mode)} === 'hang') setInterval(() => {}, 1000);
else if (${JSON.stringify(mode)} === 'failure') process.exit(9);
else process.stdout.write(JSON.stringify({ decision: 'allow', answer: 'untrusted' }));
`);
  const plugin = join(directory, 'plugin.mjs'); await writeFile(plugin, piPluginSource(process.execPath, hook));
  const handlers = new Map<string, Handler>();
  (await import(pathToFileURL(plugin).href)).default({ on: (name: string, handler: Handler) => {
    assert.equal(handlers.has(name), false); handlers.set(name, handler);
  } });
  const context: Data = { sessionManager: { getSessionId: () => 'native-session' }, cwd: 'C:\\中文项目', model: { id: 'exact/model-id', name: 'Display name' }, isIdle: () => true };
  const events = async (): Promise<RecordedEvent[]> => (await readFile(log, 'utf8')).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  const emit = (name: string, event: Data = {}, override: Data = {}) => handlers.get(name)!(event, { ...context, ...override });
  t.after(async () => { await emit('session_shutdown', { reason: 'quit' }); await rm(directory, { recursive: true, force: true }); });
  return { handlers, events, emit };
}

test('Pi path and exact source ownership support native Windows and guarded custom agent directories', () => {
  assert.equal(piPluginPath('C:\\Users\\Tester'), 'C:\\Users\\Tester\\.pi\\agent\\extensions\\xisland.ts');
  assert.equal(piPluginPath('/home/test', { PI_CODING_AGENT_DIR: '/home/test/custom' }), join('/home/test/custom', 'extensions', 'xisland.ts'));
  assert.throws(() => piPluginPath('/home/test', { PI_CODING_AGENT_DIR: 'relative' }));
  const source = piPluginSource('C:\\Program Files\\XIsland\\node.exe', 'C:\\Program Files\\XIsland\\xisland-hook.cjs');
  assert.equal(isOwnedPiPlugin(source), true); assert.equal(isOwnedPiPlugin(source.replace(/\n/g, '\r\n')), true);
  for (const changed of [source + '// user edit', source.replace('1500', '2500'), '\ufeff' + source, source.trim()]) assert.equal(isOwnedPiPlugin(changed), false);
  assert.throws(() => piPluginSource('node', '/tmp/hook.cjs'));
  assert.throws(() => piPluginSource('/node\n', '/tmp/hook.cjs'));
});

test('Pi generated plugin runs actual Node child processes and replays all eight events through SessionStore', async t => {
  const { handlers, events, emit } = await fixture(t);
  assert.deepEqual([...handlers.keys()], [...PI_HOOK_EVENTS]);
  const samples: [string, Data][] = [
    ['session_start', { reason: 'new' }], ['before_agent_start', { messageType: 'user', prompt: '检查中文文件' }],
    ['agent_start', {}], ['tool_execution_start', { toolName: 'read', toolCallId: 'call-1', args: { path: '中文.txt' } }],
    ['tool_execution_end', { toolName: 'read', toolCallId: 'call-1', result: { content: [{ type: 'text', text: 'ok' }] }, isError: false }],
    ['agent_end', {}], ['agent_settled', {}], ['session_shutdown', { reason: 'quit' }],
  ];
  const store = new SessionStore();
  for (const [native, data] of samples) {
    assert.equal(await emit(native, data), undefined);
    const recorded = (await events()).at(-1)!;
    assert.deepEqual(recorded.argv, ['--agent', 'pi', '--hook', native]);
    const message = normalizePiHook(recorded.payload, { hookEventName: native });
    assert.equal(message.model, 'exact/model-id'); store.apply(message);
    if (native === 'agent_end') assert.equal(store.snapshot().sessions[0]!.status, 'active');
    if (native === 'agent_settled') assert.equal(store.snapshot().sessions[0]!.status, 'idle');
  }
  assert.equal((await events()).length, 8);
  assert.equal(store.snapshot().sessions[0]!.status, 'completed');
  assert.equal(store.snapshot().sessions[0]!.pendingInteractions.length, 0);
  await emit('session_shutdown'); await emit('agent_start'); assert.equal((await events()).length, 8);
});

test('Pi never reports idle while the host has resumed and serializes concurrent tool observations', async t => {
  const { events, emit } = await fixture(t);
  await emit('agent_settled', {}, { isIdle: () => false }); assert.equal((await events()).length, 0);
  await Promise.all([
    emit('tool_execution_start', { toolName: 'read', toolCallId: 'a', args: {} }),
    emit('tool_execution_end', { toolName: 'read', toolCallId: 'a', result: 'ok', isError: false }),
    emit('agent_end'),
  ]);
  assert.deepEqual((await events()).map(item => item.payload.native_event), ['tool_execution_start', 'tool_execution_end', 'agent_end']);
});

test('Pi cancelled runs still deliver terminal observations; invalid native ids and oversized payloads do not spawn', async t => {
  const { events, emit } = await fixture(t);
  const controller = new AbortController(); controller.abort();
  await emit('agent_start', {}, { signal: controller.signal });
  await emit('tool_execution_start', { toolName: '', toolCallId: 'call' });
  await emit('session_start', {}, { sessionManager: { getSessionId: () => 'bad\0' } });
  await emit('session_start', {}, { sessionManager: { getSessionId: () => { throw new Error('unavailable'); } } });
  await emit('before_agent_start', { prompt: 'x'.repeat(16 * 1024 * 1024) });
  const circular: Data = {}; circular.self = circular;
  await emit('tool_execution_start', { toolName: 'read', toolCallId: 'call', args: circular });
  assert.equal((await events()).length, 0);
  await emit('agent_end', {}, { signal: controller.signal });
  await emit('agent_settled', {}, { signal: controller.signal });
  assert.deepEqual((await events()).map(item => item.payload.native_event), ['agent_end', 'agent_settled']);
});

test('Pi bridge errors and timeout remain notification-only and never override native handlers', async t => {
  const failed = await fixture(t, 'failure'); assert.equal(await failed.emit('agent_start'), undefined);
  const stalled = await fixture(t, 'hang');
  const start = Date.now(); assert.equal(await stalled.emit('agent_start'), undefined);
  assert.ok(Date.now() - start < 3500);
});
