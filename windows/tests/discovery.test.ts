import assert from 'node:assert/strict';
import test from 'node:test';
import { win32 } from 'node:path';
import { clientCandidates, discoverClient, isKimiCodeShim, isPiShim, type DiscoveryIO } from '../src/integrations/discovery';

const env = { home: 'C:\\Users\\用户', path: 'C:\\Tools;C:\\Other', appData: 'C:\\Users\\用户\\AppData\\Roaming', localAppData: 'C:\\Users\\用户\\AppData\\Local' };
const shim = '@echo off\r\nnode "%~dp0\\node_modules\\@moonshot-ai\\kimi-code\\dist\\main.mjs" %*\r\n';
const npmShim = ['@ECHO off', 'GOTO start', ':find_dp0', 'SET dp0=%~dp0', 'EXIT /b', ':start', 'SETLOCAL', 'CALL :find_dp0',
  'IF EXIST "%dp0%\\node.exe" (', '  SET "_prog=%dp0%\\node.exe"', ') ELSE (', '  SET "_prog=node"', '  SET PATHEXT=%PATHEXT:;.JS;=;%', ')',
  'endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\node_modules\\@moonshot-ai\\kimi-code\\dist\\main.mjs" %*'].join('\r\n');

test('Client discovery checks a bounded list of fixed Windows executable names only', () => {
  const candidates = clientCandidates('codex', { ...env, path: '.;relative;C:\\Tools;c:\\tools;C:\\bad\0name' });
  assert.ok(candidates.includes('C:\\Tools\\codex.exe')); assert.ok(candidates.includes('C:\\Users\\用户\\AppData\\Roaming\\npm\\codex.cmd'));
  assert.equal(candidates.filter(path => path.toLowerCase() === 'c:\\tools\\codex.exe').length, 1);
  assert.ok(!candidates.some(path => path.includes('\0') || path.startsWith('relative')));
  assert.deepEqual(clientCandidates('unknown-agent', env), []);
  assert.ok(clientCandidates('qwen', { ...env, path: Array.from({ length: 500 }, (_, i) => `C:\\Tool-${i}`).join(';') }).length <= 160);
  assert.ok(clientCandidates('cursor', env).some(path => path.endsWith('Programs\\cursor\\Cursor.exe')));
});

test('Discovery never executes a candidate and Codex prefers a directly inspectable exe', async () => {
  const io: DiscoveryIO = { isFile: async path => ['C:\\Tools\\codex.cmd', 'C:\\Other\\codex.exe'].includes(path), packageAt: async () => { throw new Error('not required'); } };
  const client = await discoverClient('codex', env, io);
  assert.equal(client.state, 'detected'); assert.equal(client.executablePath, 'C:\\Other\\codex.exe'); assert.equal(client.version, undefined);
  assert.equal((await discoverClient('claude_code', env, io)).state, 'not_found');
});

test('Kimi Code discovery verifies package name, entrypoint and the actual cmd invocation', async () => {
  const executable = 'C:\\Tools\\kimi.cmd', root = win32.join(win32.dirname(executable), 'node_modules', '@moonshot-ai', 'kimi-code');
  const io: DiscoveryIO = { isFile: async path => path === executable || path === win32.join(root, 'dist', 'main.mjs'),
    packageAt: async path => path === win32.join(root, 'package.json') ? { name: '@moonshot-ai/kimi-code', version: '1.2.3' } : null,
    readText: async () => npmShim };
  const result = await discoverClient('kimi_code', env, io);
  assert.equal(result.state, 'detected'); assert.equal(result.version, '1.2.3'); assert.equal(result.executablePath, executable);
  for (const changed of [
    { packageAt: async () => ({ name: 'kimi-cli' }) },
    { readText: async () => 'python -m kimi_cli %*' },
    { readText: async () => 'echo "node_modules\\@moonshot-ai\\kimi-code\\dist\\main.mjs"' },
    { readText: undefined },
    { isFile: async (path: string) => path === executable },
  ]) assert.equal((await discoverClient('kimi_code', env, { ...io, ...changed })).state, 'unconfirmed');
});

test('Kimi shim recognition rejects misleading comments, unreachable launch lines and modified wrappers', () => {
  assert.equal(isKimiCodeShim(shim), true); assert.equal(isKimiCodeShim(npmShim), true);
  for (const source of [shim.replace('node "', 'echo node "'), shim.replace('node "', 'rem node "'), 'exit /b\n' + shim,
    shim + 'echo another-command\n', shim.replace('dist\\main.mjs', 'dist\\other.mjs'), npmShim.replace('SET "_prog=node"', 'SET "_prog=python"'),
    npmShim.replace('SETLOCAL', 'SETLOCAL\nCALL user-script.cmd'), npmShim + '\0']) assert.equal(isKimiCodeShim(source), false);
});

test('An unrelated first Kimi command does not hide a later verified Node distribution', async () => {
  const first = 'C:\\Tools\\kimi.cmd', second = 'C:\\Other\\kimi.cmd';
  const result = await discoverClient('kimi_code', env, { isFile: async path => path === first || path === second || path.startsWith('C:\\Other\\node_modules'),
    packageAt: async () => ({ name: '@moonshot-ai/kimi-code', version: 'unexpected-version' }), readText: async path => path === first ? 'python -m kimi_cli %*' : shim });
  assert.equal(result.state, 'detected'); assert.equal(result.executablePath, second); assert.equal(result.version, undefined);
});

test('Pi discovery confirms the current official Node package and refuses legacy or unrelated pi commands', async () => {
  const executable = 'C:\\Tools\\pi.cmd';
  const root = win32.join(win32.dirname(executable), 'node_modules', '@earendil-works', 'pi-coding-agent');
  const entry = 'dist\\bundle\\cli.js';
  const source = npmShim.replaceAll('@moonshot-ai\\kimi-code\\dist\\main.mjs', '@earendil-works\\pi-coding-agent\\' + entry);
  assert.equal(isPiShim(source), true); assert.equal(isPiShim(npmShim), false); assert.equal(isKimiCodeShim(source), false);
  const io: DiscoveryIO = { isFile: async path => path === executable || path === win32.join(root, entry),
    packageAt: async () => ({ name: '@earendil-works/pi-coding-agent', version: '1.3.0' }), readText: async () => source };
  const client = await discoverClient('pi', env, io);
  assert.equal(client.state, 'detected'); assert.equal(client.version, '1.3.0');
  for (const change of [{ packageAt: async () => ({ name: '@mariozechner/pi-coding-agent' }) },
    { readText: async () => source.replace('"%_prog%"', 'echo "%_prog%"') },
    { isFile: async (path: string) => path === executable }]) {
    assert.equal((await discoverClient('pi', env, { ...io, ...change })).state, 'unconfirmed');
  }
});

test('Copilot CLI discovery includes its native binary and npm command without using VS Code installation evidence', () => {
  const candidates = clientCandidates('copilot_cli', env);
  assert.ok(candidates.includes('C:\\Users\\用户\\.copilot\\bin\\copilot.exe'));
  assert.ok(candidates.includes('C:\\Users\\用户\\AppData\\Roaming\\npm\\copilot.cmd'));
  assert.equal(candidates.some(path => /Code\.exe|extensions/i.test(path)), false);
});
