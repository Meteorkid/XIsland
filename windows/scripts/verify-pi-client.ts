import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { piPluginSource } from '../src/integrations/pi-plugin';
import { normalizePiHook, PI_HOOK_EVENTS } from '../src/adapters/pi';
import { SessionStore } from '../src/core';
import { parseDIMessage } from '../src/core/protocol';

// 使用已下载的官方 CLI；不安装依赖、不读取真实 home、凭据、信任或项目设置。
// npx tsx scripts/verify-pi-client.ts --cli /absolute/dist/bundle/cli.js --node /absolute/node --report /absolute/report.json
const argument = (flag: string) => {
  const index = process.argv.indexOf(flag); return index < 0 ? undefined : process.argv[index + 1];
};
const cli = argument('--cli'), node = argument('--node') ?? process.execPath, output = argument('--report');
const bundledHook = argument('--bundled-hook');
const switchSession = process.argv.includes('--switch-session');
if (!cli || !isAbsolute(cli) || !isAbsolute(node) || output && !isAbsolute(output) || bundledHook && !isAbsolute(bundledHook)) {
  throw new Error('Require absolute --cli, --node and optional --report/--bundled-hook paths');
}
const home = await realpath(await mkdtemp(join(tmpdir(), 'xisland-pi-client-')));
const workspace = join(home, 'workspace'), agent = join(home, '.pi', 'agent'), log = join(home, 'events.jsonl');
const messageLog = join(home, 'messages.jsonl'), hookLog = join(home, 'hook-results.jsonl');
const modelRequests: { method?: string; url?: string; toolResults: number }[] = [];
const server = createServer(async (request, response) => {
  try {
    let input = ''; for await (const chunk of request) input += chunk;
    assert.equal(request.method, 'POST'); assert.equal(request.url, '/v1/chat/completions');
    const payload = JSON.parse(input), results = payload.messages.filter((item: { role: string }) => item.role === 'tool');
    modelRequests.push({ method: request.method, url: request.url, toolResults: results.length });
    assert.ok(modelRequests.length <= (switchSession ? 4 : 2), 'Unexpected retry loop');
    const hasToolResult = results.length > 0;
    if (hasToolResult) assert.ok(JSON.stringify(results).includes('isolated Pi fixture'));
    response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
    const chunk = (delta: unknown, finish_reason: string | null = null) => response.write(`data: ${JSON.stringify({
      id: 'chatcmpl-fixture', object: 'chat.completion.chunk', created: 1, model: 'observer-model',
      choices: [{ index: 0, delta, finish_reason }],
    })}\n\n`);
    chunk({ role: 'assistant' });
    if (hasToolResult) { chunk({ content: 'Isolated verification complete.' }); chunk({}, 'stop'); }
    else {
      chunk({ tool_calls: [{ index: 0, id: 'call-local-read', type: 'function', function: { name: 'read', arguments: JSON.stringify({ path: join(workspace, 'fixture.txt') }) } }] });
      chunk({}, 'tool_calls');
    }
    response.end('data: [DONE]\n\n');
  } catch { response.writeHead(500); response.end('local fixture assertion failed'); }
});
try {
  await mkdir(workspace); await mkdir(join(agent, 'extensions'), { recursive: true });
  await writeFile(join(workspace, 'fixture.txt'), 'isolated Pi fixture\n'); await writeFile(log, '');
  const hook = join(home, 'capture-hook.cjs');
  const capture = `const {appendFileSync}=require('node:fs');let input='';process.stdin.on('data',c=>input+=c);process.stdin.on('end',()=>{
appendFileSync(${JSON.stringify(log)},JSON.stringify({argv:process.argv.slice(2),payload:JSON.parse(input)})+'\\n');`;
  if (bundledHook) {
    // hook.ts 要求替身 bridge 位于 tmpdir 的独立子目录，不能直接放在临时根目录。
    const transport = join(home, 'transport'); await mkdir(transport);
    const bridge = join(transport, 'mock-bridge.cjs');
    await writeFile(messageLog, ''); await writeFile(hookLog, '');
    await writeFile(bridge, `const fs=require('node:fs');const input=fs.readFileSync(0,'utf8');fs.appendFileSync(${JSON.stringify(messageLog)},JSON.stringify(JSON.parse(input))+'\\n');process.stdout.write('{"ok":true}');`);
    await writeFile(hook, capture + `
const {spawn}=require('node:child_process');
const child=spawn(process.execPath,[${JSON.stringify(bundledHook)},...process.argv.slice(2),'--test-bridge-script',${JSON.stringify(bridge)}],{shell:false,windowsHide:true,stdio:['pipe','pipe','pipe']});
let stdoutBytes=0,stderrBytes=0;
child.stdout.on('data',c=>stdoutBytes+=c.length);child.stderr.on('data',c=>stderrBytes+=c.length);
child.stdin.on('error',()=>{});child.once('error',()=>{process.exitCode=1;});
child.once('close',code=>{appendFileSync(${JSON.stringify(hookLog)},JSON.stringify({code,stdoutBytes,stderrBytes})+'\\n');process.exitCode=code===0?0:1;});
child.stdin.end(input);
});`);
  } else await writeFile(hook, capture + '});');
  const plugin = piPluginSource(node, hook);
  await writeFile(join(agent, 'extensions', 'xisland.ts'), plugin);
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as { port: number }).port;
  await writeFile(join(agent, 'models.json'), JSON.stringify({ providers: { 'xisland-local': {
    baseUrl: `http://127.0.0.1:${port}/v1`, api: 'openai-completions', apiKey: 'isolated-dummy-key',
    models: [{ id: 'observer-model', name: 'Isolated Model', reasoning: false, input: ['text'], contextWindow: 128000, maxTokens: 1024,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  await writeFile(join(agent, 'settings.json'), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
  const environment: NodeJS.ProcessEnv = {
    PI_CODING_AGENT_DIR: agent, PI_OFFLINE: '1', PI_TELEMETRY: '0',
    XDG_CONFIG_HOME: join(home, 'xdg-config'), XDG_DATA_HOME: join(home, 'xdg-data'),
    XDG_CACHE_HOME: join(home, 'xdg-cache'), XDG_STATE_HOME: join(home, 'xdg-state'),
    PATH: process.platform === 'win32' ? dirname(node) : `${dirname(node)}:/usr/bin:/bin`,
    TMPDIR: home, TMP: home, TEMP: home, TERM: 'dumb', NO_COLOR: '1',
  };
  if (bundledHook) environment.XISLAND_TEST_MODE = '1';
  // Windows 的原生进程需要 SystemRoot；绝不继承 provider 认证和扩展环境。
  if (process.platform === 'win32' && process.env.SystemRoot) environment.SystemRoot = process.env.SystemRoot;
  const result = await new Promise<{ code: number | null; stdout: string; stderr: string }>((resolve, reject) => {
    const child = spawn(node, [cli, '--offline', '--no-mcp', '--no-skills', '--no-context-files', '--no-prompt-templates', '--no-themes',
      '--no-approve', '--tools', 'read', ...(switchSession ? ['--mode', 'rpc'] : ['--print', '--mode', 'json']),
      '--no-session', '--provider', 'xisland-local', '--model', 'observer-model', '--thinking', 'off',
      ...(switchSession ? [] : ['Read fixture.txt once and confirm completion.'])],
    { shell: false, windowsHide: true, cwd: workspace, env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', total = 0;
    const timeout = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Isolated Pi client timed out')); }, 20000);
    const collect = (stream: 'stdout' | 'stderr', chunk: Buffer) => {
      total += chunk.length;
      if (total > 1024 * 1024) { child.kill('SIGKILL'); clearTimeout(timeout); reject(new Error('Isolated Pi output exceeded limit')); return; }
      if (stream === 'stdout') stdout += chunk.toString(); else stderr += chunk.toString();
    };
    child.stdout.on('data', chunk => collect('stdout', chunk)); child.stderr.on('data', chunk => collect('stderr', chunk));
    child.once('error', error => { clearTimeout(timeout); reject(error); });
    child.once('close', code => { clearTimeout(timeout); resolve({ code, stdout, stderr }); });
    if (switchSession) void (async () => {
      const send = (command: unknown) => child.stdin.write(JSON.stringify(command) + '\n');
      const waitCount = async (event: string, count: number) => {
        const deadline = Date.now() + 15000;
        while (true) {
          // RPC settled 在 extension handler 完全返回后才发出，不能仅凭 capture 已落盘就切换或关闭宿主。
          const rows = event === 'agent_settled'
            ? stdout.split('\n').slice(0, -1).filter(Boolean).map(line => JSON.parse(line))
            : (await readFile(log, 'utf8')).split('\n').filter(Boolean).map(line => JSON.parse(line));
          if (rows.filter(row => event === 'agent_settled' ? row.type === event : row.payload.native_event === event).length >= count) return;
          assert.ok(Date.now() < deadline && child.exitCode === null, `Timed out awaiting ${event}`);
          await new Promise(resolve => setTimeout(resolve, 10));
        }
      };
      const waitResponse = async (id: string) => {
        const deadline = Date.now() + 15000;
        while (true) {
          const lines = stdout.split('\n').slice(0, -1).filter(Boolean).map(line => JSON.parse(line));
          const response = lines.find(line => line.type === 'response' && line.id === id);
          if (response) { assert.equal(response.success, true, JSON.stringify(response)); return; }
          assert.ok(Date.now() < deadline && child.exitCode === null, `Timed out awaiting ${id}`);
          await new Promise(resolve => setTimeout(resolve, 10));
        }
      };
      send({ id: 'first-prompt', type: 'prompt', message: 'Read fixture.txt once and confirm completion.' });
      await waitCount('agent_settled', 1);
      send({ id: 'replace-session', type: 'new_session' });
      await waitResponse('replace-session');
      await waitCount('session_start', 2);
      send({ id: 'second-prompt', type: 'prompt', message: 'Read fixture.txt once and confirm completion.' });
      await waitCount('agent_settled', 2);
      child.stdin.end();
    })().catch(error => { child.kill('SIGKILL'); clearTimeout(timeout); reject(error); });
    else child.stdin.end();
  });
  assert.equal(result.code, 0, result.stderr); assert.equal(result.stderr.includes('XIsland'), false, result.stderr);
  const records = (await readFile(log, 'utf8')).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  const sessionIds = [...new Set<string>(records.map(record => record.payload.session_id))];
  assert.equal(sessionIds.length, switchSession ? 2 : 1);
  for (const id of sessionIds) {
    const events = records.filter(record => record.payload.session_id === id).map(record => record.payload.native_event);
    // Pi 1.3.0 RPC new_session 会再次 bindExtensions，原生重复 session_start 应保持幂等。
    assert.deepEqual(events.filter((event, index) => event !== 'session_start' || index === 0), [...PI_HOOK_EVENTS]);
  }
  assert.equal(modelRequests.length, switchSession ? 4 : 2);
  if (switchSession) {
    assert.notEqual(records[0].payload.session_id, records[8].payload.session_id);
    assert.equal(records[7].payload.reason, 'new');
    assert.equal(records[8].payload.source, 'new');
  }
  const delivered = bundledHook
    ? (await readFile(messageLog, 'utf8')).trim().split('\n').filter(Boolean).map(line => parseDIMessage(JSON.parse(line)))
    : undefined;
  if (delivered) {
    assert.equal(delivered.length, records.length);
    const outcomes = (await readFile(hookLog, 'utf8')).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
    assert.equal(outcomes.length, records.length);
    for (const outcome of outcomes) assert.deepEqual(outcome, { code: 0, stdoutBytes: 0, stderrBytes: 0 });
  }
  const store = new SessionStore(), states: { event: string; status: string }[] = [];
  for (const [index, { payload, argv }] of records.entries()) {
    assert.deepEqual(argv, ['--agent', 'pi', '--hook', payload.native_event]);
    assert.equal(payload.model, 'observer-model');
    const message = delivered?.[index] ?? normalizePiHook(payload);
    if (delivered) assert.deepEqual(message, normalizePiHook(payload, { timestamp: message.timestamp }));
    assert.equal(store.apply(message).accepted, true);
    states.push({ event: payload.native_event, status: store.snapshot().sessions.find(session => session.id === `pi-${payload.session_id}`)!.status });
  }
  assert.equal(states.find(state => state.event === 'agent_end')!.status, 'active');
  assert.equal(states.find(state => state.event === 'agent_settled')!.status, 'idle');
  assert.equal(states.at(-1)!.status, 'completed');
  const packagePath = resolve(dirname(cli), '../../package.json');
  const metadata = JSON.parse(await readFile(packagePath, 'utf8'));
  const report = {
    checkedAt: new Date().toISOString(), hostPlatform: process.platform, hostArchitecture: process.arch,
    package: metadata.name, version: metadata.version, license: metadata.license,
    cliSha256: createHash('sha256').update(await readFile(cli)).digest('hex'),
    pluginSha256: createHash('sha256').update(plugin).digest('hex'),
    nativeClientLoadedPlugin: true, defaultExtensionDiscovery: true, realToolExecuted: 'read',
    actualBundledHookVerified: !!bundledHook,
    bundledHookSha256: bundledHook ? createHash('sha256').update(await readFile(bundledHook)).digest('hex') : undefined,
    transport: bundledHook ? 'isolated Node bridge returning ok; no Rust or Named Pipe' : 'capture-only hook; normalized during replay',
    sessionReplacementVerified: switchSession, sessionCount: store.snapshot().sessions.length,
    repeatedNativeSessionStarts: records.filter(record => record.payload.native_event === 'session_start').length - sessionIds.length,
    model: 'loopback OpenAI-compatible deterministic fixture', modelRequests: modelRequests.length, eventCount: records.length,
    states, modelIdPreserved: store.snapshot().sessions[0]!.usage.model === 'observer-model',
    credentialsInherited: false, realUserConfigurationTouched: false, homeVariableOverridden: false,
    windowsRuntimeVerified: false,
    limitations: [bundledHook
      ? 'Native CLI executed the supplied hook CJS with a local simulated model and Node mock transport; Rust, Named Pipe, installed Windows runtime and UI remain separate acceptance gates.'
      : 'Native CLI used a local simulated model and a capture-only hook; Windows installed-app pipe, UI, and bundled runtime are separate acceptance gates.'],
  };
  if (output) await writeFile(output, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
} finally {
  server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve()));
  await rm(home, { recursive: true, force: true });
}
