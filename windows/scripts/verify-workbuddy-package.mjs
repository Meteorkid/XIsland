// 仅提取固定厂商包中的类/函数，在内存依赖和模拟子进程上验证；不启动 WorkBuddy。
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { StringDecoder } from 'node:string_decoder';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

if (!process.argv[2]) throw new Error('用法：node --import tsx scripts/verify-workbuddy-package.mjs <固定 Windows 安装包及解包目录>');
const auditRoot = path.resolve(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const runtimeRoot = path.join(auditRoot, 'windows/resources/app.asar.unpacked/cli/dist');
const sha256 = data => createHash('sha256').update(data).digest('hex');
const pinned = {
  'WorkBuddy-5.7.7.exe': '42f2d8120ba3900b83a80ed0d9f318b3df7b5c84b58efa7b7860b83860578d2d',
  'codebuddy-lite-wb.mjs': 'fd44e8c6250e056f9d360f5b46247a410e3aab5878e99cb09e354ab6d27949cc',
  'codebuddy-headless.js': '24421091d73247294b2a6f3371baf1750a904cdf0e56e0373e8f17b211ded695',
};
const artifacts = Object.entries(pinned).map(([name, expected]) => {
  const file = name.endsWith('.exe') ? path.join(auditRoot, name) : path.join(runtimeRoot, name);
  const bytes = readFileSync(file), hash = sha256(bytes);
  assert.equal(hash, expected, `固定资源发生变化：${name}`);
  return { name, path: file, bytes: bytes.length, sha256: hash };
});
const bytes = readFileSync(path.join(runtimeRoot, 'codebuddy-lite-wb.mjs'));
const source = bytes.toString('utf8');
const extracted = [];
function span(name, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, name);
  const end = source.indexOf(endMarker, start);
  assert.notEqual(end, -1, name);
  const text = source.slice(start, end);
  extracted.push({ name, startMarker, endMarker,
    byteOffsetZeroBased: Buffer.byteLength(source.slice(0, start)),
    byteLength: Buffer.byteLength(text), sha256: sha256(text) });
  return text;
}
const generatorPath = path.join(repository, 'windows/src/integrations/workbuddy-plugin.ts');
const { workBuddyPluginFiles } = await import(pathToFileURL(generatorPath));
const files = workBuddyPluginFiles('C:\\Program Files\\XIsland\\node.exe', 'C:\\中文 空格\\xisland-hook.cjs');
const manifest = JSON.parse(files['.codebuddy-plugin/plugin.json']);
const marketplace = JSON.parse(files['.codebuddy-plugin/marketplace.json']);
const hooks = JSON.parse(files['hooks/hooks.json']).hooks;
assert.equal(manifest.version, '0.1.1');
assert.equal(Object.keys(hooks).length, 11);
assert.ok(Object.values(hooks).every(entries => entries[0].hooks[0].timeout === 10));
const noOtherRead = file => { assert.ok(Object.hasOwn(files, file), `拒绝读取非测试文件：${file}`); return files[file]; };
const validatorSandbox = {
  es: { readFile: async file => noOtherRead(file) },
  eq: /^[A-Za-z0-9][-A-Za-z0-9._]*$/,
  eG: /^[A-Za-z0-9][-A-Za-z0-9._]*(?:@[A-Za-z0-9][-A-Za-z0-9._]*)?$/,
  eW: { validRange: () => { throw new Error('此无依赖插件不应触发semver检查'); } },
};
vm.runInNewContext(span('PluginValidator', 'let ez=class{', ';ez=plugin_validator_decorate')
  .replace('let ez=', 'globalThis.Validator='), validatorSandbox);
const validator = new validatorSandbox.Validator();
const pluginValidation = await validator.validatePluginManifestFile('.codebuddy-plugin/plugin.json');
const marketplaceValidation = await validator.validateMarketplaceManifestFile('.codebuddy-plugin/marketplace.json');
assert.equal(pluginValidation.success, true);
assert.equal(marketplaceValidation.success, true);
const hookValidator = vm.runInNewContext('new (class{' + span('HookExtensionLoader validators', 'isValidHooksConfig(t){', ';hook_loader_decorate') + ')',
  { areExtendedPluginHooksDisabled: () => false });
hookValidator.logger = { warn() {} };
assert.equal(hookValidator.isValidHooksConfig(hooks), true);

// 只为确切测试目录提供存在性结果，其他目录一律不可见；路径逻辑用厂商原函数配win32 path。
const simulatedRoot = 'C:\\XIsland-Plugins\\workbuddy-export';
const localSandbox = { el: path.win32, ed: /^[A-Za-z0-9][-A-Za-z0-9._]*$/,
  eu: new Set(['__proto__', 'prototype', 'constructor']), er: { Local: 'local' },
  es: { pathExists: async file => file === simulatedRoot } };
vm.runInNewContext(span('Local path containment functions', 'function isPathContainedInRoot', 'function resolveMarketplaceInstallDir'), localSandbox);
vm.runInNewContext(span('LocalPluginInstaller', 'let rM=class{support(t){', ';local_plugin_installer_decorate')
  .replace('let rM=', 'globalThis.LocalInstaller='), localSandbox);
const local = new localSandbox.LocalInstaller();
const resolvedPluginPath = await local.isInstalled(marketplace.plugins[0], simulatedRoot);
assert.equal(resolvedPluginPath, simulatedRoot);
assert.equal(await local.resolvePluginPath(manifest.name, './', simulatedRoot), simulatedRoot);

// 命令本身从未执行。提取原HookExecutor，所有spawn均替换为内存EventEmitter。
const timers = new Set();
const fakeTimeout = (fn, ms) => { const timer = setTimeout(fn, ms); timers.add(timer); return timer; };
const noop = () => {};
let mode = 'empty';
function fakeSpawn() {
  const child = new EventEmitter(); child.pid = 1; child.killed = false;
  child.stdout = new EventEmitter(); child.stderr = new EventEmitter(); child.stdin = new EventEmitter();
  child.stdout.destroy = child.stderr.destroy = child.stdin.destroy = child.stdin.write = noop;
  child.stdin.end = () => setImmediate(() => {
    if (mode === 'empty') child.emit('exit', 0);
    if (mode === 'async') child.stdout.emit('data', Buffer.from('{"async":true,"asyncTimeout":100,"suppressOutput":true}\n'));
  });
  child.kill = () => { child.killed = true; setImmediate(() => child.emit('exit', null)); };
  return child;
}
const executorSandbox = {
  process: { env: {}, platform: 'win32' }, setTimeout: fakeTimeout, clearTimeout,
  registerHookPid: noop, unregisterHookPid: noop, Oc: 60000,
  Ol: { t7: async () => {} }, Oa: { Pz: ({ baseEnv, env }) => ({ ...baseEnv, ...env }) },
  gq: { uF: () => true, E5: () => ({}) }, gW: { spawn: fakeSpawn }, On: { y: StringDecoder },
  fF: { mb: { USER_PROMPT_SUBMIT: 'UserPromptSubmit', PRE_TOOL_USE: 'PreToolUse', STOP: 'Stop', SUBAGENT_STOP: 'SubagentStop' } },
  g7: { R40: { createHookMessage: noop } }, Os: { d: noop },
  tryBuildDirectPowerShellHookCommand: () => ({ executable: 'FAKE-NOT-EXECUTED', args: [] }),
  buildHookSpawnOptions: () => ({}),
};
vm.runInNewContext(span('HookExecutor', 'let Od=class{async execute(', ';hook_executor_decorate')
  .replace('let Od=', 'globalThis.Executor='), executorSandbox);
const executor = new executorSandbox.Executor();
executor.logger = { info: noop, warn: noop, error: noop, debug: noop }; executor.debugService = { debug: noop };
let empty, timedOut, asyncResult, aggregatedAsync;
try {
  const run = () => executor.execute('FAKE-NOT-EXECUTED', { hook_event_name: 'UserPromptSubmit' }, { timeout: 20, hookEvent: 'UserPromptSubmit' });
  empty = await run(); mode = 'stalled'; timedOut = await run(); mode = 'async'; asyncResult = await run();
  const aggregate = vm.runInNewContext('({' + span('HookManager aggregateSettledResults', 'aggregateSettledResults(t){', 'mergeMessages(t)') + '})').aggregateSettledResults;
  aggregatedAsync = aggregate.call({ logger: { warn: noop } }, [{ status: 'fulfilled', value: asyncResult }]);
  assert.equal(empty.allowed, true); assert.equal(empty.stdout, ''); assert.equal(empty.exitCode, 0);
  assert.equal(timedOut.allowed, false); assert.equal(timedOut.exitCode, -1);
  assert.ok(aggregatedAsync.stdout.includes('"async":true'));
  assert.equal(aggregatedAsync.suppressOutput, undefined);
} finally { for (const timer of timers) clearTimeout(timer); }
const launcherSources = Object.values(hooks).map(entries => Buffer.from(entries[0].hooks[0].command.split(' -EncodedCommand ')[1], 'base64').toString('utf16le'));
const launcherChecks = {
  allStdoutAndStderrDrainedToNull: launcherSources.every(s => (s.match(/CopyToAsync\(\[System.IO.Stream\]::Null\)/g) ?? []).length === 2),
  allInputWaitBounded1000ms: launcherSources.every(s => s.includes('$inputCopy.Wait(1000)')),
  allProcessWaitBounded4000ms: launcherSources.every(s => s.includes('$p.WaitForExit(4000)')),
  noUnboundedWaitForExit: launcherSources.every(s => !s.includes('$p.WaitForExit()')),
  noUnboundedGetResult: launcherSources.every(s => !s.includes('GetAwaiter().GetResult()')),
  allNeutralExitOnCatch: launcherSources.every(s => s.endsWith('catch { }; exit 0 }')),
};
assert.ok(Object.values(launcherChecks).every(Boolean));
const anchors = {
  metadataDirectories: 'R=[".codebuddy-plugin",".workbuddy-plugin",".claude-plugin"]',
  baseMarketplaceLoad: 'async loadManifest(){', directoryMarketplace: 'let eQ=class extends eJ{',
  sourceParser: 'async parseSource(t){', hookLoader: 'let t8="hooks/hooks.json"',
  directPowerShell: 'function tryBuildDirectPowerShellHookCommand', hiddenArgs: 'function withHiddenPowerShellArgs',
  commandHook: 'async executeCommandHook(t,i,n,s,c){', localHookDispatch: 'async executeLocalHook(t,i,n,s,c){',
  sessionStart: 'async executeSessionStartHooks(t,i){', userPrompt: 'async executeUserPromptSubmitHooks(t,i){',
  preTool: 'async executePreToolUseHooks(t,i,n,s,c,p){', postTool: 'async executePostToolUseHooks(t,i,n,s,c,p,h){',
  postToolFailure: 'hook_event_name:"PostToolUseFailure"', stop: 'async executeStopHooks(t,i,n){',
  finalStop: 'async executeFinalStopHooks(t,i="completed"){', sessionEnd: 'async executeSessionEndHooks(t,i){',
  subagentStart: 'async executeSubagentStartHooks(t){', subagentStop: 'async executeSubagentStopHooks(t,i){',
  notification: 'async executeNotificationHooks(t,i,n){',
};
const report = {
  generatedAt: new Date().toISOString(), client: 'WorkBuddy Windows x64 5.7.7.40774747-2e8619da',
  classification: 'Windows official package static inspection plus isolated extracted-function checks; not Windows application execution or real-client acceptance',
  officialHistoryUrl: 'https://www.codebuddy.cn/docs/workbuddy/Download-History',
  officialPluginDocumentationUrl: 'https://www.codebuddy.cn/docs/workbuddy/Plugins',
  installerUrl: 'https://acc-1258344699.cos.ap-guangzhou.myqcloud.com/workbuddy/saas/win32-x64-user/WorkBuddy-win32-x64-user-5.7.7.40774747-2e8619da.exe',
  artifacts, repositoryInputs: ['windows/src/integrations/workbuddy-plugin.ts', 'windows/src/integrations/plan.ts'].map(relative => ({ relative, sha256: sha256(readFileSync(path.join(repository, relative))) })),
  generatedPlugin: { name: manifest.name, version: manifest.version, events: Object.keys(hooks), timeoutSeconds: 10,
    fileHashes: Object.fromEntries(Object.entries(files).map(([name, content]) => [name, sha256(content)])) },
  extractedVendorFunctions: extracted,
  staticAnchors: Object.fromEntries(Object.entries(anchors).map(([name, anchor]) => [name, { anchor, byteOffsetZeroBased: bytes.indexOf(Buffer.from(anchor)) }])),
  validation: { plugin: pluginValidation, marketplace: marketplaceValidation, hooks: true, localSource: marketplace.plugins[0].source, resolvedPluginPath, launcherStaticChecks: launcherChecks },
  isolatedExecutorChecks: { emptyOutput: empty, hostTimeout: { allowed: timedOut.allowed, exitCode: timedOut.exitCode, message: timedOut.message }, asyncOutput: asyncResult, aggregatedAsync },
  findings: [
    'Existing absolute local paths become Directory marketplaces; a string plugin source ./ resolves to the marketplace root.',
    'The default hooks/hooks.json is loaded automatically; adding the same file as a manifest hooks entry risks duplicate loading.',
    'timeout is seconds in command hook config. Synchronous host timeout returns allowed:false and can block UserPromptSubmit.',
    'The command dispatch chain does not pass config async to HookExecutor. asyncRewake is passed but not consumed by that executor in this fixed bundle.',
    'Streaming stdout async:true is implemented, but its early result retains the JSON stdout and ignores suppressOutput, so SessionStart/UserPromptSubmit can add the handshake to context.',
    'Keep empty stdout and neutral exit. The generated 0.1.1 launcher statically bounds stdin/process/drain waits and the host timeout is 10 seconds.',
  ],
  isolation: {
    vendorModuleBootstrapExecuted: false, workBuddyApplicationExecuted: false, realTasksRun: false,
    userConfigurationRead: false, credentialsRead: false, trustOrConfigurationModified: false, networkRequestsInVerificationScript: false,
    vendorFilesystem: 'readFile only reads the generated in-memory manifest map; pathExists only returns true for one fictional Windows export directory; no vendor filesystem methods have access to disk',
    vendorProcessExecution: 'spawn replaced entirely with in-memory EventEmitter; process exposes only empty env and platform win32; no require/import/fetch/client initialization is supplied to the VM',
    sourceHandling: 'Reads fixed public installer and extracted runtime to verify SHA and slices. Does not save or vendor extracted third-party function source. The repository pure generator is imported, but no export/install/apply function is called.',
  },
  limits: ['No Windows PowerShell execution', 'No WorkBuddy UI market installation/enabling', 'No real event receipt from WorkBuddy', 'No actual Windows cold-start or failure timing measurement', 'Headless SHA pinned and relevant contract inspected statically; isolated VM checks use the lite runtime'],
  reproduction: `node --import ${repository}/windows/node_modules/tsx/dist/loader.mjs ${repository}/windows/scripts/verify-workbuddy-package.mjs ${auditRoot}`,
};
const reportPath = path.join(auditRoot, 'workbuddy-windows-contract-report.json');
writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({ reportPath, pluginVersion: manifest.version, timeoutSeconds: 10, manifestValidationPassed: true, hookCount: 11, launcherStaticChecks: launcherChecks, realClientVerified: false }, null, 2));
