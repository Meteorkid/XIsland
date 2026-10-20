import { isRecord, parseDIMessage, utf8Length, type DIMessage, type DIResponse } from '../core/protocol';

/** https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/ */
export const QWEN_HOOK_EVENTS = [
  'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure',
  'PermissionRequest', 'Notification', 'Stop', 'SessionEnd', 'SubagentStart', 'SubagentStop', 'PreCompact',
] as const;
export interface QwenHookContext { timestamp?: string; terminal?: string; termSessionId?: string; projectDir?: string }
export interface QwenHookOutput { stdout: string; exitCode: 0 }
export class QwenHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'invalid_response' | 'unsupported_interaction', message: string) {
    super(message); this.name = 'QwenHookError';
  }
}
function text(value: unknown, field: string, allowEmpty = true): string {
  if (typeof value !== 'string' || value.includes('\0') || (!allowEmpty && (!value.trim() || utf8Length(value) > 4096))) {
    throw new QwenHookError('invalid_payload', `Invalid Qwen field: ${field}`);
  }
  return value;
}
function optionalText(data: Record<string, unknown>, field: string): string | undefined {
  return data[field] === undefined ? undefined : text(data[field], field);
}
function checkBoolean(data: Record<string, unknown>, field: string): void {
  if (data[field] !== undefined && typeof data[field] !== 'boolean') throw new QwenHookError('invalid_payload', `Invalid Qwen field: ${field}`);
}
function toolInput(data: Record<string, unknown>): Record<string, unknown> {
  if (!isRecord(data.tool_input)) throw new QwenHookError('invalid_payload', 'Invalid Qwen field: tool_input');
  return data.tool_input;
}
function output(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value === 'string') return value;
  try { return JSON.stringify(value); }
  catch { throw new QwenHookError('invalid_payload', 'Qwen tool data must be JSON serializable'); }
}
const childSessionId = (session: string, agent: string): string => `qwen-child-${JSON.stringify([session, agent])}`;

/** Qwen 的权限 hook 有独立 decision 合同；问答工具的输入替换不等于已回答。 */
export function normalizeQwenHook(value: unknown, context: QwenHookContext = {}): DIMessage {
  if (!isRecord(value)) throw new QwenHookError('invalid_payload', 'Qwen hook must be an object');
  const event = text(value.hook_event_name, 'hook_event_name', false);
  if (!(QWEN_HOOK_EVENTS as readonly string[]).includes(event)) throw new QwenHookError('unsupported_event', `Unsupported Qwen event: ${event}`);
  const rootSessionId = `qwen-${text(value.session_id, 'session_id', false)}`;
  const agentId = value.agent_id === undefined ? undefined : text(value.agent_id, 'agent_id', false);
  const childBoundary = event === 'SubagentStart' || event === 'SubagentStop';
  // 子代理工具/权限事件复用原生 session_id，但 agent_id 指向当前子代理。
  const sessionId = agentId && !childBoundary ? childSessionId(rootSessionId, agentId) : rootSessionId;
  const message: DIMessage = { type: 'status_update', sessionId, agentType: 'qwen', nativeEvent: event,
    timestamp: context.timestamp ?? new Date().toISOString(), workingDir: optionalText(value, 'cwd') || context.projectDir,
    nativeAgentId: agentId, nativeTurnId: optionalText(value, 'prompt_id'),
    parentSessionId: agentId && !childBoundary ? rootSessionId : undefined, statusIsAssistantReply: false };
  for (const field of ['transcript_path', 'permission_mode']) optionalText(value, field);
  // tool_use_id 是内部调用标识，tool_call_id 是上游 API 标识，二者允许不同。
  message.toolCallId = value.tool_use_id === undefined ? undefined : text(value.tool_use_id, 'tool_use_id', false);
  if (value.tool_call_id !== undefined) text(value.tool_call_id, 'tool_call_id', false);

  switch (event) {
    case 'SessionStart':
    case 'UserPromptSubmit':
      message.type = 'session_start'; message.terminal = context.terminal || 'Terminal'; message.termSessionId = context.termSessionId;
      message.prompt = event === 'UserPromptSubmit' ? text(value.prompt, 'prompt') : optionalText(value, 'prompt');
      optionalText(value, 'source'); break;
    case 'PreToolUse':
    case 'PostToolUse':
    case 'PostToolUseFailure':
    case 'PermissionRequest': {
      const input = toolInput(value);
      message.tool = text(value.tool_name, 'tool_name', false); message.toolInput = output(input);
      message.filePath = optionalText(input, 'file_path');
      if (event === 'PermissionRequest') {
        // Qwen ask_user_question 的回答结构未在 command-hook 合同中定义。
        if (message.tool === 'ask_user_question' || message.tool === 'AskUserQuestion') {
          message.status = '请在 Qwen Code 中回答问题'; message.observedState = 'waitingAnswer';
        } else {
          message.type = 'permission_request';
          message.permDescription = optionalText(input, 'command') ?? optionalText(input, 'description')
            ?? message.filePath ?? message.toolInput;
          message.nativeRequestId = message.toolCallId; message.nativeRequestKind = 'permission';
        }
      } else {
        message.type = event === 'PreToolUse' ? 'tool_start' : 'tool_complete';
        if (event === 'PostToolUse') message.toolResult = output(value.tool_response);
        if (event === 'PostToolUseFailure') { message.toolResult = text(value.error, 'error'); message.observedState = 'error'; }
      }
      break;
    }
    case 'Notification':
      message.status = text(value.message, 'message');
      if (value.notification_type === 'permission_prompt') message.observedState = 'waitingPermission';
      else if (value.notification_type === 'idle_prompt') message.observedState = 'idle';
      optionalText(value, 'notification_type'); break;
    case 'Stop':
      checkBoolean(value, 'stop_hook_active'); message.status = optionalText(value, 'last_assistant_message');
      message.statusIsAssistantReply = message.status !== undefined; message.observedState = 'completionUnconfirmed'; break;
    case 'SessionEnd':
      optionalText(value, 'reason'); message.type = 'session_end'; message.observedState = 'completed'; break;
    case 'SubagentStart':
    case 'SubagentStop': {
      const child = text(value.agent_id, 'agent_id', false);
      message.type = event === 'SubagentStart' ? 'subagent_start' : 'subagent_end';
      message.parentSessionId = sessionId;
      message.subagentId = childSessionId(rootSessionId, child);
      message.prompt = text(value.agent_type, 'agent_type', false);
      if (event === 'SubagentStop') { checkBoolean(value, 'stop_hook_active'); message.subagentEndIsProvisional = true; }
      break;
    }
    case 'PreCompact':
      optionalText(value, 'trigger'); optionalText(value, 'custom_instructions');
      message.type = 'context_compact'; message.status = 'Qwen Code 正在压缩上下文'; break;
  }
  try { return parseDIMessage(message); }
  catch (error) { throw new QwenHookError('invalid_payload', error instanceof Error ? error.message : 'Invalid Qwen message'); }
}

/** 无决定时不输出 allow；客户端继续使用自己的审批机制。 */
export function qwenHookResponse(payload: unknown, response: DIResponse | null): QwenHookOutput {
  if (response === null) return { stdout: '{}', exitCode: 0 };
  const message = normalizeQwenHook(payload);
  if (response.sessionId !== message.sessionId) throw new QwenHookError('invalid_response', 'Qwen response belongs to another session');
  if (message.type !== 'permission_request') throw new QwenHookError('unsupported_interaction', 'Qwen only supports native PermissionRequest decisions');
  if (response.type !== 'permission_response' || typeof response.approved !== 'boolean') {
    throw new QwenHookError('invalid_response', 'Qwen response does not match the pending permission');
  }
  return { stdout: JSON.stringify({ hookSpecificOutput: { hookEventName: 'PermissionRequest',
    decision: { behavior: response.approved ? 'allow' : 'deny' } } }), exitCode: 0 };
}
