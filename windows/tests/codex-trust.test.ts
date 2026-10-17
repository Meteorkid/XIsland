import assert from 'node:assert/strict';
import { mkdtemp, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { inspectCodexTrust, parseCodexTrust } from '../src/integrations/codex-trust';

const commands = ['owned-start', 'owned-stop'];
const hook = (command: string, trustStatus = 'trusted') => ({ command, handlerType: 'command', enabled: true, isManaged: false, currentHash: 'hash-' + command, trustStatus });
const response = (cwd: string, hooks: unknown[] = commands.map(command => hook(command))) => ({ data: [{ cwd, hooks, warnings: [], errors: [] }] });
async function fixture(t: TestContext, body: string) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'xisland-codex-probe-'))); t.after(() => rm(home, { recursive: true, force: true }));
  const script = join(home, 'probe.mjs'); await writeFile(script, body);
  return { home, script, options: { tempHome: home, testScript: script, timeoutMs: 1500 } };
}
function server(tail = ''): string {
  return `import {createInterface} from 'node:readline';import {appendFileSync} from 'node:fs';
const rl=createInterface({input:process.stdin});rl.on('line',line=>{const packet=JSON.parse(line);appendFileSync('requests.jsonl',line+'\\n');
if(packet.method==='initialize')process.stdout.write(JSON.stringify({id:1,result:{}})+'\\n');
if(packet.method==='hooks/list'){const result=${JSON.stringify(response('REPLACE_CWD'))};result.data[0].cwd=process.cwd();${tail || "process.stdout.write(JSON.stringify({id:2,result})+'\\n');"}}});`;
}

test('Codex trust requires exact enabled user-owned commands and stable native hashes', () => {
  const baseline = parseCodexTrust(response('C:\\work'), commands, 'C:\\work');
  assert.equal(baseline.state, 'granted'); assert.equal(baseline.configuredCount, 2); assert.equal(baseline.trustedCount, 2); assert.match(baseline.fingerprint!, /^[a-f0-9]{64}$/);
  const reordered = parseCodexTrust(response('c:/work', [hook(commands[1]!, 'modified'), hook(commands[0]!, 'untrusted'), hook('private unrelated')]), commands, 'C:\\work');
  assert.equal(reordered.state, 'required'); assert.equal(reordered.fingerprint, baseline.fingerprint); assert.equal(reordered.trustedCount, 0);
  const changed = parseCodexTrust(response('C:\\work', [hook(commands[0]!), { ...hook(commands[1]!), currentHash: 'changed' }]), commands, 'C:\\work');
  assert.notEqual(changed.fingerprint, baseline.fingerprint);
});

test('Codex malformed, incomplete, disabled, managed and foreign trust snapshots are never granted or leaked', () => {
  for (const hooks of [[hook(commands[0]!)], [...commands.map(command => hook(command)), hook(commands[0]!)],
    [hook(commands[0]!), { ...hook(commands[1]!), enabled: false }], [hook(commands[0]!), { ...hook(commands[1]!), isManaged: true }],
    [hook(commands[0]!), hook(commands[1]!, 'managed')], [hook(commands[0]!), { ...hook(commands[1]!), enabled: 1 }],
    [hook(commands[0]!), { ...hook(commands[1]!), currentHash: '' }], [hook(commands[0]!), hook('echo ' + commands[1])]]) {
    assert.equal(parseCodexTrust(response('C:\\work', hooks), commands, 'C:\\work').state, 'unavailable');
  }
  for (const value of [null, { data: [] }, response('C:\\elsewhere'), { data: [{ ...response('C:\\work').data[0], warnings: [1] }] },
    { data: [{ ...response('C:\\work').data[0], errors: [{ message: 'secret-token-body' }] }] }]) {
    const snapshot = parseCodexTrust(value, commands, 'C:\\work'); assert.equal(snapshot.state, 'unavailable'); assert.ok(!JSON.stringify(snapshot).includes('secret-token-body'));
  }
  assert.equal(parseCodexTrust(response('C:\\work'), [], 'C:\\work').state, 'unavailable');
});

test('Codex subprocess handshake sends only initialize, initialized and hooks/list with isolated home', async t => {
  const { home, options } = await fixture(t, server());
  const result = await inspectCodexTrust(process.execPath, home, commands, options);
  assert.equal(result.state, 'granted');
  const packets = (await readFile(join(home, 'requests.jsonl'), 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  assert.deepEqual(packets.map(packet => packet.method), ['initialize', 'initialized', 'hooks/list']);
  assert.equal(packets[1].id, undefined); assert.deepEqual(packets[2].params, { cwds: [home] });
  assert.deepEqual(packets[0].params.capabilities, { experimentalApi: true });
});

test('Codex subprocess handles chunked UTF-8 and drains large stderr without exposing either body', async t => {
  const { home, options } = await fixture(t, server(`result.data[0].warnings=['中文'];process.stderr.write(Buffer.alloc(5*1024*1024,83));
const bytes=Buffer.from(JSON.stringify({id:2,result})+'\\n');const split=bytes.indexOf(Buffer.from('中文'))+1;
process.stdout.write(bytes.subarray(0,split));setTimeout(()=>process.stdout.write(bytes.subarray(split)),10);`));
  const result = await inspectCodexTrust(process.execPath, home, commands, options);
  assert.equal(result.state, 'granted'); assert.ok(!JSON.stringify(result).includes('中文'));
});

test('Codex subprocess rejects bad UTF-8, malformed JSON, early exit, RPC error and oversized stdout', async t => {
  const cases = ["process.stdout.write(Buffer.from([255,10]));", "process.stdout.write('secret-not-json\\n');", 'process.exit(2);',
    "process.stdout.write(JSON.stringify({id:1,error:{message:'secret-error'}})+'\\n');", "process.stdout.write(Buffer.alloc(4*1024*1024+1,65));"];
  for (const body of cases) {
    const { home, options } = await fixture(t, body);
    const result = await inspectCodexTrust(process.execPath, home, commands, options);
    assert.equal(result.state, 'unavailable'); assert.ok(!JSON.stringify(result).includes('secret'));
  }
});

test('Codex subprocess timeout force-kills a server that ignores termination', async t => {
  const { home, options } = await fixture(t, "import{writeFileSync}from'node:fs';writeFileSync('pid',String(process.pid));process.on('SIGTERM',()=>{});setInterval(()=>{},100);");
  const started = Date.now(); const result = await inspectCodexTrust(process.execPath, home, commands, { ...options, timeoutMs: 250 });
  assert.equal(result.state, 'unavailable'); assert.match(result.reason!, /超时/); assert.ok(Date.now() - started < 1500);
  const pid = Number(await readFile(join(home, 'pid'), 'utf8'));
  assert.throws(() => process.kill(pid, 0));
});

test('Codex test process cannot use an external script, symlink or production home', async t => {
  const first = await fixture(t, server()), second = await fixture(t, server());
  const alias = join(first.home, 'linked.mjs'); await symlink(second.script, alias);
  for (const options of [{ testScript: first.script }, { ...first.options, testScript: second.script }, { ...first.options, testScript: alias }]) {
    assert.equal((await inspectCodexTrust(process.execPath, first.home, commands, options)).state, 'unavailable');
  }
  assert.equal((await inspectCodexTrust(process.execPath, second.home, commands, first.options)).state, 'unavailable');
  assert.equal((await inspectCodexTrust('/missing/codex.exe', first.home, commands, first.options)).state, 'unavailable');
});
