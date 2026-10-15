import type { DIMessage, DIResponse } from '../core/protocol';

type NativeObject = Record<string, unknown>;

export const CLAUDE_HOOK_EVENTS = [
  'SessionStart', 'UserPromptSubmit', 'SessionEnd', 'Stop', 'Notification',
  'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'PermissionRequest',
  'SubagentStart', 'SubagentStop', 'PreCompact',
] as const;

export class ClaudeHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'unsupported_question' | 'invalid_response', message: string) {
    super(message);
    this.name = 'ClaudeHookError';
  }
}

export interface ClaudeHookContext {
  timestamp?: string;
  terminal?: string;
  termSessionId?: string;
  projectDir?: string;
}

export interface ClaudeHookOutput {
  stdout: string;
  exitCode: 0;
}

function object(value: unknown): NativeObject | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as NativeObject : undefined;
}

function text(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function requiredText(value: unknown, field: string, allowEmpty = false): string {
  if (typeof value !== 'string' || (!allowEmpty && !value.trim())
    || value.includes('\0') || new TextEncoder().encode(value).length > 4096) {
    throw new ClaudeHookError('invalid_payload', `Invalid Claude field: ${field}`);
  }
  return value;
}

function firstText(sources: (NativeObject | undefined)[], keys: string[]): string | undefined {
  for (const source of sources) {
    for (const key of keys) {
      const value = text(source?.[key]);
      if (value) return value;
    }
  }
  return undefined;
}

function toolInput(payload: NativeObject): NativeObject {
  for (const key of ['tool_input', 'input', 'parameters', 'params', 'args']) {
    const value = payload[key];
    if (object(value)) return object(value)!;
    if (typeof value === 'string') {
      try {
        const parsed = object(JSON.parse(value));
        if (parsed) return parsed;
      } catch { /* 普通工具输入文本不属于 JSON 对象。 */ }
    }
  }
  return object(object(payload.tool)?.input) ?? {};
}

function outputText(value: unknown): string | undefined {
  if (typeof value === 'string') return value;
  if (!object(value) && !Array.isArray(value)) return undefined;
  return JSON.stringify(value, (_key, child: unknown) => {
    const record = object(child);
    return record ? Object.fromEntries(Object.keys(record).sort().map(key => [key, record[key]])) : child;
  });
}

function copyUsage(payload: NativeObject, message: DIMessage): void {
  const usage = object(payload.usage);
  const number = (...values: unknown[]) => values.find(value => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) as number | undefined;
  message.tokensIn = number(payload.tokens_in, payload.input_tokens, usage?.input_tokens);
  message.tokensOut = number(payload.tokens_out, payload.output_tokens, usage?.output_tokens);
  message.totalTokens = number(payload.total_tokens, usage?.total_tokens);
  const cost = payload.cost_usd ?? payload.cost;
  if (typeof cost === 'number' && Number.isFinite(cost) && cost >= 0) message.costUSD = cost;
  message.model = text(payload.model);
}

function userPrompt(payload: NativeObject): string {
  const raw = text(payload.prompt) ?? '';
  const trimmed = raw.trim();
  if (!['You are a', 'You will be', 'System:'].some(prefix => trimmed.startsWith(prefix))) return raw;
  for (const separator of ['\n\nUser:', '\nUser:', '\n\n> ', '\n---\n']) {
    const position = trimmed.lastIndexOf(separator);
    if (position >= 0) {
      const prompt = trimmed.slice(position + separator.length).trim();
      if (prompt) return prompt;
    }
  }
  const last = trimmed.split('\n').filter(Boolean).at(-1);
  return last && last.length < 500 ? last : '';
}

function isQuestionTool(name: string): boolean {
  const lower = name.toLowerCase();
  return ['askuser', 'ask_user', 'askquestion', 'ask_question'].some(part => lower.includes(part))
    || ['question', 'userinput', 'user_input'].includes(lower);
}

function questionDetails(payload: NativeObject): { input: NativeObject; first?: NativeObject; sources: NativeObject[] } {
  const input = toolInput(payload);
  let first: NativeObject | undefined;
  if (input.questions !== undefined) {
    if (!Array.isArray(input.questions) || input.questions.some(item => !object(item))) {
      throw new ClaudeHookError('invalid_payload', 'Invalid Claude questions');
    }
    // Swift 当前只改写首题；Windows 首批不把部分回答伪装成整组完成。
    if (input.questions.length > 1) {
      throw new ClaudeHookError('unsupported_question', 'Multiple Claude questions require the native client');
    }
    first = object(input.questions[0]);
  }
  const sources = [first, input, payload].filter((item): item is NativeObject => item !== undefined);
  if (sources.some(item => item.multiSelect === true || item.multiple === true)) {
    throw new ClaudeHookError('unsupported_question', 'Claude multi-select requires the native client');
  }
  return { input, first, sources };
}

function questionMessage(payload: NativeObject, message: DIMessage, tool: string): DIMessage {
  const { first, sources } = questionDetails(payload);
  message.type = 'question';
  const header = text(first?.header);
  const question = firstText(sources, ['question', 'text', 'message', 'description', 'prompt']);
  message.questionText = question ? `${header ? `${header}: ` : ''}${question}` : tool;
  for (const source of sources) {
    const options = source.options ?? source.choices;
    if (!Array.isArray(options)) continue;
    if (options.every(option => typeof option === 'string')) {
      message.options = options as string[];
      break;
    }
    if (options.every(option => object(option))) {
      message.options = options.map(option => firstText([object(option)], ['label', 'value', 'text', 'description']))
        .filter((option): option is string => option !== undefined);
      break;
    }
    throw new ClaudeHookError('invalid_payload', 'Invalid Claude question options');
  }
  const defaultAnswer = firstText(sources, ['default_answer', 'default']);
  if (!message.options?.length && defaultAnswer) message.options = [defaultAnswer];
  message.options ??= [];
  // 回传沿用 Swift 的单一 answer 字段，可承载选项或自由文本。
  message.allowsCustomAnswer = true;
  message.allowsMultipleAnswers = false;
  return message;
}

/** 纯协议转换；字段规则来自现有 DIBridge.swift，不读取环境或安装 hooks。 */
export function normalizeClaudeHook(value: unknown, context: ClaudeHookContext = {}): DIMessage {
  const payload = object(value);
  if (!payload) throw new ClaudeHookError('invalid_payload', 'Claude hook must be an object');
  const event = requiredText(payload.hook_event_name, 'hook_event_name');
  if (!(CLAUDE_HOOK_EVENTS as readonly string[]).includes(event)) {
    throw new ClaudeHookError('unsupported_event', `Unsupported Claude event: ${event}`);
  }
  const sessionId = `claude_code-${requiredText(payload.session_id, 'session_id')}`;
  const message: DIMessage = {
    type: 'status_update', sessionId, agentType: 'claude_code',
    timestamp: context.timestamp ?? new Date().toISOString(), nativeEvent: event,
  };
  message.workingDir = text(payload.cwd);
  message.toolCallId = text(payload.tool_use_id) || undefined;
  const tool = text(payload.tool_name) ?? text(payload.tool) ?? 'unknown';

  switch (event) {
    case 'SessionStart':
    case 'UserPromptSubmit':
      message.type = 'session_start';
      message.terminal = text(payload.terminal) || context.terminal || 'Terminal';
      message.termSessionId = context.termSessionId || undefined;
      message.workingDir = firstText([payload], ['working_dir', 'cwd', 'projectPath', 'workspace', 'workspaceFolder'])
        ?? text(Array.isArray(payload.workspace_roots) ? payload.workspace_roots[0] : undefined)
        ?? context.projectDir;
      message.prompt = userPrompt(payload);
      copyUsage(payload, message);
      break;
    case 'SessionEnd':
    case 'Stop':
      message.type = event === 'SessionEnd' ? 'session_end' : 'status_update';
      message.observedState = event === 'SessionEnd' ? 'completed' : 'completionUnconfirmed';
      message.status = firstText([payload], ['last_assistant_message', 'message', 'response', 'result']);
      if (event === 'Stop') message.statusIsAssistantReply = true;
      copyUsage(payload, message);
      break;
    case 'SubagentStart':
    case 'SubagentStop':
      message.type = event === 'SubagentStart' ? 'subagent_start' : 'subagent_end';
      message.parentSessionId = sessionId;
      message.subagentId = `claude_code-${requiredText(payload.agent_id, 'agent_id')}`;
      message.prompt = requiredText(payload.agent_type, 'agent_type', event === 'SubagentStop');
      message.statusIsAssistantReply = false;
      if (event === 'SubagentStop') message.subagentEndIsProvisional = true;
      break;
    case 'PreToolUse':
      if (isQuestionTool(tool)) return questionMessage(payload, message, tool);
      message.type = 'tool_start';
      message.tool = tool;
      message.toolInput = outputText(payload.tool_input) ?? text(payload.input);
      break;
    case 'PostToolUse':
    case 'PostToolUseFailure':
      message.type = 'tool_complete';
      message.tool = tool;
      message.toolInput = outputText(payload.tool_input);
      message.toolResult = outputText(payload.tool_result) ?? outputText(payload.tool_response)
        ?? outputText(payload.result) ?? outputText(payload.error);
      if (Number.isSafeInteger(payload.lines_added)) message.linesAdded = payload.lines_added as number;
      if (Number.isSafeInteger(payload.lines_removed)) message.linesRemoved = payload.lines_removed as number;
      if (event === 'PostToolUseFailure') message.observedState = 'error';
      copyUsage(payload, message);
      break;
    case 'PermissionRequest': {
      if (isQuestionTool(tool)) return questionMessage(payload, message, tool);
      message.type = 'permission_request';
      message.tool = tool;
      const input = toolInput(payload);
      const sources = [input, payload];
      message.permDescription = firstText(sources, ['description', 'command', 'path', 'file_path', 'pattern', 'query', 'content', 'text'])
        ?? firstText(sources, ['command', 'query', 'content', 'code', 'url', 'pattern', 'text']) ?? '';
      message.filePath = firstText(sources, ['file_path', 'path', 'filePath']);
      message.diff = text(payload.diff);
      break;
    }
    case 'PreCompact':
      message.type = 'context_compact';
      message.status = text(payload.message) ?? 'Context window compacting...';
      copyUsage(payload, message);
      break;
    case 'Notification':
      message.status = firstText([payload], ['message', 'status', 'text', 'last-assistant-message', 'last_assistant_message']) ?? '';
      message.statusIsAssistantReply = false;
      if (['ToolPermission', 'permission_prompt'].includes(String(payload.notification_type))) message.observedState = 'waitingPermission';
      else if (payload.notification_type === 'idle_prompt') message.observedState = 'idle';
      copyUsage(payload, message);
      break;
  }
  return message;
}

/** null 表示未得到用户决定，返回空 JSON，让原生客户端继续处理。 */
export function claudeHookResponse(payload: unknown, response: DIResponse | null): ClaudeHookOutput {
  if (response === null) return { stdout: '{}', exitCode: 0 };
  const message = normalizeClaudeHook(payload);
  if (response.sessionId !== message.sessionId) {
    throw new ClaudeHookError('invalid_response', 'Claude response belongs to another session');
  }
  if (message.type === 'permission_request' && response.type === 'permission_response' && typeof response.approved === 'boolean') {
    return { stdout: JSON.stringify({ hookSpecificOutput: {
      hookEventName: 'PermissionRequest', decision: { behavior: response.approved ? 'allow' : 'deny' },
    } }), exitCode: 0 };
  }
  if (message.type !== 'question' || response.type !== 'question_response'
    || typeof response.answer !== 'string' || !response.answer.trim() || response.selectedAnswers !== undefined) {
    throw new ClaudeHookError('invalid_response', 'Claude response does not match the pending interaction');
  }
  const { input, first } = questionDetails(object(payload)!);
  const updatedInput: NativeObject = { ...input, answer: response.answer };
  if (first) {
    const question = text(first.question) ?? text(first.header) ?? '';
    updatedInput.questions = [{ ...first, answer: response.answer, answers: [response.answer] }];
    if (question) updatedInput.answers = { [question]: response.answer };
  } else {
    const question = text(input.question) ?? text(object(payload)!.question) ?? '';
    if (question) updatedInput.answers = { [question]: response.answer };
  }
  // 与 DIBridge.buildClaudeCodeQuestionResponse 保持相同形状；仍须原生版本验收。
  return { stdout: JSON.stringify({ hookSpecificOutput: {
    hookEventName: message.nativeEvent, permissionDecision: 'allow', updatedInput,
  } }), exitCode: 0 };
}
