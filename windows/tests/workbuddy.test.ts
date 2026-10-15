import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, realpath, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { normalizeWorkBuddyHook, WORKBUDDY_HOOK_EVENTS, workBuddyHookResponse } from '../src/adapters/workbuddy';
import { CONFIGURABLE_AGENTS, SUPPORTED_AGENTS } from '../src/adapters/registry';
import { SessionStore } from '../src/core';
import { workBuddyPluginFiles, writeWorkBuddyPlugin } from '../src/integrations/workbuddy-plugin';

const payload = (event: string, fields = {}) => ({ hook_event_name: event, session_id: '中文/session', cwd: 'C:\\项目', ...fields });
const tool = { tool_name: 'Bash', tool_input: { command: 'dir' }, call_id: 'call-1' };

test('WorkBuddy has its own identity and every declared event maps to an observation', () => {
  assert.equal(SUPPORTED_AGENTS.includes('workbuddy'), true);
  assert.equal((CONFIGURABLE_AGENTS as readonly string[]).includes('workbuddy'), false);
  assert.equal(WORKBUDDY_HOOK_EVENTS.length, 11);
  for (const event of WORKBUDDY_HOOK_EVENTS) {
    const message = normalizeWorkBuddyHook(payload(event, { ...tool, prompt: '检查项目', final_stop_reason: 'completed', message: '', notification_type: 'permission_prompt' }));
    assert.equal(message.agentType, 'workbuddy'); assert.equal(message.terminal, 'WorkBuddy');
    assert.equal(message.sessionId, 'workbuddy-' + Buffer.from('中文/session').toString('base64'));
    assert.ok(!['permission_request', 'question_request', 'plan_request', 'session_end', 'subagent_end'].includes(message.type));
    assert.deepEqual(workBuddyHookResponse(null, null), { stdout: '', exitCode: 0 });
  }
  assert.throws(() => normalizeWorkBuddyHook(payload('PermissionRequest')));
  assert.throws(() => workBuddyHookResponse(null, { type: 'permission_response', sessionId: 'other', timestamp: new Date().toISOString(), approved: true }));
});

test('WorkBuddy tool preparation is not execution, missing IDs stay missing and conflicting IDs fail', () => {
  const before = normalizeWorkBuddyHook(payload('PreToolUse', tool));
  assert.equal(before.type, 'status_update'); assert.equal(before.tool, undefined);
  const after = normalizeWorkBuddyHook(payload('PostToolUse', { ...tool, tool_response: { ok: true } }));
  assert.equal(after.type, 'tool_complete'); assert.equal(after.toolCallId, 'call-1'); assert.equal(after.toolResult, '{"ok":true}');
  assert.equal(normalizeWorkBuddyHook(payload('PostToolUse', { ...tool, call_id: undefined })).toolCallId, undefined);
  assert.equal(normalizeWorkBuddyHook(payload('PostToolUseFailure', { ...tool, error: '失败' })).toolResult, '失败');
  for (const extra of [{ tool_use_id: 'another' }, { call_id: '' }, { tool_input: [] }]) {
    assert.throws(() => normalizeWorkBuddyHook(payload('PreToolUse', { ...tool, ...extra })));
  }
});

test('WorkBuddy Stop and child end do not finish the parent, FinalStop uses native reason', () => {
  const store = new SessionStore();
  const apply = (event: string, extra = {}) => assert.equal(store.apply(normalizeWorkBuddyHook(payload(event, extra))).accepted, true);
  const session = () => store.snapshot().sessions[0]!;
  apply('UserPromptSubmit', { prompt: '运行' });
  apply('Stop', { last_assistant_message: '中间回复' });
  assert.equal(session().status, 'completionUnconfirmed'); assert.equal(session().agentResponse, '中间回复');
  for (const event of ['SubagentStop', 'SessionEnd']) { apply(event); assert.notEqual(session().status, 'completed'); }
  apply('FinalStop', { final_stop_reason: 'completed' }); assert.equal(session().status, 'idle');
  apply('UserPromptSubmit', { prompt: '再试' });
  apply('FinalStop', { final_stop_reason: 'future_unknown_reason' }); assert.equal(session().status, 'active');
  apply('FinalStop', { final_stop_reason: 'failed' }); assert.equal(session().status, 'error');
});

test('WorkBuddy marketplace exports exact neutral Windows commands and never overwrites', async t => {
  const parent = await realpath(await mkdtemp(join(tmpdir(), 'xisland-workbuddy-')));
  t.after(() => rm(parent, { recursive: true, force: true }));
  const files = workBuddyPluginFiles('C:\\Program Files\\XIsland\\node.exe', 'C:\\中文 空格\\xisland-hook.cjs');
  const hooks = JSON.parse(files['hooks/hooks.json']!).hooks;
  assert.deepEqual(Object.keys(hooks), [...WORKBUDDY_HOOK_EVENTS]);
  for (const event of WORKBUDDY_HOOK_EVENTS) {
    const handler = hooks[event][0].hooks[0]; assert.equal(handler.timeout, 10);
    const command = Buffer.from(handler.command.split(' -EncodedCommand ')[1], 'base64').toString('utf16le');
    assert.ok(command.includes('"--agent" "workbuddy"')); assert.ok(command.includes(`"--hook" "${event}"`));
    assert.ok(command.endsWith('exit 0 }')); assert.ok(command.includes('BaseStream.CopyToAsync'));
    assert.ok(command.includes('WaitForExit(4000)')); assert.ok(command.includes('$inputCopy.Wait(1000)'));
    assert.ok(command.includes('[System.IO.Stream]::Null')); assert.ok(!command.includes('OpenStandardOutput'));
    assert.ok(!command.includes('"async"')); assert.ok(!command.includes('$p.WaitForExit()'));
  }
  assert.equal(JSON.parse(files['.codebuddy-plugin/marketplace.json']!).plugins[0].source, './');
  const destination = join(parent, 'export'); await writeWorkBuddyPlugin(destination, files);
  const original = await readFile(join(destination, 'hooks/hooks.json'), 'utf8');
  await assert.rejects(writeWorkBuddyPlugin(destination, files));
  assert.equal(await readFile(join(destination, 'hooks/hooks.json'), 'utf8'), original);
  const alias = join(parent, 'alias'); await symlink(destination, alias, 'dir');
  await assert.rejects(writeWorkBuddyPlugin(alias, files));
  await assert.rejects(writeWorkBuddyPlugin(join(parent, 'unsafe'), { ...files, '../outside': 'bad' }));
  assert.deepEqual((await readdir(parent)).sort(), ['alias', 'export']);
});
