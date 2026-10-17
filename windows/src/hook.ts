import { spawn } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { adapterFor, CONFIGURABLE_AGENTS, MANAGED_AGENTS, type ManagedAgent, type ConfigurableAgent, type HookAdapter, type HookOutput } from './adapters/registry';
import { exportWorkBuddyPlugin, prepareWorkBuddyPlugin, workBuddySetupStatus } from './integrations/workbuddy-plugin';
import { prepareKiroPlugin, kiroSetupStatus } from './integrations/kiro-plugin';
import { isRecord, MAX_MESSAGE_BYTES, parseDIMessage, type DIMessage, type DIResponse } from './core/protocol';
import { createIntegrationPlan, integrationPlanSummary } from './integrations/plan';
import { IntegrationError, type IntegrationOperation } from './integrations/installer';
import { integrationService, readManagedStatus } from './integrations/service';
import { connectionIdentity, recordAcceptedIntegrationActivity, type ConnectionActivityReceipt } from './integrations/connection-health';

function argumentsMap(args: string[]): Map<string, string> {
  const allowed = new Set(['--agent', '--hook', '--managed-by', '--test-bridge-script', '--plan', '--home', '--node', '--script', '--operation', '--expected-revision', '--configuration-revision', '--runtime-fingerprint']);
  const flags = new Set(['--integration-status', '--integration-plan', '--integration-apply', '--workbuddy-export', '--workbuddy-prepare', '--workbuddy-status', '--kiro-prepare', '--kiro-status', '--record-accepted-activity']);
  const result = new Map<string, string>();
  for (let index = 0; index < args.length; index++) {
    const key = args[index]!;
    if (result.has(key)) throw new Error('invalid_arguments');
    if (flags.has(key)) { result.set(key, '1'); continue; }
    const value = args[++index];
    if (!allowed.has(key) || value === undefined) throw new Error('invalid_arguments');
    result.set(key, value);
  }
  return result;
}

async function readInput(): Promise<unknown> {
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += bytes.length;
    if (size > MAX_MESSAGE_BYTES) {
      process.stdin.destroy();
      throw new Error('input_too_large');
    }
    chunks.push(bytes);
  }
  const input = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size));
  return JSON.parse(input);
}

function bridgeCommand(testScript?: string): { executable: string; args: string[] } {
  if (testScript !== undefined) {
    if (process.env.XISLAND_TEST_MODE !== '1' || !isAbsolute(testScript)) throw new Error('test_bridge_not_allowed');
    const script = realpathSync(testScript), temporary = realpathSync(tmpdir());
    const path = relative(temporary, script);
    // 只能运行临时目录独立子目录中的测试脚本，不允许根目录文件或链接逃逸。
    if (!path || path.startsWith('..') || isAbsolute(path) || dirname(path) === '.' || !/\.[cm]?js$/.test(script)) {
      throw new Error('test_bridge_not_isolated');
    }
    return { executable: process.execPath, args: [script] };
  }
  const directory = dirname(resolve(process.argv[1]!));
  const executable = join(directory, process.platform === 'win32' ? 'xisland-bridge.exe' : 'xisland-bridge');
  if (!existsSync(executable)) throw new Error('bridge_missing');
  return { executable, args: [] };
}

async function bridge(message: DIMessage, testScript?: string, timeoutMs = 125_000, activityReceipt?: ConnectionActivityReceipt): Promise<DIResponse | null> {
  const command = bridgeCommand(testScript);
  return new Promise((resolveResponse, reject) => {
    const child = spawn(command.executable, command.args, { shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    const chunks: Buffer[] = [];
    let size = 0, done = false;
    const timer = setTimeout(() => { child.kill(); finish(new Error('bridge_timeout')); }, timeoutMs);
    function finish(error?: Error) {
      if (done) return;
      done = true; clearTimeout(timer);
      if (error) { reject(error); return; }
      try {
        const value: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size)));
        if (isRecord(value) && value.ok === true) { resolveResponse(null); return; }
        const response = parseDIMessage(value);
        if (!['permission_response', 'question_response', 'plan_response'].includes(response.type)) throw new Error('unexpected_response');
        resolveResponse(response as DIResponse);
      } catch { reject(new Error('invalid_bridge_response')); }
    }
    child.on('error', () => finish(new Error('bridge_start_failed')));
    child.stdout.on('data', (data: Buffer) => {
      size += data.length;
      if (size > MAX_MESSAGE_BYTES) { child.kill(); finish(new Error('response_too_large')); }
      else chunks.push(data);
    });
    // stderr 不转印，避免桥接错误夹带原生输入、密钥或完整会话正文。
    child.stderr.resume();
    child.stdin.on('error', () => finish(new Error('bridge_input_closed')));
    child.on('close', code => finish(code === 0 ? undefined : new Error('bridge_unavailable')));
    // 元数据只能来自本进程投递前的读取，原生输入中的同名字段不能进入信任边界。
    child.stdin.end(JSON.stringify({ ...message, __xislandActivity: activityReceipt }));
  });
}

function writeOutput(output: HookOutput): void {
  if (output.stdout) process.stdout.write(output.stdout + '\n');
  process.exitCode = output.exitCode;
}

async function main(): Promise<void> {
  let payload: unknown, adapter: HookAdapter | undefined, expectedEvent: string | undefined;
  let eventField = 'hook_event_name';
  let planning = false;
  const serviceMode = process.argv.slice(2).some(value => value.startsWith('--integration-') || value.startsWith('--workbuddy-') || value.startsWith('--kiro-') || value === '--record-accepted-activity');
  try {
    const args = argumentsMap(process.argv.slice(2));
    adapter = adapterFor(args.get('--agent') ?? 'claude_code');
    if (args.has('--kiro-status') || args.has('--kiro-prepare')) {
      if (args.size !== 2 || args.get('--agent') !== 'kiro') throw new Error('invalid_arguments');
      writeOutput({ stdout: JSON.stringify(args.has('--kiro-status') ? await kiroSetupStatus() : await prepareKiroPlugin()), exitCode: 0 });
      return;
    }
    if (args.has('--record-accepted-activity')) {
      if (process.platform !== 'win32' || process.env.XISLAND_TEST_MODE === '1') throw new Error('unsupported_platform');
      const agent = args.get('--agent'), event = args.get('--hook');
      const configurationRevision = args.get('--configuration-revision'), runtimeFingerprint = args.get('--runtime-fingerprint');
      if (args.size !== 5 || !agent || !(MANAGED_AGENTS as readonly string[]).includes(agent)
        || !event || !adapter.events.includes(event) || !configurationRevision || !/^[a-f0-9]{64}$/.test(configurationRevision)
        || !runtimeFingerprint || !/^[a-f0-9]{64}$/.test(runtimeFingerprint)) throw new Error('invalid_activity_receipt');
      const recorded = await recordAcceptedIntegrationActivity(await readManagedStatus(agent as ManagedAgent),
        { agent, event, configurationRevision, runtimeFingerprint });
      writeOutput({ stdout: JSON.stringify({ recorded }), exitCode: 0 });
      return;
    }
    if (['--workbuddy-export', '--workbuddy-prepare', '--workbuddy-status'].some(flag => args.has(flag))) {
      if (args.size !== 2 || args.get('--agent') !== 'workbuddy') throw new Error('invalid_arguments');
      const result = args.has('--workbuddy-status') ? await workBuddySetupStatus()
        : args.has('--workbuddy-prepare') ? await prepareWorkBuddyPlugin() : await exportWorkBuddyPlugin();
      writeOutput({ stdout: JSON.stringify(result), exitCode: 0 });
      return;
    }
    eventField = args.get('--agent') === 'windsurf' ? 'agent_action_name' : args.get('--agent') === 'opencode' ? 'native_event' : 'hook_event_name';
    expectedEvent = args.get('--hook');
    planning = args.has('--plan');
    if (serviceMode) {
      if (!(MANAGED_AGENTS as readonly string[]).includes(args.get('--agent') ?? 'claude_code')) throw new Error('unsupported_configuration_agent');
      const flags = ['--integration-status', '--integration-plan', '--integration-apply'].filter(flag => args.has(flag));
      if (flags.length !== 1 || [...args.keys()].some(key => ![...flags, '--agent', '--operation', '--expected-revision'].includes(key))) throw new Error('invalid_arguments');
      const operation = args.get('--operation') ?? 'install';
      if (!['install', 'uninstall'].includes(operation)) throw new Error('invalid_operation');
      const agent = (args.get('--agent') ?? 'claude_code') as ManagedAgent;
      const action = flags[0] === '--integration-status' ? 'status' : flags[0] === '--integration-plan' ? 'plan' : 'apply';
      const result = await integrationService(agent, action, operation as IntegrationOperation, args.get('--expected-revision') ?? '');
      writeOutput({ stdout: JSON.stringify(result), exitCode: 0 });
      return;
    }
    payload = await readInput();
    if (planning) {
      if (!(CONFIGURABLE_AGENTS as readonly string[]).includes(args.get('--agent') ?? 'claude_code')) throw new Error('unsupported_configuration_agent');
      const operation = args.get('--plan');
      if (operation !== 'install' && operation !== 'uninstall') throw new Error('invalid_plan_operation');
      const plan = createIntegrationPlan({
        agent: (args.get('--agent') ?? 'claude_code') as ConfigurableAgent, operation,
        homeDirectory: args.get('--home') ?? '', nodeExecutable: args.get('--node') ?? '', hookScript: args.get('--script') ?? '',
        configuration: payload,
      });
      // CLI 仅展示摘要；含原配置的 nextConfig 只由受控调用方取得，避免凭据进入终端日志。
      writeOutput({ stdout: JSON.stringify(integrationPlanSummary(plan)), exitCode: 0 });
      return;
    }
    if (expectedEvent && (!isRecord(payload) || payload[eventField] !== expectedEvent)) throw new Error('hook_event_mismatch');
    const message = adapter.normalize(payload);
    let identity: Awaited<ReturnType<typeof connectionIdentity>>;
    if (process.platform === 'win32' && process.env.XISLAND_TEST_MODE !== '1' && (MANAGED_AGENTS as readonly string[]).includes(args.get('--agent') ?? 'claude_code')) {
      try { identity = await connectionIdentity(await readManagedStatus((args.get('--agent') ?? 'claude_code') as ManagedAgent)); }
      catch { /* 状态检查失败不能阻断原客户端的事件或审批。 */ }
    }
    const activityEvent = isRecord(payload) ? payload[eventField] : undefined;
    const activityReceipt = identity && typeof activityEvent === 'string'
      ? { ...identity, event: activityEvent } : undefined;
    const response = await bridge(message, args.get('--test-bridge-script'), adapter.timeoutMs, activityReceipt);
    const output = adapter.respond(payload, response);
    writeOutput(output);
  } catch (error) {
    if (serviceMode) {
      const code = error instanceof IntegrationError ? error.code : error instanceof Error
        && ['modified_workbuddy_artifact', 'modified_kiro_artifact', 'unsafe_export_directory'].includes(error.message) ? error.message : 'integration_failed';
      const message = error instanceof IntegrationError ? error.message : '接入配置操作未完成，请重新检查状态。';
      writeOutput({ stdout: JSON.stringify({ error: { code, message } }), exitCode: 1 });
      return;
    }
    process.stderr.write('XIsland: 本次接入未完成，请在原客户端继续；未记录原生输入内容。\n');
    if (planning || !adapter) { process.exitCode = 1; return; }
    const fallbackPayload = expectedEvent ? { [eventField]: expectedEvent } : payload;
    try { writeOutput(adapter.respond(fallbackPayload, null)); }
    catch { process.exitCode = 1; }
  }
}

void main();
