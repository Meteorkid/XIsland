import assert from 'node:assert/strict';
import test from 'node:test';
import { COPILOT_CLI_HOOK_EVENTS } from '../src/adapters/copilot-cli';
import { copilotConfigPath, copilotManagedHandlerCount, mergeCopilotConfiguration, validateCopilotConfiguration } from '../src/integrations/copilot-config';
import { windowsHookCommand } from '../src/integrations/plan';

const node = "C:\\软件 空格\\O'Brien\\node.exe", hook = 'C:\\软件 空格\\xisland-hook.cjs';
test('Copilot CLI config targets its native user hooks directory including explicit Windows home', () => {
  assert.equal(copilotConfigPath('C:\\Users\\Example'), 'C:\\Users\\Example\\.copilot\\hooks\\xisland.json');
  assert.equal(copilotConfigPath('C:\\Users\\Example', { COPILOT_HOME: 'C:\\Users\\Example\\custom' }), 'C:\\Users\\Example\\custom\\hooks\\xisland.json');
  for (const path of ['', 'relative', 'C:relative']) assert.throws(() => copilotConfigPath(path));
  assert.throws(() => copilotConfigPath('C:\\Users\\Example', { COPILOT_HOME: 'relative' }));
});

test('Copilot CLI generates version 1 flat powershell handlers with exact trusted event arguments', () => {
  const result = mergeCopilotConfiguration({}, 'install', node, hook);
  assert.equal(result.configuration.version, 1); assert.equal(result.addedHandlers, 12);
  const hooks = result.configuration.hooks as Record<string, Record<string, unknown>[]>;
  assert.deepEqual(Object.keys(hooks), [...COPILOT_CLI_HOOK_EVENTS]);
  for (const event of COPILOT_CLI_HOOK_EVENTS) {
    assert.deepEqual(hooks[event], [{ type: 'command', powershell: windowsHookCommand(node, hook, 'copilot_cli', event), timeoutSec: 10 }]);
    const command = hooks[event]![0]!.powershell as string;
    const script = Buffer.from(command.split(' -EncodedCommand ')[1]!, 'base64').toString('utf16le');
    assert.match(script, /CopyToAsync\(\[System.IO.Stream\]::Null\)/);
    assert.match(script, /WaitForExit\(4000\)/); assert.match(script, /exit 0/);
    const manifest = JSON.parse(Buffer.from(script.split('\n')[0]!.split(':')[1]!, 'base64').toString('utf8'));
    assert.deepEqual(manifest, { node, script: hook, agent: 'copilot_cli', event });
  }
  assert.equal('permissionRequest' in hooks, false);
});

test('Copilot CLI merge retains third-party commands, platform settings and disabled state', () => {
  const original = { version: 1, disableAllHooks: true, userData: { token: 'private-fixture' }, hooks: {
    sessionStart: [{ type: 'command', powershell: 'custom.ps1', timeoutSec: 42 }],
    preToolUse: [{ type: 'command', exec: 'validator.exe', args: ['--safe'] }],
    permissionRequest: [{ type: 'http', url: 'https://example.test/permission' }],
    futureHook: [{ matcher: 'x', hooks: [{ type: 'command', command: 'future' }] }],
  } };
  const installed = mergeCopilotConfiguration(original, 'install', node, hook);
  assert.equal(copilotManagedHandlerCount(installed.configuration), 12);
  assert.equal(installed.configuration.disableAllHooks, true);
  assert.deepEqual(mergeCopilotConfiguration(installed.configuration, 'install', node, hook).configuration, installed.configuration);
  const removed = mergeCopilotConfiguration(installed.configuration, 'uninstall', node, hook);
  assert.equal(removed.removable, false); assert.deepEqual(removed.configuration, original);
});

test('Copilot CLI uninstall removes only exact owned handlers and only deletes a pure generated document', () => {
  const installed = mergeCopilotConfiguration({}, 'install', node, hook).configuration;
  assert.equal(mergeCopilotConfiguration(installed, 'uninstall', node, hook).removable, true);
  const hooks = installed.hooks as Record<string, Record<string, unknown>[]>;
  const source = hooks.sessionStart![0]!;
  for (const modified of [{ ...source, bash: 'user-unix-script' }, { ...source, note: 'user modification' },
    { ...source, timeoutSec: 20 }, { ...source, powershell: (source.powershell as string) + ' user-suffix' }]) {
    const config = { version: 1, hooks: { sessionStart: [modified] } };
    assert.equal(copilotManagedHandlerCount(config), 0);
    assert.deepEqual(mergeCopilotConfiguration(config, 'uninstall', node, hook).configuration, config);
  }
});

test('Copilot CLI version and malformed hook structures fail before mutation', () => {
  for (const value of [null, [], { version: true }, { version: 2 }, { hooks: [] }, { hooks: { sessionStart: {} } },
    { hooks: { sessionStart: [null] } }, { hooks: { sessionStart: [{ type: 'command' }] } },
    { hooks: { sessionStart: [{ command: 'echo', args: 'bad' }] } }, { hooks: { sessionStart: [{ command: 'echo', timeoutSec: -1 }] } }]) {
    assert.throws(() => validateCopilotConfiguration(value));
    assert.throws(() => mergeCopilotConfiguration(value, 'install', node, hook));
  }
});
