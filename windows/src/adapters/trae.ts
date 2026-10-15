import { isRecord, parseDIMessage, type DIMessage, type DIResponse } from '../core/protocol';

// 国内版共享观察入口；TraeWork CN 0.2.2 的公开安装资源也使用此全局配置和六事件合同。
// 两个产品共用配置时不能重复注册或凭载荷猜测来源；Windows 原生验收仍待完成。
// 官方核查：2026-10-15 https://docs.trae.cn/ide_hook-configuration-reference
export const TRAE_HOOK_PROFILE = 'trae_cn' as const;
export const TRAE_OBSERVATION_CLIENTS = ['Trae CN', 'TraeWork CN'] as const;
export const TRAE_HOOK_EVENTS = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'Notification'] as const;
export interface TraeHookContext {
  timestamp?: string;
  terminal?: string;
  termSessionId?: string;
  hookEventName?: string;
  /** 未传入时即选择本文件明确限定的 CN 协议；其他发行版必须另建适配器。 */
  edition?: 'cn' | 'work-cn' | 'international' | 'solo';
  /** 本地前置门禁不能绕过原客户端的手动确认模式。 */
  preToolGate?: boolean;
}
export interface TraeHookOutput { stdout: string; exitCode: 0 }
export class TraeHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'unsupported_edition' | 'unsupported_interaction' | 'invalid_response', message: string) {
    super(message); this.name = 'TraeHookError';
  }
}

function edition(context: TraeHookContext): void {
  if (context.edition !== undefined && !['cn', 'work-cn'].includes(context.edition)) throw new TraeHookError('unsupported_edition', 'Only the reviewed domestic TRAE observation dialect is implemented');
  if (context.edition === 'work-cn' && context.preToolGate) throw new TraeHookError('unsupported_interaction', 'TraeWork CN is observation only');
}
function text(source: Record<string, unknown>, field: string, allowEmpty = false): string {
  const value = source[field];
  if (typeof value !== 'string' || value.includes('\0') || (!allowEmpty && !value.trim())) throw new TraeHookError('invalid_payload', `Invalid Trae CN field: ${field}`);
  return value;
}
function json(value: unknown): string {
  const ancestors = new Set<object>();
  const ordered = (value: unknown): unknown => {
    if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (Array.isArray(value) || isRecord(value)) {
      if (ancestors.has(value)) throw new Error('cyclic JSON');
      ancestors.add(value);
      const result = Array.isArray(value) ? value.map(ordered) : Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])]));
      ancestors.delete(value); return result;
    }
    throw new Error('non-JSON value');
  };
  try { return JSON.stringify(ordered(value)); }
  catch { throw new TraeHookError('invalid_payload', 'Trae CN payload must contain finite JSON values'); }
}

/** 六个已核实 CN 事件；通知仅表示原应用等待，不伪造本地问答或计划请求。 */
export function normalizeTraeHook(value: unknown, context: TraeHookContext = {}): DIMessage {
  edition(context);
  if (!isRecord(value)) throw new TraeHookError('invalid_payload', 'Trae CN payload must be an object');
  json(value);
  const event = text(value, 'hook_event_name');
  if (context.hookEventName !== undefined && context.hookEventName !== event) throw new TraeHookError('invalid_payload', 'Trae CN event differs from invoked hook');
  if (!(TRAE_HOOK_EVENTS as readonly string[]).includes(event)) throw new TraeHookError('unsupported_event', `Unsupported Trae CN event: ${event}`);
  const message: DIMessage = { type: 'status_update', sessionId: `trae-${text(value, 'session_id')}`, agentType: 'trae', nativeEvent: event,
    workingDir: text(value, 'cwd'), timestamp: context.timestamp ?? new Date().toISOString(), statusIsAssistantReply: false,
    terminal: context.terminal, termSessionId: context.termSessionId };
  switch (event) {
    case 'SessionStart': message.type = 'session_start'; break;
    case 'UserPromptSubmit': message.type = 'session_start'; message.prompt = text(value, 'prompt', true); break;
    case 'PreToolUse':
    case 'PostToolUse': {
      message.type = event === 'PreToolUse' ? 'tool_start' : 'tool_complete';
      message.tool = text(value, 'tool_name'); message.toolCallId = text(value, 'tool_use_id');
      if (!isRecord(value.tool_input)) throw new TraeHookError('invalid_payload', 'Trae CN tool_input must be an object');
      message.toolInput = json(value.tool_input);
      if (event === 'PostToolUse') {
        if (!isRecord(value.tool_response)) throw new TraeHookError('invalid_payload', 'Trae CN tool_response must be an object');
        message.toolResult = json(value.tool_response);
      } else if (context.preToolGate === true) {
        message.type = 'permission_request';
        const input = value.tool_input;
        message.permDescription = ['description', 'command', 'file_path', 'path'].map(key => input[key])
          .find((value): value is string => typeof value === 'string' && !!value.trim()) ?? message.toolInput;
        const path = input.file_path ?? input.path;
        if (typeof path === 'string' && path) message.filePath = path;
      }
      break;
    }
    case 'Stop':
      message.status = text(value, 'last_assistant_message', true); message.statusIsAssistantReply = true;
      message.observedState = 'completionUnconfirmed'; break;
    case 'Notification': {
      if (typeof value.message === 'string') message.status = value.message;
      const notification = text(value, 'notification_type');
      const states: Record<string, string> = { idle_prompt: 'idle', permission_prompt: 'waitingPermission',
        document_review: 'waitingPlanReview', ask_user_question: 'waitingAnswer' };
      if (Object.hasOwn(states, notification)) message.observedState = states[notification];
      break;
    }
  }
  try { return parseDIMessage(message); }
  catch (error) { throw new TraeHookError('invalid_payload', error instanceof Error ? error.message : 'Invalid Trae CN message'); }
}

/** 默认观察输出不改变客户端流程；显式门禁失效时返回 ask，由原端进行确认。 */
export function traeHookResponse(payload: unknown, response: DIResponse | null, context: TraeHookContext = {}): TraeHookOutput {
  edition(context);
  const gate = context.preToolGate === true && isRecord(payload) && payload.hook_event_name === 'PreToolUse';
  if (response === null) return { stdout: gate
    ? JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'ask' } }) : '{}', exitCode: 0 };
  if (!gate) throw new TraeHookError('unsupported_interaction', 'Trae CN observations do not answer native approvals, questions or document reviews');
  const message = normalizeTraeHook(payload, context);
  if (message.type !== 'permission_request' || response.type !== 'permission_response' || response.sessionId !== message.sessionId || typeof response.approved !== 'boolean') {
    throw new TraeHookError('invalid_response', 'Trae CN response does not match the explicit pre-tool gate');
  }
  return { stdout: JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse',
    permissionDecision: response.approved ? 'allow' : 'deny' } }), exitCode: 0 };
}
