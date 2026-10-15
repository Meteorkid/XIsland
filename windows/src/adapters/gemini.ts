import { isRecord, parseDIMessage, utf8Length, type DIMessage, type DIResponse } from '../core/protocol';

/** Gemini NativeHookProfile 已注册的观察事件；不接管供应商审批或问答。 */
export const GEMINI_HOOK_EVENTS = [
  'SessionStart', 'BeforeAgent', 'BeforeTool', 'AfterTool', 'Notification', 'AfterAgent', 'SessionEnd', 'PreCompress',
] as const;
export interface GeminiHookContext { timestamp?: string; terminal?: string; termSessionId?: string; projectDir?: string }
export interface GeminiHookOutput { stdout: string; exitCode: 0 }
export class GeminiHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'unsupported_interaction', message: string) {
    super(message); this.name = 'GeminiHookError';
  }
}
function nativeText(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value.trim() || value.includes('\0') || utf8Length(value) > 4096) {
    throw new GeminiHookError('invalid_payload', `Invalid Gemini field: ${field}`);
  }
  return value;
}
const text = (value: unknown): string | undefined => typeof value === 'string' ? value : undefined;
function firstText(source: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) if (typeof source[key] === 'string') return source[key];
  return undefined;
}
function outputText(value: unknown): string | undefined {
  if (typeof value === 'string') return value;
  if (!isRecord(value) && !Array.isArray(value)) return undefined;
  try { return JSON.stringify(value, (_key, child: unknown) => isRecord(child)
    ? Object.fromEntries(Object.keys(child).sort().map(key => [key, child[key]])) : child); }
  catch { throw new GeminiHookError('invalid_payload', 'Gemini tool data must be JSON serializable'); }
}
function copyUsage(payload: Record<string, unknown>, message: DIMessage): void {
  const usage = isRecord(payload.usage) ? payload.usage : {};
  const integer = (...values: unknown[]): number | undefined => values.find(value => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) as number | undefined;
  message.tokensIn = integer(payload.tokens_in, payload.input_tokens, usage.input_tokens);
  message.tokensOut = integer(payload.tokens_out, payload.output_tokens, usage.output_tokens);
  message.totalTokens = integer(payload.total_tokens, usage.total_tokens);
  const cost = payload.cost_usd ?? payload.cost;
  if (typeof cost === 'number' && Number.isFinite(cost) && cost >= 0) message.costUSD = cost;
  message.model = text(payload.model);
}
function userPrompt(value: unknown): string {
  if (typeof value !== 'string') return '';
  const trimmed = value.trim();
  if (!['You are a', 'You will be', 'System:'].some(prefix => trimmed.startsWith(prefix))) return value;
  for (const separator of ['\n\nUser:', '\nUser:', '\n\n> ', '\n---\n']) {
    const index = trimmed.lastIndexOf(separator);
    if (index >= 0) { const result = trimmed.slice(index + separator.length).trim(); if (result) return result; }
  }
  const last = trimmed.split('\n').filter(Boolean).at(-1);
  return last && [...last].length < 500 ? last : '';
}

/** 事件映射以 NativeHookProfile 的 bridgeHook 和 DIBridge.makeMessage 为依据。 */
export function normalizeGeminiHook(value: unknown, context: GeminiHookContext = {}): DIMessage {
  if (!isRecord(value)) throw new GeminiHookError('invalid_payload', 'Gemini hook must be an object');
  const event = nativeText(value.hook_event_name, 'hook_event_name');
  if (!(GEMINI_HOOK_EVENTS as readonly string[]).includes(event)) throw new GeminiHookError('unsupported_event', `Unsupported Gemini event: ${event}`);
  const message: DIMessage = { type: 'status_update', sessionId: `gemini_cli-${nativeText(value.session_id, 'session_id')}`,
    agentType: 'gemini_cli', nativeEvent: event, timestamp: context.timestamp ?? new Date().toISOString(), workingDir: text(value.cwd) };
  if (typeof value.tool_use_id === 'string' && value.tool_use_id) message.toolCallId = value.tool_use_id;
  switch (event) {
    case 'SessionStart':
    case 'BeforeAgent': {
      message.type = 'session_start'; message.prompt = userPrompt(value.prompt);
      message.terminal = text(value.terminal) || context.terminal || 'Terminal'; message.termSessionId = context.termSessionId || undefined;
      const directory = firstText(value, ['working_dir', 'cwd', 'projectPath', 'workspace', 'workspaceFolder'])
        ?? (Array.isArray(value.workspace_roots) ? text(value.workspace_roots[0]) : undefined);
      message.workingDir = directory || context.projectDir; copyUsage(value, message); break;
    }
    case 'BeforeTool':
      message.type = 'tool_start'; message.tool = text(value.tool_name) ?? text(value.tool) ?? 'unknown';
      message.toolInput = outputText(value.tool_input) ?? text(value.input); break;
    case 'AfterTool':
      message.type = 'tool_complete'; message.tool = text(value.tool_name) ?? text(value.tool) ?? 'unknown';
      message.toolInput = outputText(value.tool_input);
      message.toolResult = outputText(value.tool_result) ?? outputText(value.tool_response) ?? outputText(value.result) ?? outputText(value.error);
      if (Number.isSafeInteger(value.lines_added)) message.linesAdded = value.lines_added as number;
      if (Number.isSafeInteger(value.lines_removed)) message.linesRemoved = value.lines_removed as number;
      // Swift 仅对 Tabnine AfterTool 的 error 字段声明错误状态；Gemini 不借用该分支。
      copyUsage(value, message); break;
    case 'Notification':
      message.status = firstText(value, ['message', 'status', 'text', 'last-assistant-message', 'last_assistant_message']) ?? '';
      message.statusIsAssistantReply = false;
      if (value.notification_type === 'ToolPermission' || value.notification_type === 'permission_prompt') message.observedState = 'waitingPermission';
      // idle_prompt 对 Gemini 未形成终结契约，不能改成 idle/completed。
      copyUsage(value, message); break;
    case 'AfterAgent':
      message.status = text(value.prompt_response)
        ?? firstText(value, ['message', 'status', 'text', 'last-assistant-message', 'last_assistant_message']) ?? '';
      message.observedState = 'completionUnconfirmed'; message.statusIsAssistantReply = true; copyUsage(value, message); break;
    case 'SessionEnd':
      message.type = 'session_end'; message.observedState = 'completed';
      message.status = firstText(value, ['last_assistant_message', 'message', 'response', 'result']); copyUsage(value, message); break;
    case 'PreCompress':
      message.type = 'context_compact'; message.status = text(value.message) ?? 'Context window compacting...'; copyUsage(value, message); break;
  }
  try { return parseDIMessage(message); }
  catch (error) { throw new GeminiHookError('invalid_payload', error instanceof Error ? error.message : 'Invalid Gemini message'); }
}

/** 观察 hook 的中性输出不批准命令、不回答问题、不声明已完成。 */
export function geminiHookResponse(_payload: unknown, response: DIResponse | null): GeminiHookOutput {
  if (response !== null) throw new GeminiHookError('unsupported_interaction', 'Gemini approvals and questions must remain in the native client');
  return { stdout: '{}', exitCode: 0 };
}
