import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeCodexHook } from '../src/adapters/codex';
import { SessionStore } from '../src/core/index';
import { normalizeCodexPrompt } from '../src/core/codex-prompt';
import { sessionPromptTitle } from '../src/core/session-title';

const timestamp = '2026-10-24T00:00:00Z';
const open = '<send_user_message_question_reply>';
const close = '</send_user_message_question_reply>';
const wrapped = (answer: string): string => `${open}${JSON.stringify([{ answer, question: 'Internal question', id: 'private-id' }])}${close}`;
const hook = (prompt: string) => normalizeCodexHook({ hook_event_name: 'UserPromptSubmit', session_id: 'prompt', prompt }, { timestamp });
const legacy = (prompt: string, agentType = 'codex') => ({ type: 'session_start', sessionId: `${agentType}-prompt`,
  agentType, timestamp, prompt, workingDir: 'C:\\fixture-project' });

test('Codex reply envelopes expose answers without question metadata', () => {
  const prompt = ` \n${open}${JSON.stringify([{ answer: '  第一项  ', question: 'Internal', id: 'hidden' },
    { answer: ' \n ' }, { answer: '第二项' }])}${close}\n尾随正文 `;
  assert.equal(hook(prompt).prompt, '第一项\n第二项\n尾随正文');
  assert.equal(hook(`${open}[]${close}\n继续`).prompt, '继续');
});

test('Codex reply envelopes are normalized after legacy system prompt extraction', () => {
  assert.equal(hook(`You are a coding assistant\n\nUser: ${wrapped('修复标题')}`).prompt, '修复标题');
});

test('Codex reply envelopes use the last closing tag when answers contain that literal text', () => {
  assert.equal(hook(wrapped(`请检查 ${close} 字面量`)).prompt, `请检查 ${close} 字面量`);
});

test('Codex nested reserved envelopes converge while fenced and inline tag text stays literal', () => {
  const answer = wrapped(wrapped('保留最终答案'));
  const message = hook(answer);
  assert.equal(message.prompt, '保留最终答案');
  assert.equal(hook(message.prompt!).prompt, message.prompt);
  assert.equal(hook(wrapped(open)).prompt, '');
  let deep = 'answer';
  for (let index = 0; index < 9; index++) deep = wrapped(deep);
  assert.equal(hook(deep).prompt, '');
  for (const value of [`请检查 ${open}`, `\`\`\`xml\n${open}\n\`\`\``, '<document>keep</document>',
    '<send_user_message_question_reply_extra>keep</send_user_message_question_reply_extra>',
    '<send_user_message_question_reply key="literal">keep</send_user_message_question_reply>']) {
    assert.equal(hook(value).prompt, value);
  }
});

test('Codex empty and malformed reserved envelopes do not expose transport data', () => {
  for (const prompt of [open, `${open}[]`, `${open}{"answer":"bad shape"}${close}`, `${open}[null]${close}`,
    `${open}[{"answer":12}]${close}`, `${open}[{}]${close}`, `${open}[{"answer":"ok"},{}]${close}`,
    `${open}not json${close}metadata`, `${open}[]${close}`, wrapped(' \n ')]) {
    assert.equal(hook(prompt).prompt, '', prompt);
  }
});

test('legacy Codex session_start messages store only the reply text', () => {
  const store = new SessionStore();
  assert.equal(store.apply(legacy(wrapped('修复标题'))).accepted, true);
  const session = store.snapshot().sessions[0]!;
  assert.equal(session.prompt, '修复标题');
  assert.deepEqual(session.chatHistory.map(message => message.content), ['修复标题']);
  assert.equal(store.serialize().includes('private-id'), false);
});

test('empty reserved replies preserve the current Codex prompt and history', () => {
  const store = new SessionStore();
  store.apply(legacy('已有有效标题'));
  for (const prompt of [open, wrapped(' '), `${open}[{"answer":false}]${close}`]) store.apply(legacy(prompt));
  const session = store.snapshot().sessions[0]!;
  assert.equal(session.prompt, '已有有效标题');
  assert.deepEqual(session.chatHistory.map(message => message.content), ['已有有效标题']);
});

test('a new Codex session with an invalid reserved reply starts without a polluted prompt', () => {
  const store = new SessionStore();
  store.apply(legacy(open));
  assert.equal(store.snapshot().sessions[0]!.prompt, '');
  assert.deepEqual(store.snapshot().sessions[0]!.chatHistory, []);
});

test('other agents retain the same reply-like text unchanged', () => {
  const store = new SessionStore();
  const prompt = wrapped('Literal for another agent');
  store.apply(legacy(prompt, 'claude_code'));
  assert.equal(store.snapshot().sessions[0]!.prompt, prompt);
  assert.equal(store.snapshot().sessions[0]!.chatHistory[0]!.content, prompt);
  assert.equal(sessionPromptTitle(store.snapshot().sessions[0]!), prompt);
});

test('normalization is idempotent for reserved envelopes and preserves ordinary text byte for byte', () => {
  for (const value of [wrapped('title'), wrapped(wrapped('nested')), wrapped(open), `${open}[]${close}`, '  plain text\n',
    `\`\`\`xml\n${open}\n\`\`\``]) {
    const normalized = normalizeCodexPrompt(value);
    assert.equal(normalizeCodexPrompt(normalized), normalized);
  }
  assert.equal(normalizeCodexPrompt('  plain text\n'), '  plain text\n');
  let deepest = 'eighth level';
  for (let index = 0; index < 8; index++) deepest = wrapped(deepest);
  assert.equal(normalizeCodexPrompt(deepest), 'eighth level');
});

test('bridge and store together keep normalized answers intact without metadata in the saved history', () => {
  const store = new SessionStore();
  store.apply(hook(wrapped(wrapped('最终标题'))));
  assert.equal(store.snapshot().sessions[0]!.prompt, '最终标题');
  assert.equal(sessionPromptTitle(store.snapshot().sessions[0]!), '最终标题');
  const restored = new SessionStore();
  restored.restore(store.serialize());
  assert.equal(restored.snapshot().sessions[0]!.prompt, '最终标题');
  assert.deepEqual(restored.snapshot().sessions[0]!.chatHistory.map(message => message.content), ['最终标题']);
});

test('legacy history titles use reply text while restoration and serialization preserve the raw record', () => {
  const original = new SessionStore();
  original.apply(legacy('seed'));
  const saved = JSON.parse(original.serialize());
  const raw = wrapped('历史标题\n第二行');
  saved.sessions[0].prompt = raw;
  saved.sessions[0].chatHistory[0].content = raw;
  const restored = new SessionStore();
  restored.restore(JSON.stringify(saved));
  const session = restored.snapshot().sessions[0]!;
  assert.equal(sessionPromptTitle(session), '历史标题');
  assert.equal(session.prompt, raw);
  assert.equal(session.chatHistory[0]!.content, raw);
  const roundTrip = JSON.parse(restored.serialize());
  assert.equal(roundTrip.sessions[0].prompt, raw);
  assert.equal(roundTrip.sessions[0].chatHistory[0].content, raw);
  assert.equal(sessionPromptTitle({ agentType: 'codex', prompt: open }), '');
});
