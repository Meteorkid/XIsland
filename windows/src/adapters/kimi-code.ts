import { isRecord, parseDIMessage, utf8Length, type DIMessage, type DIResponse } from '../core/protocol';

// @moonshot-ai/kimi-code 2.1.1；Python kimi-cli 使用另一套协议。
export const KIMI_CODE_HOOK_EVENTS = [
  'SessionStart', 'UserPromptSubmit', 'UserPromptQueued', 'TurnStarted', 'PreToolUse', 'PostToolUse',
  'PostToolUseFailure', 'PermissionRequest', 'PermissionResult', 'Stop', 'StopFailure', 'Interrupt',
  'SessionHeartbeat', 'SubagentStart', 'SubagentStop', 'TaskStarted', 'PreCompact', 'PostCompact',
  'Notification', 'SessionEnd',
] as const;
export interface KimiCodeHookContext { timestamp?: string; terminal?: string; termSessionId?: string; event?: string }
export class KimiCodeHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'unsupported_interaction', message: string) {
    super(message); this.name = 'KimiCodeHookError';
  }
}
function invalid(field: string): never { throw new KimiCodeHookError('invalid_payload', `Invalid Kimi Code field: ${field}`); }
function string(data: Record<string, unknown>, field: string): string {
  const value = data[field];
  if (typeof value !== 'string' || value.includes('\0')) return invalid(field);
  return value;
}
function identifier(data: Record<string, unknown>, field: string): string {
  const value = string(data, field);
  if (!value.trim() || utf8Length(value) > 1024 || /[\p{Cc}\p{Cf}]/u.test(value)) return invalid(field);
  return value;
}
const optionalString = (data: Record<string, unknown>, field: string): string | undefined =>
  data[field] === undefined ? undefined : string(data, field);
function choice(data: Record<string, unknown>, field: string, choices: readonly string[]): string {
  const value = string(data, field); if (!choices.includes(value)) return invalid(field); return value;
}
function integer(data: Record<string, unknown>, field: string): number {
  const value = data[field]; if (!Number.isSafeInteger(value) || (value as number) < 0) return invalid(field); return value as number;
}
function optionalBoolean(data: Record<string, unknown>, field: string): void {
  if (data[field] !== undefined && typeof data[field] !== 'boolean') invalid(field);
}
function prompt(data: Record<string, unknown>): string {
  if (!Array.isArray(data.prompt)) return invalid('prompt');
  return data.prompt.flatMap(part => {
    if (!isRecord(part)) return invalid('prompt');
    return identifier(part, 'type') === 'text' ? [string(part, 'text')] : [];
  }).join('\n');
}
function jsonText(value: unknown): string {
  const seen = new Set<object>();
  const visit = (item: unknown): unknown => {
    if (item === null || typeof item === 'string' || typeof item === 'boolean') return item;
    if (typeof item === 'number' && Number.isFinite(item)) return item;
    if (!isRecord(item) && !Array.isArray(item)) return invalid('JSON');
    if (seen.has(item)) return invalid('JSON');
    seen.add(item);
    const copy = Array.isArray(item) ? Array.from(item, visit)
      : Object.fromEntries(Object.keys(item).sort().map(key => [key, visit(item[key])]));
    seen.delete(item); return copy;
  };
  return JSON.stringify(visit(value));
}

/** 固定协议只提供观察事实；没有主/子 Stop 归属和完整助手回复的证据。 */
export function normalizeKimiCodeHook(value: unknown, context: KimiCodeHookContext = {}): DIMessage {
  if (!isRecord(value)) return invalid('payload');
  jsonText(value);
  const event = identifier(value, 'hook_event_name');
  if (context.event !== undefined && context.event !== event) return invalid('hook_event_name');
  if (!(KIMI_CODE_HOOK_EVENTS as readonly string[]).includes(event)) {
    throw new KimiCodeHookError('unsupported_event', `Unsupported Kimi Code event: ${event}`);
  }
  identifier(value, 'client_type'); optionalString(value, 'session_title');
  const message: DIMessage = { type: 'status_update', sessionId: `kimi_code-${identifier(value, 'session_id')}`,
    timestamp: context.timestamp ?? new Date().toISOString(), agentType: 'kimi', nativeEvent: `kimi_code.${event}`,
    workingDir: string(value, 'cwd'), statusIsAssistantReply: false, terminal: context.terminal, termSessionId: context.termSessionId };
  switch (event) {
    case 'SessionStart':
      choice(value, 'source', ['startup', 'resume']); optionalString(value, 'profile');
      message.model = optionalString(value, 'model'); message.observedState = 'idle'; message.status = 'Kimi Code connected'; break;
    case 'SessionEnd':
      message.status = `Kimi Code session: ${choice(value, 'reason', ['exit', 'archive'])}`;
      message.type = 'session_end'; message.observedState = 'completed'; break;
    case 'UserPromptSubmit':
      message.type = 'session_start'; message.prompt = prompt(value); optionalBoolean(value, 'is_steer'); break;
    case 'UserPromptQueued':
      identifier(value, 'prompt_id'); message.status = `Queued (${integer(value, 'queue_length')}): ${prompt(value)}`; break;
    case 'TurnStarted': {
      message.nativeTurnId = String(integer(value, 'turn_id'));
      const origin = identifier(value, 'origin_kind'), name = optionalString(value, 'origin_name'); optionalString(value, 'prompt');
      message.observedState = 'active'; message.status = `Turn started: ${[origin, name].filter(item => item !== undefined).join('/')}`; break;
    }
    case 'PreToolUse': case 'PostToolUse': case 'PostToolUseFailure':
      message.tool = identifier(value, 'tool_name'); message.toolCallId = identifier(value, 'tool_call_id');
      if (!isRecord(value.tool_input)) return invalid('tool_input');
      message.toolInput = jsonText(value.tool_input);
      message.filePath = typeof value.tool_input.file_path === 'string' ? value.tool_input.file_path
        : typeof value.tool_input.path === 'string' ? value.tool_input.path : undefined;
      if (event === 'PreToolUse') message.type = 'tool_start';
      else {
        message.type = 'tool_complete';
        if (event === 'PostToolUse') message.toolResult = string(value, 'tool_output');
        else {
          if (!isRecord(value.error)) return invalid('error');
          message.toolResult = jsonText(value.error); message.observedState = 'error';
        }
      }
      break;
    case 'PermissionRequest': case 'PermissionResult': {
      if (value.id !== undefined) message.nativeRequestId = identifier(value, 'id');
      message.nativeRequestKind = 'permission'; message.nativeAgentId = identifier(value, 'agent_id');
      message.nativeTurnId = String(integer(value, 'turn_id')); message.toolCallId = identifier(value, 'tool_call_id');
      message.tool = identifier(value, 'tool_name'); const action = string(value, 'action');
      if (!isRecord(value.display) || value.tool_input === undefined) return invalid('approval context');
      message.toolInput = jsonText(value.tool_input);
      if (event === 'PermissionRequest') message.status = `Waiting for approval in Kimi Code: ${action}`;
      else {
        const decision = choice(value, 'decision', ['approved', 'rejected', 'cancelled', 'error']);
        if (value.scope !== undefined) choice(value, 'scope', ['session']);
        for (const field of ['feedback', 'selected_label', 'error']) optionalString(value, field);
        message.status = `Kimi Code approval result: ${decision}`;
      }
      break;
    }
    case 'Stop':
      optionalBoolean(value, 'stop_hook_active'); message.observedState = 'completionUnconfirmed'; break;
    case 'StopFailure':
      message.status = [optionalString(value, 'error_type'), string(value, 'error_message')].filter(item => item !== undefined).join(': ');
      message.observedState = 'error'; break;
    case 'Interrupt':
      message.nativeTurnId = String(integer(value, 'turn_id')); choice(value, 'reason', ['cancelled']);
      message.observedState = 'completionUnconfirmed'; message.status = 'Kimi Code turn interrupted; outcome unconfirmed'; break;
    case 'SessionHeartbeat':
      integer(value, 'uptime_ms'); message.status = 'Kimi Code session heartbeat'; break;
    case 'SubagentStart': case 'SubagentStop':
      // agent_name 不是唯一身份，不能建立父子树或配对并发任务。
      message.status = `${identifier(value, 'agent_name')}: ${string(value, event === 'SubagentStart' ? 'prompt' : 'response')}`; break;
    case 'TaskStarted': {
      const id = identifier(value, 'task_id'), kind = choice(value, 'kind', ['agent', 'process', 'question']);
      const description = string(value, 'description'), status = choice(value, 'status', ['running', 'completed', 'failed', 'timed_out', 'killed', 'lost']);
      const startedAtMilliseconds = integer(value, 'started_at'); optionalBoolean(value, 'detached');
      message.status = `Task ${id} (${kind}): ${description}`;
      message.nativeBackgroundTask = { id, kind, status, description, startedAtMilliseconds }; break;
    }
    case 'PreCompact':
      choice(value, 'trigger', ['manual', 'auto']); integer(value, 'token_count'); message.type = 'context_compact'; break;
    case 'PostCompact':
      message.observedState = choice(value, 'trigger', ['manual', 'auto']) === 'manual' ? 'completionUnconfirmed' : 'active';
      integer(value, 'estimated_token_count'); break;
    case 'Notification': {
      choice(value, 'sink', ['context']); message.nativeAgentId = identifier(value, 'agent_id');
      const notification = identifier(value, 'notification_type'), source = identifier(value, 'source_kind'), id = identifier(value, 'source_id');
      choice(value, 'severity', ['info', 'warning']); message.status = [string(value, 'title'), string(value, 'body')].filter(Boolean).join('\n');
      const status = ['completed', 'failed', 'timed_out', 'killed', 'lost'].find(state => notification === `task.${state}`);
      if (source === 'background_task' && status) message.nativeBackgroundTask = { id, status, result: message.status };
      break;
    }
  }
  try { return parseDIMessage(message); }
  catch (error) { throw new KimiCodeHookError('invalid_payload', error instanceof Error ? error.message : 'Invalid Kimi Code message'); }
}

/** 空输出不改变原生审批决定；岛上没有此协议的批准、拒绝或回答通道。 */
export function kimiCodeHookResponse(_payload: unknown, response: DIResponse | null): { stdout: string; exitCode: 0 } {
  if (response !== null) throw new KimiCodeHookError('unsupported_interaction', 'Kimi Code decisions must remain in the native client');
  return { stdout: '', exitCode: 0 };
}
