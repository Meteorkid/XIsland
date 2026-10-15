import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { build } from 'esbuild';
import { after, before, test } from 'node:test';
import { MAX_MESSAGE_BYTES } from '../src/core/protocol';

let directory: string, hook: string, stub: string;
before(async () => {
  directory = await mkdtemp(join(tmpdir(), 'xisland-hook-test-'));
  hook = join(directory, 'hook.cjs'); stub = join(directory, 'stub.cjs');
  await build({ entryPoints: [resolve('src/hook.ts')], outfile: hook, bundle: true, platform: 'node', target: 'node20', format: 'cjs', logLevel: 'silent' });
  await writeFile(stub, `
const fs = require('node:fs');
const message = JSON.parse(fs.readFileSync(0, 'utf8'));
fs.writeFileSync(process.env.XISLAND_STUB_CAPTURE, JSON.stringify(message));
const mode = process.env.XISLAND_STUB_MODE;
if (mode === 'hang') { setTimeout(() => {}, 10000); return; }
if (mode === 'fail') { process.stderr.write('secret-native-content'); process.exit(23); }
if (mode === 'invalid-utf8') { process.stdout.write(Buffer.from([0xc3, 0x28])); return; }
if (mode === 'oversized') { process.stdout.write(Buffer.alloc(${MAX_MESSAGE_BYTES + 1}, 120)); return; }
let response = {ok:true};
if (mode === 'deny') response = {type:'permission_response', sessionId:message.sessionId, timestamp:message.timestamp, approved:false};
if (mode === 'question' || mode === 'split') response = {type:'question_response',sessionId:message.sessionId,timestamp:message.timestamp,answer:'自定义😀'};
if (mode === 'wrong-session') response = {type:'permission_response',sessionId:'other',timestamp:message.timestamp,approved:true};
const bytes = Buffer.from(JSON.stringify(response));
if (mode === 'split') { const at = bytes.indexOf(Buffer.from('自')) + 1; process.stdout.write(bytes.subarray(0,at)); setTimeout(()=>process.stdout.write(bytes.subarray(at)),30); }
else process.stdout.write(bytes);
`);
});
after(async () => { await rm(directory, { recursive: true, force: true }); });

async function run(agent: string, payload: unknown, mode = 'ack', options: { raw?: Buffer; args?: string[]; testMode?: boolean; splitInput?: boolean } = {}) {
  const capture = join(directory, `capture-${Math.random().toString(36).slice(2)}.json`);
  const child = spawn(process.execPath, [hook, '--agent', agent, '--test-bridge-script', stub, ...(options.args ?? [])], {
    env: { ...process.env, XISLAND_TEST_MODE: options.testMode === false ? '0' : '1', XISLAND_STUB_MODE: mode, XISLAND_STUB_CAPTURE: capture },
    stdio: ['pipe', 'pipe', 'pipe'], timeout: 8000,
  });
  const output: Buffer[] = [], errors: Buffer[] = [];
  child.stdout.on('data', bytes => output.push(bytes)); child.stderr.on('data', bytes => errors.push(bytes));
  child.stdin.on('error', () => { /* 超限输入会主动关闭 stdin。 */ });
  const bytes = options.raw ?? Buffer.from(JSON.stringify(payload));
  if (options.splitInput) {
    const offset = bytes.indexOf(Buffer.from('中')) + 1;
    child.stdin.write(bytes.subarray(0, offset));
    setTimeout(() => child.stdin.end(bytes.subarray(offset)), 20);
  } else child.stdin.end(bytes);
  const code = await new Promise<number | null>((resolveCode, reject) => { child.on('error', reject); child.on('close', resolveCode); });
  let delivered: unknown;
  try { delivered = JSON.parse(await readFile(capture, 'utf8')); } catch { /* 无投递时没有 capture 文件。 */ }
  return { code, stdout: Buffer.concat(output).toString('utf8'), stderr: Buffer.concat(errors).toString('utf8'), delivered };
}

const native = (name: string, fields = {}) => ({ hook_event_name: name, session_id: 'one', cwd: 'C:\\中文', ...fields });
const cursor = (name: string, fields = {}) => ({ hook_event_name: name, conversation_id: 'one', cwd: 'C:\\中文', ...fields });

test('WorkBuddy subprocess observes lifecycle, rejects invalid input and never emits a native decision', async () => {
  for (const mode of ['ack', 'fail', 'wrong-session']) {
    const result = await run('workbuddy', native('FinalStop', { final_stop_reason: 'completed' }), mode, { args: ['--hook', 'FinalStop'] });
    assert.equal(result.code, 0); assert.equal(result.stdout, '');
    assert.equal((result.delivered as { agentType: string }).agentType, 'workbuddy');
    assert.equal(result.stderr.includes('secret-native-content'), false);
  }
  const invalid = await run('workbuddy', native('PermissionRequest'), 'ack', { args: ['--hook', 'Stop'] });
  assert.equal(invalid.code, 0); assert.equal(invalid.stdout, ''); assert.equal(invalid.delivered, undefined);
});

test('WorkBuddy observation bridge deadline returns neutral output instead of holding the native task', async () => {
  const start = performance.now();
  const result = await run('workbuddy', native('SessionStart'), 'hang');
  assert.equal(result.code, 0); assert.equal(result.stdout, '');
  assert.ok(performance.now() - start < 5000);
});

test('real hook subprocess routes all four native event dialects to the bridge', async () => {
  for (const [agent, payload, expectedType] of [
    ['claude_code', native('SessionStart'), 'session_start'],
    ['codex', native('UserPromptSubmit', { prompt: '检查中文😀' }), 'session_start'],
    ['cursor', cursor('afterAgentResponse', { text: '完成中文😀' }), 'status_update'],
    ['gemini_cli', native('BeforeTool', { tool_name: 'read_file', tool_input: { path: 'C:\\中文' } }), 'tool_start'],
  ] as const) {
    const result = await run(agent, payload, 'ack', { splitInput: true });
    assert.equal(result.code, 0);
    assert.equal((result.delivered as { agentType: string }).agentType, agent);
    assert.equal((result.delivered as { type: string }).type, expectedType);
    assert.equal((result.delivered as { workingDir: string }).workingDir, 'C:\\中文');
    assert.deepEqual(JSON.parse(result.stdout), {});
  }
});

test('actual subprocess denial returns the correct Claude, Codex and Cursor schemas', async () => {
  for (const agent of ['claude_code', 'codex']) {
    const result = await run(agent, native('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'dir' } }), 'deny');
    assert.equal(result.code, 0);
    assert.equal(JSON.parse(result.stdout).hookSpecificOutput.decision.behavior, 'deny');
  }
  const result = await run('cursor', cursor('beforeShellExecution', { command: 'dir' }), 'deny');
  assert.equal(result.code, 0);
  assert.deepEqual(JSON.parse(result.stdout), { permission: 'deny' });
});

test('Windsurf and Trae CN installed hook commands reach their specific observation adapters', async () => {
  const wind = { agent_action_name: 'pre_user_prompt', trajectory_id: 'wind-one', execution_id: 'turn',
    timestamp: new Date().toISOString(), model_name: 'fixture-model', tool_info: { user_prompt: '检查中文' } };
  const observed = await run('windsurf', wind, 'ack', { args: ['--hook', 'pre_user_prompt'] });
  assert.equal(observed.code, 0); assert.equal(observed.stdout.trim(), '');
  assert.equal((observed.delivered as { sessionId: string }).sessionId, 'windsurf-wind-one');
  const trae = await run('trae_cn', native('SessionStart'), 'ack', { args: ['--hook', 'SessionStart'] });
  assert.equal(trae.code, 0); assert.deepEqual(JSON.parse(trae.stdout), {});
  assert.equal((trae.delivered as { agentType: string }).agentType, 'trae');
  const failed = await run('windsurf', wind, 'fail', { args: ['--hook', 'pre_user_prompt'] });
  assert.equal(failed.code, 0); assert.equal(failed.stdout.trim(), '');
  assert.equal(failed.stderr.includes('secret-native-content'), false);
});

test('UTF-8 split inside a multibyte answer survives the real stdout pipe', async () => {
  const result = await run('claude_code', native('PreToolUse', { tool_name: 'AskUserQuestion', tool_input: { question: '路径？', options: [] } }), 'split');
  assert.equal(result.code, 0);
  assert.equal(JSON.parse(result.stdout).hookSpecificOutput.updatedInput.answer, '自定义😀');
});

test('bridge failure preserves each dialect fallback without leaking bridge stderr', async () => {
  for (const [agent, payload, expected] of [
    ['claude_code', native('PermissionRequest'), {}],
    ['codex', native('PermissionRequest'), {}],
    ['cursor', cursor('beforeShellExecution', { command: 'dir' }), { permission: 'ask' }],
    ['gemini_cli', native('BeforeTool'), {}],
  ] as const) {
    const result = await run(agent, payload, 'fail');
    assert.equal(result.code, 0);
    assert.deepEqual(JSON.parse(result.stdout), expected);
    assert.equal(result.stderr.includes('secret-native-content'), false);
  }
});

test('Cursor observation fallback remains allow but unavailable file approval is deny', async () => {
  const observed = await run('cursor', cursor('preToolUse', { tool_name: 'Read', tool_use_id: 'c', tool_input: {} }), 'fail');
  assert.deepEqual(JSON.parse(observed.stdout), { permission: 'allow' });
  const gated = await run('cursor', cursor('beforeReadFile', { file_path: 'C:\\private.txt' }), 'fail');
  assert.equal(JSON.parse(gated.stdout).permission, 'deny');
});

test('unsupported Cursor event and unknown agent preserve non-success exit', async () => {
  const unknown = await run('cursor', cursor('unknownEvent'));
  assert.equal(unknown.code, 1); assert.equal(unknown.stdout, ''); assert.equal(unknown.delivered, undefined);
  const agent = await run('invented', native('SessionStart'));
  assert.equal(agent.code, 1); assert.equal(agent.stdout, ''); assert.equal(agent.delivered, undefined);
});

test('invalid, mismatched and oversized bridge responses never grant permission', async () => {
  for (const mode of ['invalid-utf8', 'wrong-session', 'oversized']) {
    const result = await run('codex', native('PermissionRequest'), mode);
    assert.equal(result.code, 0); assert.deepEqual(JSON.parse(result.stdout), {});
  }
});

test('invalid or oversized stdin is rejected before bridge spawn, with event-aware fallback', async () => {
  for (const raw of [Buffer.from([0xc3, 0x28]), Buffer.alloc(MAX_MESSAGE_BYTES + 1, 120)]) {
    const result = await run('cursor', null, 'ack', { raw, args: ['--hook', 'beforeShellExecution'] });
    assert.equal(result.code, 0); assert.deepEqual(JSON.parse(result.stdout), { permission: 'ask' });
    assert.equal(result.delivered, undefined);
  }
  const mismatch = await run('cursor', cursor('preToolUse'), 'ack', { args: ['--hook', 'beforeReadFile'] });
  assert.equal(JSON.parse(mismatch.stdout).permission, 'deny'); assert.equal(mismatch.delivered, undefined);
});

test('test bridge override cannot run outside explicit test mode', async () => {
  const result = await run('claude_code', native('SessionStart'), 'ack', { testMode: false });
  assert.equal(result.delivered, undefined); assert.deepEqual(JSON.parse(result.stdout), {});
});

test('stdin limit is enforced while the producer keeps its stream open', async () => {
  const child = spawn(process.execPath, [hook, '--agent', 'codex', '--hook', 'PermissionRequest'], {
    stdio: ['pipe', 'pipe', 'pipe'], timeout: 3000,
  });
  const output: Buffer[] = [];
  child.stdout.on('data', bytes => output.push(bytes)); child.stderr.resume(); child.stdin.on('error', () => {});
  // 故意不发送 EOF；readFileSync 后再检查长度的旧实现会卡到测试超时。
  child.stdin.write(Buffer.alloc(MAX_MESSAGE_BYTES + 1, 120));
  const code = await new Promise<number | null>((resolveCode, reject) => { child.on('error', reject); child.on('close', resolveCode); });
  assert.equal(code, 0);
  assert.deepEqual(JSON.parse(Buffer.concat(output).toString('utf8')), {});
});

test('plan CLI prints no user credentials or nextConfig and writes no real configuration', async () => {
  const result = await run('claude_code', { apiKey: 'secret-value', hooks: {} }, 'ack', { args: [
    '--plan', 'install', '--home', 'C:\\Users\\test', '--node', 'C:\\Program Files\\nodejs\\node.exe', '--script', 'C:\\XIsland\\hook.cjs',
  ] });
  assert.equal(result.code, 0);
  const summary = JSON.parse(result.stdout);
  assert.equal(summary.configPath, 'C:\\Users\\test\\.claude\\settings.json');
  assert.equal(summary.nextConfig, undefined); assert.equal(result.stdout.includes('secret-value'), false);
  assert.equal(result.delivered, undefined);
});
