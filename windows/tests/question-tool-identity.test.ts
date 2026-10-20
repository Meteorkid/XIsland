import assert from 'node:assert/strict';
import test from 'node:test';
import { ClaudeHookError, claudeHookResponse, normalizeClaudeHook } from '../src/adapters/claude';

const question = { question: 'Continue?', options: ['Yes', 'No'] };
const payload = (tool_name = 'AskUserQuestion', tool_input: unknown = question, hook_event_name = 'PreToolUse') =>
  ({ tool_name, tool_input, hook_event_name, session_id: 'fixture' });
const response = { type: 'question_response' as const, sessionId: 'claude_code-fixture', timestamp: new Date().toISOString(), answer: 'No' };

test('third-party names and lookalikes cannot authorize a tool by answering a question', () => {
  for (const name of ['mcp__fixture__ask_user_run_command', 'mcp__fixture__AskUserQuestion', 'AskUserQuestionExtra',
    'askuserquestion', 'ask_user', 'question', 'userinput']) {
    const input = { ...question, command: 'printf fixture' };
    const before = payload(name, input);
    assert.equal(normalizeClaudeHook(before).type, 'tool_start', name);
    assert.equal(normalizeClaudeHook(payload(name, input, 'PermissionRequest')).type, 'permission_request', name);
    assert.throws(() => claudeHookResponse(before, response), ClaudeHookError);
  }
});

test('unsupported built-in question shapes never produce an allow response', () => {
  for (const input of [
    { questions: [] }, { questions: [question, question] }, { questions: [{ ...question, multiSelect: true }] },
    { question: '  ', options: ['Yes'] }, { description: 'Benign', command: 'printf fixture' },
    { question: 'Continue?', options: [1] }, { question: 'Continue?', options: [{ description: 'missing label' }] },
    { ...question, command: 'printf fixture' },
  ]) {
    for (const hook of ['PreToolUse', 'PermissionRequest']) {
      const native = payload('AskUserQuestion', input, hook);
      assert.throws(() => normalizeClaudeHook(native), ClaudeHookError);
      assert.throws(() => claudeHookResponse(native, response), ClaudeHookError);
    }
  }
});

test('PermissionRequest answers use the native decision envelope', () => {
  const output = JSON.parse(claudeHookResponse(payload('AskUserQuestion', question, 'PermissionRequest'), response).stdout).hookSpecificOutput;
  assert.equal(output.permissionDecision, undefined);
  assert.equal(output.decision.behavior, 'allow');
  assert.equal(output.decision.updatedInput.answers['Continue?'], 'No');
});

test('option byte limits are checked before showing a question that cannot deliver its answer', () => {
  for (const label of ['x'.repeat(8193), '中'.repeat(2731)]) {
    assert.throws(() => normalizeClaudeHook(payload('AskUserQuestion', { question: 'Continue?', options: [label] })), ClaudeHookError);
  }
  const label = 'x'.repeat(8192);
  const native = payload('AskUserQuestion', { question: 'Continue?', options: [label] });
  assert.equal(normalizeClaudeHook(native).type, 'question');
  assert.equal(JSON.parse(claudeHookResponse(native, { ...response, answer: label }).stdout).hookSpecificOutput.permissionDecision, 'allow');
});
