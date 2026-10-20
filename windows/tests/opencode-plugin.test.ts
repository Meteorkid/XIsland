import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test, { type TestContext } from 'node:test';
import { isOwnedOpenCodePlugin, openCodePluginPath, openCodePluginSource } from '../src/integrations/opencode-plugin';
import { normalizeOpenCodeHook } from '../src/adapters/opencode';

type Data = Record<string, unknown>;
interface RecordedEvent { payload: Data; argv: string[] }
interface NativeHooks {
  dispose(): Promise<void>;
  event(input: { event: { type: string; properties: Data } }): Promise<void>;
  'chat.message'(input: Data, output: Data): Promise<void>;
  'tool.execute.before'(input: Data, output: Data): Promise<void>;
  'tool.execute.after'(input: Data, output: Data): Promise<void>;
}
interface FixtureOptions {
  sdk?: 'v1' | 'v2' | 'raw' | 'missing';
  choices?: Record<string, unknown>;
  delay?: number;
  mode?: 'exit' | 'invalid' | 'utf8' | 'large';
  replyResult?: unknown;
  replyFails?: boolean;
}

async function until(check: () => boolean | Promise<boolean>): Promise<void> {
  const deadline = Date.now() + 5000;
  while (!await check()) {
    assert.ok(Date.now() < deadline, 'isolated plugin did not reach expected state');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}

/** 真正执行生成插件和 Node 子进程；SDK 只连接隔离替身，不操作用户 OpenCode。 */
async function fixture(t: TestContext, options: FixtureOptions = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'xisland-opencode-plugin-'));
  const log = join(directory, 'events.jsonl'), hook = join(directory, '测试 hook.mjs');
  await writeFile(log, '');
  const configuration = { choices: options.choices ?? {}, delay: options.delay ?? 0, mode: options.mode };
  await writeFile(hook, `import { appendFileSync, readFileSync } from 'node:fs';
const config = ${JSON.stringify(configuration)}, log = ${JSON.stringify(log)};
let input = ''; for await (const chunk of process.stdin) input += chunk;
const payload = JSON.parse(input);
appendFileSync(log, JSON.stringify({payload, argv:process.argv.slice(2)})+'\\n');
const interactive = ['permission.asked','question.asked'].includes(payload.native_event);
if (interactive) {
  if (config.delay) await new Promise(resolve => setTimeout(resolve, config.delay));
  if (config.mode === 'exit') process.exit(1);
  if (config.mode === 'invalid') { process.stdout.write('{'); process.exit(0); }
  if (config.mode === 'utf8') { process.stdout.write(Buffer.from([0xc3,0x28])); process.exit(0); }
  if (config.mode === 'large') { process.stdout.write('x'.repeat(1024*1024+1)); process.exit(0); }
}
let choice = config.choices[payload.native_request_id];
if (Array.isArray(choice)) {
  const count = readFileSync(log,'utf8').trim().split('\\n').map(JSON.parse).filter(item => item.payload.native_event === payload.native_event && item.payload.session_id === payload.session_id && item.payload.native_request_id === payload.native_request_id).length;
  choice = choice[count-1];
}
process.stdout.write(JSON.stringify(interactive ? choice ?? {decision:'deny'} : {}));
`);
  const plugin = join(directory, 'plugin.mjs');
  await writeFile(plugin, openCodePluginSource(process.execPath, hook));
  const calls: { method: string; input: Data; options?: Data }[] = [];
  const capture = (method: string) => async (input: Data, callOptions?: Data) => {
    calls.push({ method, input, options: callOptions });
    if (options.replyFails) throw new Error('isolated SDK failure');
    return options.replyResult === undefined ? { data: true } : options.replyResult;
  };
  const sdk = options.sdk ?? 'v2';
  const client = sdk === 'v2' ? { permission: { reply: capture('permission.reply') }, question: { reply: capture('question.reply') } }
    : sdk === 'v1' ? { postSessionIdPermissionsPermissionId: capture('legacy.permission'), _client: { post: capture('transport.post') } }
      : sdk === 'raw' ? { _client: { post: capture('transport.post') } } : {};
  const module = await import(pathToFileURL(plugin).href);
  const hooks: NativeHooks = await module.default({ client, directory: 'C:\\原始工作区' });
  t.after(async () => { await hooks.dispose(); await rm(directory, { recursive: true, force: true }); });
  const events = async (): Promise<RecordedEvent[]> => (await readFile(log, 'utf8')).trim().split('\n').filter(Boolean).map(value => JSON.parse(value));
  const emit = (type: string, properties: Data) => hooks.event({ event: { type, properties } });
  const hasEvent = async (type: string) => (await events()).some(item => item.payload.native_event === type);
  return { hooks, events, emit, calls, hasEvent };
}

const permission = (id = 'per_1', sessionID = 'ses_1') => ({ id, sessionID, permission: 'bash', patterns: ['npm test'], metadata: {}, always: [] });
const question = (id = 'que_1', sessionID = 'ses_1', fields: Data = {}) => ({ id, sessionID,
  questions: [{ header: 'Branch', question: '选哪个分支？', options: [{ label: 'main', description: '默认分支' }, { label: 'dev', description: '开发分支' }], custom: false }], ...fields });

test('OpenCode generator validates absolute paths and preserves Windows quoting as JavaScript data', () => {
  const node = 'C:\\XIsland 空格\\node.exe', hook = 'D:\\工具\\hook "literal" & $(stay).cjs';
  const source = openCodePluginSource(node, hook);
  assert.ok(source.includes(`const NODE = ${JSON.stringify(node)};`));
  assert.ok(source.includes(`const HOOK = ${JSON.stringify(hook)};`));
  assert.match(source, /shell: false, windowsHide: true/); assert.equal(source.includes('--adapter'), false);
  assert.equal(isOwnedOpenCodePlugin(source.replace(/\n/g, '\r\n')), true);
  assert.equal(isOwnedOpenCodePlugin('// user-owned\n' + source), false);
  assert.equal(isOwnedOpenCodePlugin(source + '\n// user extension\n'), false);
  assert.equal(isOwnedOpenCodePlugin(source.replace('once', 'always')), false);
  assert.equal(isOwnedOpenCodePlugin(source.replace('const NODE =', 'const NODE_BAD =')), false);
  for (const path of ['relative', '', '/bad\0path', 'C:\\bad\npath']) assert.throws(() => openCodePluginSource(path, hook));
  assert.equal(openCodePluginPath('C:\\Users\\测试'), 'C:\\Users\\测试\\.config\\opencode\\plugins\\xisland.js');
  assert.equal(openCodePluginPath('/tmp/home'), join('/tmp/home', '.config', 'opencode', 'plugins', 'xisland.js'));
  assert.equal(openCodePluginPath('/tmp/home', { XDG_CONFIG_HOME: '/tmp/config' }), join('/tmp/config', 'opencode', 'plugins', 'xisland.js'));
  assert.equal(openCodePluginPath('/tmp/home', { XDG_CONFIG_HOME: 'relative' }), join('/tmp/home', '.config', 'opencode', 'plugins', 'xisland.js'));
  assert.equal(openCodePluginPath('\\\\server\\share\\home'), '\\\\server\\share\\home\\.config\\opencode\\plugins\\xisland.js');
});

test('generated OpenCode plugin sends real subprocess observations in order without changing native tools', async t => {
  const f = await fixture(t);
  await f.emit('session.created', { info: { id: 'ses_1', directory: 'D:\\显示目录', time: {} } });
  await f.hooks['chat.message']({ sessionID: 'ses_1', model: { modelID: 'model' } }, { parts: [
    { type: 'text', text: '第一段' }, { type: 'text', text: 'synthetic', synthetic: true }, { type: 'text', text: '第二段' },
  ] });
  const input = { tool: 'bash', sessionID: 'ses_1', callID: 'call_1' }, output = { args: { command: 'npm test' } };
  await f.hooks['tool.execute.before'](input, output);
  await f.hooks['tool.execute.after']({ ...input, args: output.args }, { output: 'passed' });
  await f.emit('session.status', { sessionID: 'ses_1', status: { type: 'idle' } });
  const events = await f.events();
  assert.deepEqual(events.map(item => item.payload.native_event), ['session.created', 'prompt.submitted', 'tool.started', 'tool.completed', 'session.idle']);
  assert.equal(events[1]!.payload.prompt, '第一段\n第二段'); assert.equal(events[1]!.payload.model, 'model');
  for (const item of events) {
    assert.equal(item.payload.cwd, 'D:\\显示目录'); normalizeOpenCodeHook(item.payload);
    assert.deepEqual(item.argv, ['--agent', 'opencode', '--hook', item.payload.native_event]);
  }
  assert.deepEqual(output, { args: { command: 'npm test' } }); assert.equal(f.calls.length, 0);
});

test('OpenCode permissions use typed SDK once/reject without persisting always and preserve injected directory', async t => {
  const f = await fixture(t, { choices: { per_1: { decision: 'allow' }, per_2: { decision: 'deny' } } });
  await f.emit('session.created', { info: { id: 'ses_1', directory: 'D:\\显示目录' } });
  await f.emit('permission.asked', permission());
  await f.emit('permission.asked', permission('per_2'));
  await until(() => f.calls.length === 2);
  assert.deepEqual(f.calls.map(item => item.input), [
    { requestID: 'per_1', directory: 'C:\\原始工作区', reply: 'once' },
    { requestID: 'per_2', directory: 'C:\\原始工作区', reply: 'reject' },
  ]);
  assert.ok(f.calls.every(item => item.options?.throwOnError === true && item.options.signal instanceof AbortSignal));
  const events = await f.events();
  assert.deepEqual(events.filter(item => item.payload.native_event === 'permission.asked').map(item => item.payload.native_request_id), ['per_1', 'per_2']);
});

test('OpenCode official injected v1 SDK uses session-scoped permission method and original question transport', async t => {
  const f = await fixture(t, { sdk: 'v1', choices: { que_1: { answer: 'dev' } } });
  await f.emit('permission.asked', permission()); await until(() => f.calls.length === 1);
  assert.equal(f.calls[0]!.method, 'legacy.permission');
  assert.deepEqual(f.calls[0]!.input.path, { id: 'ses_1', permissionID: 'per_1' });
  assert.deepEqual(f.calls[0]!.input.query, { directory: 'C:\\原始工作区' });
  assert.deepEqual(f.calls[0]!.input.body, { response: 'reject' });
  await f.emit('question.asked', question()); await until(() => f.calls.length === 2);
  const request = f.calls[1]!.input;
  assert.equal(request.url, '/question/{requestID}/reply'); assert.deepEqual(request.path, { requestID: 'que_1' });
  assert.deepEqual(request.query, { directory: 'C:\\原始工作区' }); assert.deepEqual(request.body, { answers: [['dev']] });
  assert.equal(request.throwOnError, true); assert.ok(request.signal instanceof AbortSignal);
});

test('OpenCode multi-question answers retain one native request ID and ordered SDK arrays', async t => {
  const f = await fixture(t, { choices: { que_1: [{ answer: 'dev' }, { answers: ['A', '自定义😀'] }, { answer: '自由文本' }] } });
  await f.emit('question.asked', question('que_1', 'ses_1', { questions: [
    question().questions[0],
    { question: '选择功能', options: [{ label: 'A' }, { label: 'B' }], multiple: true },
    { question: '补充说明', options: [], custom: true },
  ] }));
  await until(() => f.calls.length === 1);
  assert.deepEqual(f.calls[0]!.input, { requestID: 'que_1', directory: 'C:\\原始工作区', answers: [['dev'], ['A', '自定义😀'], ['自由文本']] });
  const events = (await f.events()).filter(item => item.payload.native_event === 'question.asked');
  assert.equal(events.length, 3); assert.ok(events.every(item => item.payload.native_request_id === 'que_1' && item.payload.native_request_kind === 'question'));
  assert.deepEqual(events.map(item => item.payload.question), ['[1/3] 选哪个分支？', '[2/3] 选择功能', '[3/3] 补充说明']);
  assert.equal(events[1]!.payload.allow_multiple_answers, true);
});

test('OpenCode invalid or partial multi-question answers never submit a partial SDK reply', async t => {
  const f = await fixture(t, { choices: { que_1: [{ answer: 'main' }, { answer: 'unknown' }] } });
  await f.emit('question.asked', question('que_1', 'ses_1', { questions: [question().questions[0], question().questions[0]] }));
  await until(() => f.hasEvent('interaction.unavailable'));
  assert.equal(f.calls.length, 0);
  const events = await f.events();
  assert.deepEqual(events.slice(-2).map(item => item.payload.native_event), ['interaction.resolved', 'interaction.unavailable']);
});

test('OpenCode unsupported or failed SDK replies return processing to native client', async t => {
  for (const options of [{ sdk: 'missing' as const }, { replyFails: true }, { replyResult: { data: false } },
    { replyResult: { data: undefined } }, { replyResult: { data: true, error: 'failed' } }]) {
    const f = await fixture(t, options);
    await f.emit('permission.asked', permission());
    await until(() => f.hasEvent('interaction.unavailable'));
    assert.equal((await f.events()).at(-1)!.payload.native_request_id, 'per_1');
    assert.equal(f.calls.length, options.sdk === 'missing' ? 0 : 1);
    assert.equal((await f.events()).some(item => item.payload.native_event === 'session.idle'), false);
  }
});

test('OpenCode malformed native questions and invalid selections remain in the original client', async t => {
  for (const fields of [{ questions: [] }, { questions: [null] }, { questions: [{ question: 'q', options: [{ label: 'x' }, { label: 'x' }] }] },
    { questions: [{ question: 'q', options: [], custom: false }] }, { questions: [{ question: 'q', options: [{ label: 'x' }], multiple: 1 }] }]) {
    const f = await fixture(t);
    await f.emit('question.asked', question('que_1', 'ses_1', fields));
    await until(() => f.hasEvent('interaction.unavailable'));
    assert.equal(await f.hasEvent('question.asked'), false); assert.equal(f.calls.length, 0);
  }
  for (const choice of [{ answers: ['main', 'main'] }, { answers: ['custom1', 'custom2'] }, { answer: 'main' }]) {
    const f = await fixture(t, { choices: { que_1: choice } });
    await f.emit('question.asked', question('que_1', 'ses_1', { questions: [{ ...question().questions[0], multiple: true, custom: true }] }));
    await until(() => f.hasEvent('interaction.unavailable')); assert.equal(f.calls.length, 0);
  }
});

test('OpenCode bridge crashes, malformed bytes and oversized output never call the SDK', async t => {
  for (const mode of ['exit', 'invalid', 'utf8', 'large'] as const) {
    const f = await fixture(t, { mode });
    await f.emit('permission.asked', permission());
    await until(() => f.hasEvent('interaction.unavailable'));
    assert.equal(f.calls.length, 0);
  }
});

test('native replies cancel only the same session/request identity and do not echo another decision', async t => {
  const f = await fixture(t, { delay: 1000, choices: { per_1: { decision: 'allow' } } });
  await f.emit('permission.asked', permission()); await until(() => f.hasEvent('permission.asked'));
  await f.emit('permission.replied', { sessionID: 'other_session', requestID: 'per_1' });
  await f.emit('permission.replied', { sessionID: 'ses_1', requestID: 'other_request' });
  await f.emit('session.status', { sessionID: 'ses_1', status: { type: 'idle' } });
  assert.equal((await f.events()).some(item => item.payload.native_event === 'session.idle'), false);
  await f.emit('permission.replied', { sessionID: 'ses_1', requestID: 'per_1' });
  await until(() => f.hasEvent('session.idle'));
  assert.equal(f.calls.length, 0);
  await f.emit('permission.asked', permission());
  await f.hooks.dispose();
  assert.equal((await f.events()).filter(item => item.payload.native_event === 'permission.asked').length, 1);
});

test('OpenCode identical request IDs remain independent across sessions and event duplicates submit once', async t => {
  const f = await fixture(t);
  await f.emit('permission.asked', permission('shared', 'session_a'));
  await f.emit('permission.asked', permission('shared', 'session_a'));
  await f.emit('permission.asked', permission('shared', 'session_b'));
  await until(() => f.calls.length === 2);
  await f.emit('permission.asked', permission('shared', 'session_a'));
  await f.hooks.dispose();
  const requests = (await f.events()).filter(item => item.payload.native_event === 'permission.asked');
  assert.deepEqual(requests.map(item => item.payload.session_id).sort(), ['session_a', 'session_b']);
  assert.equal(f.calls.length, 2);
});

test('a late native resolution for an old request cannot cancel the next queued request', async t => {
  const f = await fixture(t, { delay: 250, choices: { per_1: { decision: 'allow' }, per_2: { decision: 'deny' } } });
  await f.emit('permission.asked', permission());
  await f.emit('permission.asked', permission('per_2'));
  await until(() => f.hasEvent('permission.asked'));
  await f.emit('permission.replied', { sessionID: 'ses_1', requestID: 'per_1' });
  await until(async () => (await f.events()).some(item => item.payload.native_event === 'permission.asked' && item.payload.native_request_id === 'per_2'));
  await f.emit('permission.replied', { sessionID: 'ses_1', requestID: 'per_1' });
  await until(() => f.calls.length === 1);
  assert.deepEqual(f.calls[0]!.input, { requestID: 'per_2', directory: 'C:\\原始工作区', reply: 'reject' });
});

test('OpenCode deleted and archived sessions cancel waiting work and cannot reopen through late requests', async t => {
  for (const archive of [false, true]) {
    const f = await fixture(t, { delay: 1000 });
    await f.emit('question.asked', question()); await until(() => f.hasEvent('question.asked'));
    await f.emit(archive ? 'session.updated' : 'session.deleted', { info: { id: 'ses_1', time: archive ? { archived: 1 } : {} } });
    await f.emit('question.asked', question('que_2'));
    await f.hooks.dispose();
    const events = await f.events();
    assert.equal(events.filter(item => item.payload.native_event === 'question.asked').length, 1);
    assert.equal(events.at(-1)!.payload.native_event, 'session.deleted'); assert.equal(f.calls.length, 0);
  }
});

test('OpenCode dispose cancels visible requests and rejects later work without approving', async t => {
  const f = await fixture(t, { delay: 1000 });
  await f.emit('permission.asked', permission()); await until(() => f.hasEvent('permission.asked'));
  await f.hooks.dispose();
  await f.emit('permission.asked', permission('per_2')); await f.hooks['tool.execute.before']({ sessionID: 'ses_1', callID: 'late', tool: 'bash' }, { args: {} });
  assert.deepEqual((await f.events()).map(item => item.payload.native_event), ['permission.asked', 'interaction.resolved']);
  assert.equal(f.calls.length, 0);
});

test('OpenCode assistant text is emitted once only for completed nonsynthetic assistant parts', async t => {
  const f = await fixture(t);
  await f.emit('message.updated', { info: { id: 'msg_1', role: 'assistant' } });
  const part = { type: 'text', sessionID: 'ses_1', messageID: 'msg_1', id: 'part_1', text: '完成😀', time: { end: 1 } };
  await f.emit('message.part.updated', { part: { ...part, time: {} } });
  await f.emit('message.part.updated', { part: { ...part, synthetic: true } });
  await f.emit('message.part.updated', { part }); await f.emit('message.part.updated', { part });
  await f.emit('message.part.updated', { part: { type: 'tool', sessionID: 'ses_1', callID: 'call', tool: 'bash', state: { status: 'error', input: {}, error: 'exit 1' } } });
  await f.emit('session.compacted', { sessionID: 'ses_1' });
  const events = await f.events();
  assert.deepEqual(events.map(item => item.payload.native_event), ['assistant.message', 'tool.failed', 'session.compacted']);
  assert.equal(normalizeOpenCodeHook(events[0]!.payload).statusIsAssistantReply, true);
});
