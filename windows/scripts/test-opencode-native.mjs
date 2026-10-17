// 隔离的真实 OpenCode macOS CLI 验收；桌面 Rust/Named Pipe/UI 不在本脚本覆盖范围。
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, realpath, writeFile } from 'node:fs/promises';
import { createServer as createHttpServer } from 'node:http';
import { createServer as createTcpServer } from 'node:net';
import { tmpdir, userInfo } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';

const windows = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const applicationVersion = JSON.parse(await readFile(join(windows, 'package.json'), 'utf8')).version;
const version = '1.19.3';
const binaryHash = '6d3e6458fce4b649edf974c19959d5dbfe1e7f255a503dcfc01215b24ad3ea5b';
const cli = resolve(process.argv[2] ?? `/tmp/xisland-opencode-native-${version}/package/bin/opencode`);
const reportPath = resolve(process.argv[3] ?? join(windows, `../docs/windows/evidence/opencode-native-macos-${applicationVersion}.json`));
assert.equal(process.platform, 'darwin', 'this pinned binary and evidence harness target macOS only');
assert.equal(process.arch, 'arm64');
const sha256 = value => createHash('sha256').update(value).digest('hex');
assert.equal(sha256(await readFile(cli)), binaryHash, 'unverified or different OpenCode binary');
for (const plist of [
  '/Library/Managed Preferences/ai.opencode.managed.plist',
  `/Library/Managed Preferences/${userInfo().username}/ai.opencode.managed.plist`,
]) assert.equal(existsSync(plist), false, 'managed preferences could override isolated settings');

const directory = await realpath(await mkdtemp(join(tmpdir(), 'xisland-opencode-native-')));
const workspace = join(directory, 'workspace');
const configDirectory = join(directory, 'config', 'opencode');
const fixturePath = join(workspace, 'fixture.txt');
const marker = `XISLAND_NATIVE_FIXTURE_${randomBytes(10).toString('hex')}`;
await Promise.all([workspace, configDirectory, join(configDirectory, 'node_modules'), join(directory, 'home'),
  join(directory, 'cache'), join(directory, 'state'), join(directory, 'data'), join(directory, 'tmp'),
  join(directory, 'managed')].map(path => mkdir(path, { recursive: true })));
await writeFile(fixturePath, marker + '\n');
// 官方配置加载会检查 plugin 依赖锁；本插件仅使用 Node 内置模块，无需 npm 网络安装。
await writeFile(join(configDirectory, 'package.json'), JSON.stringify({ private: true, dependencies: { '@opencode-ai/plugin': version } }));
await writeFile(join(configDirectory, 'package-lock.json'), JSON.stringify({ lockfileVersion: 3,
  packages: { '': { dependencies: { '@opencode-ai/plugin': version } } } }));

const runtimePath = join(directory, 'runtime.mjs');
await build({ stdin: { contents: `export { SessionStore } from ${JSON.stringify(join(windows, 'src/core/session-store.ts'))};
export { openCodePluginSource } from ${JSON.stringify(join(windows, 'src/integrations/opencode-plugin.ts'))};`,
  resolveDir: windows }, outfile: runtimePath, bundle: true, platform: 'node', format: 'esm' });
const { SessionStore, openCodePluginSource } = await import(pathToFileURL(runtimePath).href);
const store = new SessionStore({ ownerInstanceId: 'opencode-native-macos' });
const receipts = [], responses = [], models = [], nativeEvents = [], failures = [];
const scenarios = new Map();
const sockets = new Set();
let transportSequence = 0;
let child;
let stdout = '', stderr = '';
const eventAbort = new AbortController();
const report = {
  schemaVersion: 1, applicationVersion, startedAt: new Date().toISOString(), platform: process.platform, arch: process.arch,
  version, binarySha256: binaryHash, cli, isolatedDirectory: directory,
  distribution: {
    package: 'opencode-darwin-arm64@1.19.3',
    url: 'https://registry.npmjs.org/opencode-darwin-arm64/-/opencode-darwin-arm64-1.19.3.tgz',
    tarballSha256: '6b0d3cf1f00f9df971702f96d812562e8b94ae870c5a74ca149d8e00b2187b32',
    npmIntegrity: 'sha512-NmDF28jD8W7m9a/k4mc3rajEWftDemGecrzBJItzTWwN0Eu5WFSEFBocvmmasUr4nh8ei9Zl1pwRvv66R4dN6A==',
    licenseSource: 'https://github.com/anomalyco/opencode/blob/v1.19.3/LICENSE',
  },
  nativeClientExecuted: false, realProviderUsed: false, windowsNativeClientExecuted: false,
  rustBridgeExecuted: false, graphicalUiExecuted: false,
  bridge: 'real generated plugin -> real bundled hook/adapter -> temporary Node TCP transport -> real SessionStore',
  isolation: { homeUnmodified: true, codexHomeUnmodified: true, realCredentialsInherited: false,
    xdgRoots: true, opencodeTestHome: true, opencodeTestManagedConfigDir: true, projectConfigurationDisabled: true,
    provider: 'localhost OpenAI-compatible deterministic fixture', automaticUpdateDisabled: true,
    defaultPluginsDisabled: true, externalSkillsDisabled: true, claudeCompatibilityDisabled: true,
    modelsFetchDisabled: true, publicNpmInstallPerformed: false },
  scenarios: [], sources: {}, receipts, responses, modelRequests: models, nativeEvents, failures,
};
const log = text => process.stdout.write(`[opencode-native] ${text}\n`);
const listen = server => new Promise((resolveListen, reject) => {
  server.once('error', reject); server.listen(0, '127.0.0.1', () => {
    server.off('error', reject); resolveListen(server.address().port);
  });
});
const sleep = milliseconds => new Promise(resolveSleep => setTimeout(resolveSleep, milliseconds));
async function until(predicate, label, milliseconds = 20000) {
  const deadline = Date.now() + milliseconds;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timeout: ${label}`);
    if (child && child.exitCode !== null) throw new Error(`CLI exited: ${child.exitCode}; ${stderr.slice(-2500)}`);
    await sleep(25);
  }
}

const transport = createTcpServer(socket => {
  sockets.add(socket); socket.setEncoding('utf8');
  let input = '', requestId;
  socket.on('close', () => { sockets.delete(socket); if (requestId) store.endTransport(requestId); });
  socket.on('error', error => failures.push(`transport: ${error.message}`));
  socket.on('data', chunk => {
    input += chunk;
    if (!input.includes('\n')) return;
    socket.removeAllListeners('data');
    try {
      const message = JSON.parse(input.trim());
      const interactive = ['permission_request', 'question'].includes(message.type);
      requestId = interactive ? `native-${++transportSequence}` : undefined;
      const applied = store.apply(message, requestId ? { requestId, expiresAt: Date.now() + 10000 } : undefined);
      receipts.push({ message, applied, transportRequestId: requestId });
      // Store 已确认发送后，原生 replied 再来一次会被作为无匹配的幂等通知忽略。
      if (message.type !== 'interaction_resolved') assert.equal(applied.accepted, true, applied.reason);
      if (!interactive) { socket.end('{"ok":true}\n'); return; }
      const session = store.snapshot().sessions.find(value => value.id === message.sessionId);
      const pending = session.pendingInteractions.find(value => value.transportRequestId === requestId);
      assert.ok(pending);
      const scenario = scenarios.get(message.sessionId);
      let decision;
      if (message.type === 'permission_request') {
        // 白名单检查失败只拒绝。不得批准来自真实项目或非本次 fixture 的权限。
        const exactFixture = message.tool === 'read'
          && [fixturePath, fixturePath.slice(1), 'fixture.txt'].includes(message.permDescription);
        decision = { kind: 'permission', approved: exactFixture && scenario === 'allow-read' };
        if (!exactFixture) failures.push(`unexpected permission rejected: ${message.tool}`);
      } else {
        assert.equal(scenario, 'questions');
        if (message.questionText.endsWith('选择分支')) decision = { kind: 'question', answer: 'dev' };
        else if (message.questionText.endsWith('选择功能')) decision = { kind: 'question', selectedAnswers: ['B', 'A', '自定义😀'] };
        else if (message.questionText.endsWith('补充说明')) decision = { kind: 'question', answer: '中文自由文本' };
        else throw new Error('unexpected question');
      }
      const prepared = store.prepareResponse(message.sessionId, pending.id, decision);
      assert.ok(prepared, 'SessionStore must prepare a correlated response');
      responses.push({ scenario, nativeRequestId: message.nativeRequestId, decision, response: prepared.response });
      socket.end(JSON.stringify(prepared.response) + '\n', () => {
        assert.equal(store.confirmResponse(prepared.interactionId, true), true);
      });
    } catch (error) {
      failures.push(String(error)); socket.destroy();
    }
  });
});

const questionRows = [
  { header: '分支', question: '选择分支', options: [{ label: 'main', description: '主分支' }, { label: 'dev', description: '开发分支' }], custom: false },
  { header: '功能', question: '选择功能', options: [{ label: 'A', description: '功能 A' }, { label: 'B', description: '功能 B' }], multiple: true, custom: true },
  { header: '说明', question: '补充说明', options: [], custom: true },
];
const model = createHttpServer(async (request, response) => {
  let text = ''; for await (const chunk of request) text += chunk;
  try {
    assert.equal(request.url, '/v1/chat/completions');
    const body = JSON.parse(text);
    const prompt = body.messages.findLast(value => value.role === 'user')?.content;
    const scenario = typeof prompt === 'string' ? prompt.match(/SCENARIO:([a-z-]+)/)?.[1]
      : JSON.stringify(prompt).match(/SCENARIO:([a-z-]+)/)?.[1];
    assert.ok(['allow-read', 'deny-read', 'questions'].includes(scenario), 'only fixture prompts are accepted');
    const toolMessages = body.messages.filter(value => value.role === 'tool');
    models.push({ scenario, path: request.url, model: body.model, tools: body.tools?.map(value => value.function.name),
      toolResults: toolMessages.map(value => ({ toolCallId: value.tool_call_id, content: value.content })) });
    const tool = scenario === 'questions' ? 'question' : 'read';
    assert.ok(body.tools?.some(value => value.function.name === tool), `native ${tool} tool is available`);
    const chunks = [];
    if (toolMessages.length === 0) {
      chunks.push({ delta: { role: 'assistant', tool_calls: [{ index: 0, id: `call_${scenario.replaceAll('-', '_')}`,
        type: 'function', function: { name: tool, arguments: JSON.stringify(tool === 'read'
          ? { filePath: fixturePath } : { questions: questionRows }) } }] }, finish_reason: null });
      chunks.push({ delta: {}, finish_reason: 'tool_calls' });
    } else {
      const content = JSON.stringify(toolMessages);
      if (scenario === 'allow-read') assert.ok(content.includes(marker), 'native Read must return the generated fixture');
      if (scenario === 'deny-read') { assert.ok(!content.includes(marker), 'denied tool must not expose the fixture'); assert.match(content, /reject|denied|permission/i); }
      if (scenario === 'questions') for (const answer of ['dev', 'A', 'B', '自定义😀', '中文自由文本']) assert.ok(content.includes(answer));
      chunks.push({ delta: { role: 'assistant', content: `NATIVE_DONE:${scenario}` }, finish_reason: null });
      chunks.push({ delta: {}, finish_reason: 'stop' });
    }
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const choice of chunks) response.write(`data: ${JSON.stringify({ id: `chatcmpl-${scenario}`, object: 'chat.completion.chunk',
      created: Math.floor(Date.now() / 1000), model: 'fixture', choices: [{ index: 0, ...choice }] })}\n\n`);
    response.end('data: [DONE]\n\n');
  } catch (error) { failures.push(`model: ${error}`); response.writeHead(400); response.end(JSON.stringify({ error: String(error) })); }
});

try {
  const transportPort = await listen(transport);
  const modelPort = await listen(model);
  await mkdir(join(directory, 'tmp', 'bridge'), { recursive: true });
  const bridge = join(directory, 'tmp', 'bridge', 'test-bridge.mjs');
  await writeFile(bridge, `import { createConnection } from 'node:net';
let input = ''; for await (const chunk of process.stdin) input += chunk;
const socket = createConnection({host:'127.0.0.1',port:${transportPort}}); socket.setEncoding('utf8');
socket.on('error',()=>process.exit(1)); socket.on('connect',()=>socket.write(input+'\\n'));
let output = ''; for await (const chunk of socket) output += chunk; process.stdout.write(output);
`);
  const hook = join(directory, 'xisland-hook.cjs');
  await build({ entryPoints: [join(windows, 'src/hook.ts')], outfile: hook, bundle: true, platform: 'node', target: 'node20', format: 'cjs' });
  const wrapper = join(directory, 'hook-wrapper.mjs');
  await writeFile(wrapper, `process.argv.push('--test-bridge-script',${JSON.stringify(bridge)}); await import(${JSON.stringify(pathToFileURL(hook).href)});\n`);
  const plugin = join(directory, 'xisland-plugin.mjs');
  await writeFile(plugin, openCodePluginSource(process.execPath, wrapper));
  for (const path of ['src/hook.ts', 'src/adapters/opencode.ts', 'src/core/session-store.ts', 'src/integrations/opencode-plugin.ts']) {
    report.sources[path] = sha256(await readFile(join(windows, path)));
  }
  report.generatedPluginSha256 = sha256(await readFile(plugin));
  report.bundledHookSha256 = sha256(await readFile(hook));
  report.harnessSha256 = sha256(await readFile(fileURLToPath(import.meta.url)));
  const config = {
    autoupdate: false, share: 'disabled', snapshot: false, model: 'xisland-fixture/fixture', small_model: 'xisland-fixture/fixture',
    enabled_providers: ['xisland-fixture'], plugin: [pathToFileURL(plugin).href],
    provider: { 'xisland-fixture': { npm: '@ai-sdk/openai-compatible', name: 'Isolated localhost fixture',
      options: { baseURL: `http://127.0.0.1:${modelPort}/v1`, apiKey: 'local-fixture-only' },
      models: { fixture: { name: 'Deterministic fixture', tool_call: true, limit: { context: 32000, output: 4000 } } } } },
    permission: { '*': 'deny', read: { '*': 'deny', [fixturePath]: 'ask', [fixturePath.slice(1)]: 'ask' }, question: 'allow' },
    agent: { title: { disable: true }, summary: { disable: true } },
    lsp: false, formatter: false,
  };
  const configPath = join(configDirectory, 'opencode.json');
  await writeFile(configPath, JSON.stringify(config, null, 2));
  const env = {
    PATH: `${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`, LANG: 'en_US.UTF-8',
    XDG_CONFIG_HOME: join(directory, 'config'), XDG_DATA_HOME: join(directory, 'data'),
    XDG_CACHE_HOME: join(directory, 'cache'), XDG_STATE_HOME: join(directory, 'state'), TMPDIR: join(directory, 'tmp'),
    OPENCODE_TEST_HOME: join(directory, 'home'), OPENCODE_TEST_MANAGED_CONFIG_DIR: join(directory, 'managed'),
    OPENCODE_CONFIG: configPath, OPENCODE_CONFIG_DIR: configDirectory, OPENCODE_AUTH_CONTENT: '{}',
    OPENCODE_DISABLE_PROJECT_CONFIG: '1', OPENCODE_DISABLE_AUTOUPDATE: '1', OPENCODE_DISABLE_AUTOCOMPACT: '1',
    OPENCODE_DISABLE_MODELS_FETCH: '1', OPENCODE_DISABLE_DEFAULT_PLUGINS: '1', OPENCODE_DISABLE_CLAUDE_CODE: '1',
    OPENCODE_DISABLE_EXTERNAL_SKILLS: '1', OPENCODE_DISABLE_LSP_DOWNLOAD: '1', OPENCODE_DISABLE_EMBEDDED_WEB_UI: '1',
    OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER: '1', OPENCODE_ENABLE_QUESTION_TOOL: '1',
    OPENCODE_SERVER_PASSWORD: randomBytes(24).toString('hex'), XISLAND_TEST_MODE: '1',
    npm_config_registry: `http://127.0.0.1:${modelPort}/npm-disabled`,
  };
  // HOME/CODEX_HOME 不重赋值；仅将用户原 HOME 传给运行时，OpenCode home 由测试专用字段隔离。
  if (process.env.HOME) env.HOME = process.env.HOME;
  report.isolation.environmentKeys = Object.keys(env).sort();
  const versionResult = spawnSync(cli, ['--version'], { cwd: workspace, env, encoding: 'utf8', timeout: 10000 });
  assert.equal(versionResult.status, 0, versionResult.stderr);
  assert.equal(versionResult.stdout.trim(), version);
  report.nativeClientExecuted = true;
  log(`verified OpenCode ${version}; starting isolated native server`);
  child = spawn(cli, ['serve', '--hostname', '127.0.0.1', '--port', '0'], { cwd: workspace, env, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', chunk => { stdout += chunk; }); child.stderr.on('data', chunk => { stderr += chunk; });
  await until(() => /http:\/\/127\.0\.0\.1:\d+/.test(stdout), 'CLI server address');
  const base = stdout.match(/http:\/\/127\.0\.0\.1:\d+/)[0];
  const headers = { authorization: `Basic ${Buffer.from(`opencode:${env.OPENCODE_SERVER_PASSWORD}`).toString('base64')}`,
    'content-type': 'application/json', 'x-opencode-directory': workspace };
  async function api(path, body) {
    const response = await fetch(base + path, { method: body === undefined ? 'GET' : 'POST', headers,
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(45000) });
    const data = await response.json(); assert.ok(response.ok, `${path}: ${JSON.stringify(data)}`); return data;
  }
  const eventTask = (async () => {
    try {
      const response = await fetch(base + '/event', { headers, signal: eventAbort.signal });
      assert.equal(response.status, 200);
      let buffer = '';
      for await (const chunk of response.body) {
        buffer += Buffer.from(chunk).toString('utf8');
        const lines = buffer.split('\n'); buffer = lines.pop();
        for (const line of lines) if (line.startsWith('data: ')) {
          const event = JSON.parse(line.slice(6));
          if (['permission.asked', 'permission.replied', 'question.asked', 'question.replied', 'question.rejected', 'session.error'].includes(event.type)) nativeEvents.push(event);
        }
      }
    } catch (error) { if (!eventAbort.signal.aborted) failures.push(`native events: ${error}`); }
  })();
  const effective = await api('/config');
  assert.deepEqual(effective.enabled_providers, ['xisland-fixture']);
  assert.equal(effective.provider['xisland-fixture'].options.baseURL, config.provider['xisland-fixture'].options.baseURL);
  assert.equal(effective.plugin.length, 1, 'only generated XIsland plugin may load');
  report.effectiveConfigVerified = true;
  for (const scenario of ['allow-read', 'deny-read', 'questions']) {
    const session = await api('/session', { title: `XIsland native fixture ${scenario}` });
    scenarios.set(`opencode-${session.id}`, scenario);
    log(`running ${scenario}`);
    const reply = await api(`/session/${session.id}/message`, { model: { providerID: 'xisland-fixture', modelID: 'fixture' },
      parts: [{ type: 'text', text: `SCENARIO:${scenario}. Use only the supplied deterministic fixture tool call.` }] });
    assert.equal(reply.info?.error, undefined, JSON.stringify(reply.info?.error));
    await until(() => receipts.some(receipt => receipt.message.sessionId === `opencode-${session.id}`
      && receipt.message.nativeEvent === 'session.idle'), `${scenario} idle bridge receipt`);
    if (scenario === 'deny-read') {
      // OpenCode 1.19.3 默认在拒绝权限后停止当前回合，无第二次模型请求。
      assert.ok(reply.parts.some(part => part.type === 'tool' && part.state.status === 'error'
        && /reject|denied|permission/i.test(part.state.error)), 'native rejected tool result');
      assert.ok(!JSON.stringify(reply).includes(marker), 'denied native result must not include fixture contents');
      assert.equal(models.filter(value => value.scenario === scenario).length, 1);
    } else assert.ok(reply.parts.some(part => part.type === 'text' && part.text === `NATIVE_DONE:${scenario}`), 'native final response');
    const result = store.snapshot().sessions.find(value => value.id === `opencode-${session.id}`);
    assert.equal(result.pendingInteractions.length, 0);
    assert.ok(result.chatHistory.some(value => value.role === 'user' && value.content.includes(`SCENARIO:${scenario}`)));
    const relevantResponses = responses.filter(value => value.scenario === scenario);
    const relevantNative = nativeEvents.filter(value => value.properties?.sessionID === session.id);
    if (scenario === 'questions') {
      assert.equal(relevantResponses.length, 3);
      const confirmed = relevantNative.find(value => value.type === 'question.replied');
      assert.ok(confirmed, 'native question.replied must independently confirm SDK delivery');
      assert.deepEqual(confirmed.properties.answers, [['dev'], ['A', 'B', '自定义😀'], ['中文自由文本']]);
      assert.equal(new Set(relevantResponses.map(value => value.nativeRequestId)).size, 1);
    } else {
      assert.equal(relevantResponses.length, 1);
      const confirmed = relevantNative.find(value => value.type === 'permission.replied');
      assert.ok(confirmed, 'native permission.replied must independently confirm SDK delivery');
      assert.equal(confirmed.properties.reply, scenario === 'allow-read' ? 'once' : 'reject');
    }
    report.scenarios.push({ scenario, sessionId: session.id, nativeReplyConfirmed: true,
      interactionCount: relevantResponses.length, modelRequests: models.filter(value => value.scenario === scenario).length,
      finalText: scenario === 'deny-read' ? null : `NATIVE_DONE:${scenario}`,
      nativeParts: reply.parts, storePendingCount: result.pendingInteractions.length, storeStatus: result.status });
    log(`passed ${scenario}`);
  }
  assert.deepEqual(failures, []);
  report.passed = true;
  eventAbort.abort(); await eventTask;
} catch (error) {
  report.passed = false; report.error = error instanceof Error ? error.stack : String(error);
  process.exitCode = 1; log(`failed: ${error.message}`);
} finally {
  eventAbort.abort();
  if (child && child.exitCode === null) {
    child.kill('SIGTERM');
    await Promise.race([new Promise(resolveClose => child.once('close', resolveClose)), sleep(3000)]);
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
  for (const socket of sockets) socket.destroy();
  model.closeAllConnections(); transport.close(); model.close();
  report.finishedAt = new Date().toISOString();
  report.nativeStdout = stdout; report.nativeStderr = stderr;
  report.store = store.snapshot();
  await mkdir(dirname(reportPath), { recursive: true });
  await writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
  log(`report: ${reportPath}`);
}
