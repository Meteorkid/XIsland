import test from 'node:test';
import assert from 'node:assert/strict';
import { KIMI_CODE_HOOK_EVENTS } from '../src/adapters/kimi-code';
import { createKimiCodeConfigurationPlan, kimiCodeConfigPath, kimiCodeHookFragment,
  KIMI_CODE_HOOK_TIMEOUT_SECONDS, type KimiCodeHookEvent } from '../src/integrations/kimi-config';

const command = (event: KimiCodeHookEvent) => `powershell.exe -NoProfile -EncodedCommand ${Buffer.from(event).toString('base64')}`;
const original = '# 保留注释\r\nmodel = "local"\r\n[providers.custom]\r\nunknown = "unchanged"\r\n';
const plan = (configuration: string, operation: 'install' | 'uninstall' = 'install') =>
  createKimiCodeConfigurationPlan({ configuration, operation, commandForEvent: command });

test('Kimi Node configuration paths respect the home override and cannot target legacy Python config', () => {
  assert.equal(kimiCodeConfigPath('C:\\Users\\Example'), 'C:\\Users\\Example\\.kimi-code\\config.toml');
  assert.equal(kimiCodeConfigPath('C:\\Users\\Example', 'D:\\Kimi 数据'), 'D:\\Kimi 数据\\config.toml');
  for (const path of ['relative', '', 'C:relative', 'C:\\bad\0path', 'C:\\x:stream', 'C:\\Users\\Example\\.kimi']) {
    assert.throws(() => kimiCodeConfigPath('C:\\Users\\Example', path));
  }
});

test('Kimi TOML install and removal preserve user text byte-for-byte and are idempotent', () => {
  const installed = plan(original);
  assert.equal(installed.changed, true); assert.equal(installed.addedHandlers, 20);
  assert.equal(installed.nextText.slice(0, original.length), original);
  assert.equal((installed.nextText.match(/^\[\[hooks\]\]$/gm) ?? []).length, 20);
  assert.equal((installed.nextText.match(/^timeout = 10$/gm) ?? []).length, 20);
  assert.equal(KIMI_CODE_HOOK_TIMEOUT_SECONDS, 10);
  const same = plan(installed.nextText); assert.equal(same.changed, false); assert.equal(same.addedHandlers, 0);
  const removed = plan(installed.nextText, 'uninstall'); assert.equal(removed.nextText, original); assert.equal(removed.removedHandlers, 20);
  assert.equal(plan(original, 'uninstall').changed, false);
});

test('Kimi TOML keeps third-party hook rules and hook-looking multiline strings intact', () => {
  const thirdParty = 'text = """\n[[hooks]]\n# BEGIN XIsland:Windows:KimiCode:hooks v1\n"""\n'
    + '[[hooks]]\nevent = "Stop"\ncommand = \'echo third-party\' # retained\nmatcher = "anything"\ntimeout = 5\n';
  const installed = plan(thirdParty);
  assert.equal(installed.nextText.slice(0, thirdParty.length), thirdParty);
  assert.equal(plan(installed.nextText, 'uninstall').nextText, thirdParty);
});

test('Kimi TOML refuses ambiguous hook shapes and unfinished lexical boundaries', () => {
  for (const text of [
    'hooks = []\n', '[hooks]\n', '[[hooks.Stop]]\n', '[["hoo\\u006bs"]]\n',
    'x = "unfinished\n', 'x = [1,\n', 'x = """unfinished\n',
    '[[hooks]]\nevent = "PythonOnly"\ncommand = "echo"\n',
    '[[hooks]]\nevent = "Stop"\ncommand = "echo"\nunknown = true\n',
    '[[hooks]]\nevent = "Stop"\nevent = "Stop"\ncommand = "echo"\n',
    '[[hooks]]\nevent = "Stop"\ncommand = "echo"\ntimeout = 601\n',
    '[[hooks]]\nevent = "Stop"\ncommand = """\necho\n"""\n',
    'x = 1\rbroken = 2',
  ]) assert.throws(() => plan(text), Error, text);
});

test('Kimi TOML refuses edited markers, commands, fields, or trailing user data without deleting anything', () => {
  const installed = plan(original).nextText;
  for (const text of [
    installed.replace('timeout = 10', 'timeout = 9'),
    installed.replace('powershell.exe', 'evil.exe'),
    installed.replace('# END XIsland:Windows:KimiCode:hooks v1', '# END changed'),
    installed + '\n[extra]\nvalue = 1\n',
    installed.replace('[[hooks]]', '# custom comment\n[[hooks]]'),
  ]) assert.throws(() => plan(text, 'uninstall'));
});

test('Kimi TOML can upgrade fully verified old commands but never accepts a marker alone', () => {
  const old = (event: KimiCodeHookEvent) => `old-launcher --hook ${event}`;
  const configuration = original + kimiCodeHookFragment(old);
  assert.throws(() => plan(configuration));
  const updated = createKimiCodeConfigurationPlan({ configuration, operation: 'install', commandForEvent: command,
    ownsCommand: (candidate, event) => candidate === old(event) });
  assert.equal(updated.nextText, original + kimiCodeHookFragment(command));
  assert.equal(updated.addedHandlers, 20); assert.equal(updated.removedHandlers, 20);
  assert.throws(() => createKimiCodeConfigurationPlan({ configuration: configuration.replace(old(KIMI_CODE_HOOK_EVENTS[0]), 'other-launcher'),
    operation: 'uninstall', commandForEvent: command, ownsCommand: (candidate, event) => candidate === old(event) }));
});
