import { isRecord, parseDIMessage, utf8Length, type DIMessage, type DIResponse } from '../core/protocol';

/** Factory Droid 的九个原生事件：https://docs.factory.com/harness/hooks */
export const DROID_HOOK_EVENTS = [
  'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Notification',
  'Stop', 'SessionEnd', 'SubagentStop', 'PreCompact',
] as const;
export interface DroidHookContext { timestamp?: string; terminal?: string; termSessionId?: string; projectDir?: string }
export interface DroidHookOutput { stdout: string; exitCode: 0 }
export class DroidHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'unsupported_interaction', message: string) {
    super(message); this.name = 'DroidHookError';
  }
}
function text(value: unknown, field: string, allowEmpty = true): string {
  if (typeof value !== 'string' || value.includes('\0') || (!allowEmpty && (!value.trim() || utf8Length(value) > 4096))) {
    throw new DroidHookError('invalid_payload', `Invalid Droid field: ${field}`);
  }
  return value;
}
function optionalText(data: Record<string, unknown>, field: string): string | undefined {
  return data[field] === undefined ? undefined : text(data[field], field);
}
function boolean(data: Record<string, unknown>, field: string): void {
  if (data[field] !== undefined && typeof data[field] !== 'boolean') throw new DroidHookError('invalid_payload', `Invalid Droid field: ${field}`);
}
function output(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value === 'string') return value;
  try { return JSON.stringify(value); }
  catch { throw new DroidHookError('invalid_payload', 'Droid tool data must be JSON serializable'); }
}

/** Droid 没有 PermissionRequest hook；权限通知、问题与 Spec Mode 都留在客户端。 */
export function normalizeDroidHook(value: unknown, context: DroidHookContext = {}): DIMessage {
  if (!isRecord(value)) throw new DroidHookError('invalid_payload', 'Droid hook must be an object');
  const event = text(value.hook_event_name, 'hook_event_name', false);
  if (!(DROID_HOOK_EVENTS as readonly string[]).includes(event)) throw new DroidHookError('unsupported_event', `Unsupported Droid event: ${event}`);
  const message: DIMessage = { type: 'status_update', sessionId: `droid-${text(value.session_id, 'session_id', false)}`,
    agentType: 'droid', nativeEvent: event, timestamp: context.timestamp ?? new Date().toISOString(),
    workingDir: optionalText(value, 'cwd') || context.projectDir, terminal: context.terminal || 'Terminal',
    termSessionId: context.termSessionId, nativeMessageId: optionalText(value, 'message_id'), statusIsAssistantReply: false };
  for (const field of ['transcript_path', 'permission_mode']) optionalText(value, field);
  switch (event) {
    case 'SessionStart':
      optionalText(value, 'source'); message.type = 'session_start'; break;
    case 'UserPromptSubmit':
      boolean(value, 'has_images'); message.type = 'session_start'; message.prompt = text(value.prompt, 'prompt'); break;
    case 'PreToolUse':
    case 'PostToolUse':
      if (!isRecord(value.tool_input)) throw new DroidHookError('invalid_payload', 'Invalid Droid field: tool_input');
      message.type = event === 'PreToolUse' ? 'tool_start' : 'tool_complete';
      message.tool = text(value.tool_name, 'tool_name', false); message.toolInput = output(value.tool_input);
      message.filePath = optionalText(value.tool_input, 'file_path');
      // message_id 标识消息而非工具调用；不能用它合并同一消息内的多次调用。
      if (event === 'PostToolUse') message.toolResult = output(value.tool_response);
      break;
    case 'Notification':
      message.status = text(value.message, 'message'); text(value.notification_type, 'notification_type', false);
      if (value.notification_type === 'permission_prompt') message.observedState = 'waitingPermission';
      else if (value.notification_type === 'idle_prompt') message.observedState = 'idle';
      else if (value.notification_type === 'elicitation_dialog') message.observedState = 'waitingAnswer';
      break;
    case 'Stop':
      boolean(value, 'stop_hook_active'); message.observedState = 'completionUnconfirmed'; break;
    case 'SubagentStop': {
      boolean(value, 'stop_hook_active');
      const name = optionalText(value, 'task_name');
      message.status = `Droid 子代理已返回${name ? `：${name}` : ''}`;
      // task_name 不是唯一实例 ID；task_error 属于子任务，不将父会话标成失败或完成。
      message.toolResult = output(value.task_error) ?? output(value.task_result);
      break;
    }
    case 'SessionEnd':
      optionalText(value, 'reason'); message.type = 'session_end'; message.observedState = 'completed'; break;
    case 'PreCompact':
      optionalText(value, 'trigger'); optionalText(value, 'custom_instructions');
      message.type = 'context_compact'; message.status = 'Droid 正在压缩上下文'; break;
  }
  try { return parseDIMessage(message); }
  catch (error) { throw new DroidHookError('invalid_payload', error instanceof Error ? error.message : 'Invalid Droid message'); }
}

/** 空 stdout 避免被 SessionStart/UserPromptSubmit 当作额外上下文。 */
export function droidHookResponse(_payload: unknown, response: DIResponse | null): DroidHookOutput {
  if (response !== null) throw new DroidHookError('unsupported_interaction', 'Droid approvals, questions and spec reviews remain in the native client');
  return { stdout: '', exitCode: 0 };
}
