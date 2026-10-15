import assert from 'node:assert/strict';
import test from 'node:test';
import { adapterFor, CONFIGURABLE_AGENTS } from '../src/adapters/registry';
import { createIntegrationPlan, integrationPlanSummary, windowsHookCommand } from '../src/integrations/plan';

const paths = { homeDirectory: 'C:\\Users\\测试', nodeExecutable: 'C:\\Program Files\\nodejs\\node.exe', hookScript: 'C:\\Users\\测试\\X Island\\hook.cjs' };
const decode = (command: string) => Buffer.from(command.split(' -EncodedCommand ')[1]!, 'base64').toString('utf16le');

test('all registered clients use their own file structure and installation is idempotent', () => {
  for (const agent of CONFIGURABLE_AGENTS) {
    const original = { theme: 'keep', hooks: { CustomEvent: [{ custom: 'untouched' }] } };
    const plan = createIntegrationPlan({ ...paths, agent, operation: 'install', configuration: original });
    assert.equal(plan.addedHandlers, adapterFor(agent).events.length);
    assert.equal(plan.backup.required, true);
    assert.deepEqual(plan.nextConfig.theme, 'keep');
    assert.deepEqual((plan.nextConfig.hooks as Record<string, unknown>).CustomEvent, original.hooks.CustomEvent);
    assert.deepEqual(original, { theme: 'keep', hooks: { CustomEvent: [{ custom: 'untouched' }] } });
    const again = createIntegrationPlan({ ...paths, agent, operation: 'install', configuration: plan.nextConfig });
    assert.equal(again.changed, false);
    assert.equal(again.backup.required, false);
    assert.deepEqual(again.nextConfig, plan.nextConfig);
    const removed = createIntegrationPlan({ ...paths, agent, operation: 'uninstall', configuration: plan.nextConfig });
    assert.deepEqual((removed.nextConfig.hooks as Record<string, unknown>).CustomEvent, original.hooks.CustomEvent);
    assert.equal(removed.removedHandlers, adapterFor(agent).events.length);
    const twice = createIntegrationPlan({ ...paths, agent, operation: 'uninstall', configuration: removed.nextConfig });
    assert.equal(twice.changed, false);
  }
});

test('Windsurf uses native PowerShell fields and preserves foreign or mixed-platform entries', () => {
  const foreign = { command: 'user-bash-script', powershell: 'user-windows-script', show_output: true };
  const plan = createIntegrationPlan({ ...paths, agent: 'windsurf', operation: 'install', configuration: { hooks: { pre_user_prompt: [foreign] } } });
  assert.ok(plan.configPath.endsWith('\\.codeium\\windsurf\\hooks.json'));
  const entries = (plan.nextConfig.hooks as Record<string, Record<string, unknown>[]>).pre_user_prompt;
  assert.deepEqual(entries[0], foreign);
  assert.deepEqual(Object.keys(entries[1]!).sort(), ['powershell', 'show_output']);
  assert.equal(entries[1]!.show_output, false);
  assert.ok(decode(entries[1]!.powershell as string).includes('"windsurf"'));
  const removal = createIntegrationPlan({ ...paths, agent: 'windsurf', operation: 'uninstall', configuration: plan.nextConfig });
  assert.deepEqual((removal.nextConfig.hooks as Record<string, unknown>).pre_user_prompt, [foreign]);
});

test('Trae profile is explicitly CN, nested command handlers retain matcher and loop metadata', () => {
  const foreign = { matcher: 'Read', hooks: [{ type: 'command', command: 'keep-me' }] };
  const plan = createIntegrationPlan({ ...paths, agent: 'trae_cn', operation: 'install', configuration: { version: 1, hooks: { PreToolUse: [foreign], Stop: [{ loop_limit: 2, hooks: [{ command: 'keep-stop' }] }] } } });
  assert.ok(plan.configPath.endsWith('\\.trae-cn\\hooks.json'));
  const groups = (plan.nextConfig.hooks as Record<string, { hooks: { timeout: number; command: string }[] }[]>).PreToolUse;
  assert.deepEqual(groups[0], foreign); assert.equal(groups[1]!.hooks[0]!.timeout, 5);
  const removed = createIntegrationPlan({ ...paths, agent: 'trae_cn', operation: 'uninstall', configuration: plan.nextConfig });
  assert.deepEqual((removed.nextConfig.hooks as Record<string, unknown>).PreToolUse, [foreign]);
  assert.deepEqual((removed.nextConfig.hooks as Record<string, unknown>).Stop, [{ loop_limit: 2, hooks: [{ command: 'keep-stop' }] }]);
  assert.throws(() => createIntegrationPlan({ ...paths, agent: 'trae_cn', operation: 'install', configuration: { version: 2 } }));
});

test('mixed matcher groups keep third-party handlers and every unrelated setting', () => {
  const initial = createIntegrationPlan({ ...paths, agent: 'claude_code', operation: 'install' });
  const own = ((initial.nextConfig.hooks as Record<string, { hooks: unknown[] }[]>).SessionStart![0]!).hooks[0];
  const third = { type: 'command', command: 'echo user-hook', timeout: 1 };
  const original = { apiKey: 'private', hooks: { SessionStart: [{ matcher: 'startup', hooks: [third, own], custom: true }] } };
  const plan = createIntegrationPlan({ ...paths, agent: 'claude_code', operation: 'uninstall', configuration: original });
  assert.deepEqual(plan.nextConfig, { apiKey: 'private', hooks: { SessionStart: [{ matcher: 'startup', hooks: [third], custom: true }] } });
  assert.equal(JSON.stringify(integrationPlanSummary(plan)).includes('private'), false);
});

test('uninstall recognizes exact generated commands, not similar names or altered scripts', () => {
  const command = windowsHookCommand(paths.nodeExecutable, paths.hookScript, 'cursor', 'preToolUse');
  const unrelated = [{ command: 'echo XIsland' }, { command: command + ' & echo custom' }, { command: 'di-bridge --agent cursor' }];
  const original = { version: 1, hooks: { preToolUse: [...unrelated, { command, type: 'command' }] } };
  const plan = createIntegrationPlan({ ...paths, agent: 'cursor', operation: 'uninstall', configuration: original });
  assert.deepEqual((plan.nextConfig.hooks as Record<string, unknown>).preToolUse, unrelated);
  assert.equal(plan.removedHandlers, 1);
});

test('Gemini milliseconds, disabled metadata and feature toggle are preserved', () => {
  const original = { hooksConfig: { enabled: false }, hooks: { disabled: ['third-party'], customOption: true } };
  const plan = createIntegrationPlan({ ...paths, agent: 'gemini_cli', operation: 'install', configuration: original });
  const hooks = plan.nextConfig.hooks as Record<string, unknown>;
  const handler = (hooks.BeforeTool as { hooks: { timeout: number }[] }[])[0]!.hooks[0]!;
  assert.equal(handler.timeout, 5000);
  assert.deepEqual(hooks.disabled, ['third-party']); assert.equal(hooks.customOption, true);
  assert.deepEqual(plan.nextConfig.hooksConfig, { enabled: false });
  assert.equal(plan.warnings.some(value => value.includes('关闭了 hooks')), true);
});

test('Cursor flat entries and Codex Windows command override retain native schema', () => {
  const cursor = createIntegrationPlan({ ...paths, agent: 'cursor', operation: 'install' });
  assert.equal(cursor.nextConfig.version, 1);
  const flat = (cursor.nextConfig.hooks as Record<string, { command: string; timeout: number; hooks?: unknown; failClosed?: boolean }[]>).beforeReadFile![0]!;
  assert.equal(flat.timeout, 130); assert.equal(flat.hooks, undefined); assert.equal(flat.failClosed, true);
  const codex = createIntegrationPlan({ ...paths, agent: 'codex', operation: 'install' });
  const handler = (codex.nextConfig.hooks as Record<string, { hooks: { command: string; commandWindows: string }[] }[]>).PermissionRequest![0]!.hooks[0]!;
  assert.equal(handler.command, handler.commandWindows);
  assert.equal(codex.configPath.endsWith('\\.codex\\hooks.json'), true);
});

test('Windows launcher quotes paths without exposing shell metacharacters to the outer shell', () => {
  const node = "C:\\Tools\\O'Brien & %PATH%\\node.exe";
  const script = 'C:\\用户\\$([bad]) `bang!\\hook.cjs';
  const command = windowsHookCommand(node, script, 'claude_code', 'SessionStart');
  assert.match(command, /^powershell\.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand [A-Za-z0-9+/]+=*$/);
  const source = decode(command);
  assert.equal(source.includes("O''Brien & %PATH%"), true);
  assert.equal(source.includes('$p.StartInfo.UseShellExecute = $false'), true);
  assert.equal(source.includes('StandardOutput.BaseStream.CopyToAsync'), true);
  assert.equal(source.includes('exit $code'), true);
  assert.equal(source.includes('--managed-by'), true);
  assert.equal(command.includes('%PATH%'), false);
});

test('malformed known hooks or unsafe paths reject the plan without mutation', () => {
  for (const configuration of [{ hooks: [] }, { hooks: { SessionStart: {} } }, { hooks: { SessionStart: [{ hooks: [{ type: 'command', command: 5 }] }] } }]) {
    const before = JSON.stringify(configuration);
    assert.throws(() => createIntegrationPlan({ ...paths, agent: 'claude_code', operation: 'install', configuration }));
    assert.equal(JSON.stringify(configuration), before);
  }
  for (const nodeExecutable of ['node.exe', 'C:node.exe', 'C:\\bad\nname.exe', 'C:\\x".exe', 'C:\\file.cmd']) {
    assert.throws(() => createIntegrationPlan({ ...paths, agent: 'codex', operation: 'install', nodeExecutable }));
  }
});

test('new file needs no backup, existing changes require exclusive backup intent', () => {
  const fresh = createIntegrationPlan({ ...paths, agent: 'claude_code', operation: 'install' });
  assert.equal(fresh.backup.required, false);
  const existing = createIntegrationPlan({ ...paths, agent: 'claude_code', operation: 'install', configuration: { disableAllHooks: true } });
  assert.equal(existing.backup.required, true); assert.equal(existing.backup.exclusive, true);
  assert.equal(existing.nextConfig.disableAllHooks, true);
});
