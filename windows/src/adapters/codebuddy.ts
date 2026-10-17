import { isRecord, parseDIMessage, utf8Length, type DIMessage, type DIResponse } from '../core/protocol';

/** CodeBuddy Code CLI 的已定义观察合同：https://www.codebuddy.ai/docs/cli/hooks */
export const CODEBUDDY_HOOK_EVENTS = [
  'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Notification',
  'Stop', 'SubagentStop', 'PreCompact', 'PostCompact', 'SessionEnd',
] as const;
export interface CodeBuddyHookContext { timestamp?: string; terminal?: string; termSessionId?: string; projectDir?: string }
export interface CodeBuddyHookOutput { stdout: string; exitCode: 0 }
export class CodeBuddyHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'unsupported_interaction', message: string) {
    super(message); this.name = 'CodeBuddyHookError';
  }
}
function text(value: unknown, field: string, allowEmpty = true): string {
  if (typeof value !== 'string' || value.includes('\0') || (!allowEmpty && (!value.trim() || utf8Length(value) > 4096))) {
    throw new CodeBuddyHookError('invalid_payload', `Invalid CodeBuddy field: ${field}`);
  }
  return value;
}
function optionalText(data: Record<string, unknown>, field: string): string | undefined {
  return data[field] === undefined ? undefined : text(data[field], field);
}
function objectJSON(value: unknown, field: string): string {
  if (!isRecord(value)) throw new CodeBuddyHookError('invalid_payload', `Invalid CodeBuddy field: ${field}`);
  try { return JSON.stringify(value); }
  catch { throw new CodeBuddyHookError('invalid_payload', `CodeBuddy ${field} must be JSON serializable`); }
}

/** 不把 CLI 的 generation_id 当成 session 或 tool ID，也不套用 WorkBuddy 的桌面事件。 */
export function normalizeCodeBuddyHook(value: unknown, context: CodeBuddyHookContext = {}): DIMessage {
  if (!isRecord(value)) throw new CodeBuddyHookError('invalid_payload', 'CodeBuddy hook must be an object');
  const event = text(value.hook_event_name, 'hook_event_name', false);
  if (!(CODEBUDDY_HOOK_EVENTS as readonly string[]).includes(event)) throw new CodeBuddyHookError('unsupported_event', `Unsupported CodeBuddy event: ${event}`);
  const message: DIMessage = { type: 'status_update', sessionId: `code_buddy-${text(value.session_id, 'session_id', false)}`,
    agentType: 'code_buddy', nativeEvent: event, timestamp: context.timestamp ?? new Date().toISOString(),
    workingDir: optionalText(value, 'cwd') || context.projectDir, terminal: context.terminal || 'Terminal',
    termSessionId: context.termSessionId, nativeTurnId: optionalText(value, 'generation_id'), statusIsAssistantReply: false };
  for (const field of ['transcript_path', 'permission_mode']) optionalText(value, field);
  switch (event) {
    case 'SessionStart': message.type = 'session_start'; optionalText(value, 'source'); break;
    case 'UserPromptSubmit': message.type = 'session_start'; message.prompt = text(value.prompt, 'prompt'); break;
    case 'PreToolUse':
    case 'PostToolUse':
      message.type = event === 'PreToolUse' ? 'tool_start' : 'tool_complete';
      message.tool = text(value.tool_name, 'tool_name', false); message.toolInput = objectJSON(value.tool_input, 'tool_input');
      message.filePath = optionalText(value.tool_input as Record<string, unknown>, 'file_path');
      // 文档未为该 CLI 定义稳定 tool ID；不借用 generation_id/call_id/message_id。
      if (event === 'PostToolUse') message.toolResult = objectJSON(value.tool_response, 'tool_response');
      break;
    case 'Notification':
      message.status = text(value.message, 'message'); text(value.notification_type, 'notification_type', false);
      if (value.notification_type === 'permission_prompt') message.observedState = 'waitingPermission';
      else if (value.notification_type === 'idle_prompt') message.observedState = 'idle';
      break;
    case 'Stop':
    case 'SubagentStop':
      if (value.stop_hook_active !== undefined && typeof value.stop_hook_active !== 'boolean') {
        throw new CodeBuddyHookError('invalid_payload', 'Invalid CodeBuddy field: stop_hook_active');
      }
      if (event === 'Stop') message.observedState = 'completionUnconfirmed';
      else message.status = 'CodeBuddy 子代理完成未确认';
      // 原生合同未给出最终回答或唯一子代理 ID，不读取同名的其他品牌扩展字段。
      break;
    case 'PreCompact':
      optionalText(value, 'trigger'); optionalText(value, 'custom_instructions');
      message.type = 'context_compact'; message.status = 'CodeBuddy 正在压缩上下文'; break;
    case 'PostCompact':
      optionalText(value, 'trigger'); message.type = 'recap'; message.recapText = text(value.compact_summary, 'compact_summary'); break;
    case 'SessionEnd':
      optionalText(value, 'reason'); message.type = 'session_end'; message.observedState = 'completed'; break;
  }
  try { return parseDIMessage(message); }
  catch (error) { throw new CodeBuddyHookError('invalid_payload', error instanceof Error ? error.message : 'Invalid CodeBuddy message'); }
}

/** CLI PreToolUse 的 modifiedInput 不是 Claude updatedInput；当前只观察，不改写答案或权限。 */
export function codeBuddyHookResponse(_payload: unknown, response: DIResponse | null): CodeBuddyHookOutput {
  if (response !== null) throw new CodeBuddyHookError('unsupported_interaction', 'CodeBuddy approvals, questions and plans remain in the native client');
  return { stdout: '', exitCode: 0 };
}
