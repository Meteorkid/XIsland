import { isRecord, parseDIMessage, utf8Length, type DIMessage, type DIResponse } from '../core/protocol';

/** Copilot CLI camelCase hooks；VS Code 的 PascalCase/snake_case 输入是另一种协议。 */
export const COPILOT_CLI_HOOK_EVENTS = [
  'sessionStart', 'sessionEnd', 'userPromptSubmitted', 'preToolUse', 'postToolUse',
  'postToolUseFailure', 'agentStop', 'subagentStart', 'subagentStop', 'errorOccurred',
  'preCompact', 'notification',
] as const;
export class CopilotCliHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'unsupported_interaction', message: string) {
    super(message); this.name = 'CopilotCliHookError';
  }
}
export interface CopilotCliHookContext { terminal?: string; termSessionId?: string }
function text(value: unknown, field: string, allowEmpty = true): string {
  if (typeof value !== 'string' || value.includes('\0') || (!allowEmpty && (!value.trim() || utf8Length(value) > 4096))) {
    throw new CopilotCliHookError('invalid_payload', `Invalid Copilot CLI field: ${field}`);
  }
  return value;
}
function optionalText(data: Record<string, unknown>, field: string): string | undefined {
  return data[field] === undefined ? undefined : text(data[field], field);
}
function json(value: unknown, field: string): string {
  if (value === undefined) throw new CopilotCliHookError('invalid_payload', `Missing Copilot CLI field: ${field}`);
  if (typeof value === 'string') return text(value, field);
  try {
    const encoded = JSON.stringify(value);
    if (encoded === undefined) throw new Error('invalid_json');
    return encoded;
  } catch { throw new CopilotCliHookError('invalid_payload', `Invalid Copilot CLI JSON: ${field}`); }
}

/** native_event 由受信的 --hook 参数注入；原生 camelCase stdin 没有统一事件字段。 */
export function normalizeCopilotCliHook(value: unknown, context: CopilotCliHookContext = {}): DIMessage {
  if (!isRecord(value)) throw new CopilotCliHookError('invalid_payload', 'Copilot CLI hook must be an object');
  const event = text(value.native_event, 'native_event', false);
  if (!(COPILOT_CLI_HOOK_EVENTS as readonly string[]).includes(event)) {
    throw new CopilotCliHookError('unsupported_event', `Unsupported Copilot CLI event: ${event}`);
  }
  if (value.hook_event_name !== undefined && !(event === 'notification' && value.hook_event_name === 'Notification')) {
    throw new CopilotCliHookError('invalid_payload', 'Copilot CLI camelCase hook does not accept a PascalCase event envelope');
  }
  const timestamp = value.timestamp;
  if (typeof timestamp !== 'number' || !Number.isSafeInteger(timestamp) || timestamp < 0 || timestamp > 8.64e15) {
    throw new CopilotCliHookError('invalid_payload', 'Invalid Copilot CLI timestamp');
  }
  const message: DIMessage = { type: 'status_update', sessionId: `copilot_cli-${text(value.sessionId, 'sessionId', false)}`,
    agentType: 'copilot_cli', nativeEvent: event, timestamp: new Date(timestamp).toISOString(),
    workingDir: text(value.cwd, 'cwd', false), terminal: context.terminal ?? 'GitHub Copilot CLI',
    termSessionId: context.termSessionId, statusIsAssistantReply: false };
  switch (event) {
    case 'sessionStart':
      optionalText(value, 'source'); message.type = 'session_start'; message.prompt = optionalText(value, 'initialPrompt'); break;
    case 'sessionEnd':
      optionalText(value, 'reason'); message.type = 'session_end'; message.observedState = 'completed'; break;
    case 'userPromptSubmitted':
      message.type = 'session_start'; message.prompt = text(value.prompt, 'prompt'); break;
    case 'preToolUse': {
      const tool = text(value.toolName, 'toolName', false); json(value.toolArgs, 'toolArgs');
      // 尚未通过原生权限流程且没有调用 ID，只观察准备状态，避免按名称误配并发工具。
      message.status = `Copilot CLI 准备调用：${tool}`; message.observedState = 'active'; break;
    }
    case 'postToolUse':
    case 'postToolUseFailure':
      message.type = 'tool_complete';
      message.tool = text(value.toolName, 'toolName', false); message.toolInput = json(value.toolArgs, 'toolArgs');
      // 官方输入没有稳定调用 ID；不能用工具名或猜测的字段合并并发调用。
      if (event === 'postToolUse') {
        if (!isRecord(value.toolResult)) throw new CopilotCliHookError('invalid_payload', 'Invalid Copilot CLI toolResult');
        message.toolResult = json(value.toolResult, 'toolResult');
      } else if (event === 'postToolUseFailure') {
        message.toolResult = text(value.error, 'error'); message.observedState = 'error';
      }
      break;
    case 'agentStop':
      if (value.stop_hook_active !== undefined && typeof value.stop_hook_active !== 'boolean') {
        throw new CopilotCliHookError('invalid_payload', 'Invalid Copilot CLI stop_hook_active');
      }
      optionalText(value, 'transcriptPath'); optionalText(value, 'stopReason');
      message.observedState = 'completionUnconfirmed'; break;
    case 'subagentStart':
    case 'subagentStop':
      // 起始事件不提供与结束对应的实例 ID；子任务回复也不是父会话的最终回答。
      message.status = text(value.agentName, 'agentName', false);
      optionalText(value, 'agentId'); optionalText(value, 'agentType'); optionalText(value, 'response'); break;
    case 'errorOccurred':
      if (!isRecord(value.error)) throw new CopilotCliHookError('invalid_payload', 'Invalid Copilot CLI error');
      message.status = text(value.error.message, 'error.message'); message.observedState = 'error'; break;
    case 'preCompact':
      optionalText(value, 'trigger'); optionalText(value, 'customInstructions'); message.type = 'context_compact'; break;
    case 'notification':
      message.status = text(value.message, 'message'); text(value.notification_type, 'notification_type', false);
      if (value.notification_type === 'permission_prompt') message.observedState = 'waitingPermission';
      if (value.notification_type === 'elicitation_dialog') message.observedState = 'waitingAnswer';
      // agent_idle/agent_completed 属于后台代理，不能把父会话置为空闲或已完成。
      break;
  }
  try { return parseDIMessage(message); }
  catch (error) { throw new CopilotCliHookError('invalid_payload', error instanceof Error ? error.message : 'Invalid Copilot CLI message'); }
}

/** 空输出保留 Copilot 原生权限流程，绝不生成 permissionDecision 或 behavior。 */
export function copilotCliHookResponse(_payload: unknown, response: DIResponse | null): { stdout: string; exitCode: number } {
  if (response !== null) throw new CopilotCliHookError('unsupported_interaction', 'Copilot CLI permissions and questions remain in the native client');
  return { stdout: '', exitCode: 0 };
}
