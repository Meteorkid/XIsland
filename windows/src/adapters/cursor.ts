import type { DIMessage, DIResponse } from '../core/protocol';

// 核查于 2026-10-13：https://cursor.com/docs/hooks
// 前九项沿用 CursorHookAdapter.swift 的观察合同；后三项使用官方专用审批字段。
export const CURSOR_HOOK_EVENTS = [
  'sessionStart', 'beforeSubmitPrompt', 'preToolUse', 'postToolUse', 'postToolUseFailure',
  'afterAgentResponse', 'stop', 'preCompact', 'sessionEnd',
  'beforeShellExecution', 'beforeMCPExecution', 'beforeReadFile',
] as const;

export class CursorHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'invalid_response', message: string) {
    super(message);
    this.name = 'CursorHookError';
  }
}

export interface CursorHookContext {
  timestamp?: string;
  terminal?: string;
  termSessionId?: string;
  hookEventName?: string;
}

export interface CursorHookOutput { stdout: string; exitCode: 0 | 1 | 2 }
type NativeObject = Record<string, unknown>;

function object(value: unknown): NativeObject | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as NativeObject : undefined;
}

function text(data: NativeObject, key: string, allowingEmpty = false): string {
  const value = data[key];
  if (typeof value !== 'string' || value.includes('\0') || (!allowingEmpty && !value.trim())) {
    throw new CursorHookError('invalid_payload', `Invalid Cursor field: ${key}`);
  }
  return value;
}

function serializeInput(input: NativeObject): string {
  return JSON.stringify(input, (_key, value: unknown) => {
    const record = object(value);
    return record ? Object.fromEntries(Object.keys(record).sort().map(key => [key, record[key]])) : value;
  });
}

/** Cursor 的工具观察不按工具名字猜测问答；generation_id 也不是会话身份。 */
export function normalizeCursorHook(value: unknown, context: CursorHookContext = {}): DIMessage {
  const payload = object(value);
  if (!payload) throw new CursorHookError('invalid_payload', 'Cursor hook must be an object');
  const event = text(payload, 'hook_event_name');
  if (context.hookEventName !== undefined && context.hookEventName !== event) {
    throw new CursorHookError('invalid_payload', 'Cursor hook event does not match the invoked hook');
  }
  if (!(CURSOR_HOOK_EVENTS as readonly string[]).includes(event)) {
    throw new CursorHookError('unsupported_event', `Unsupported Cursor event: ${event}`);
  }
  const conversation = text(payload, 'conversation_id');
  const message: DIMessage = {
    type: 'status_update', sessionId: `cursor-${conversation}`, agentType: 'cursor', nativeEvent: event,
    timestamp: context.timestamp ?? new Date().toISOString(), statusIsAssistantReply: false,
  };
  if (typeof payload.model_id === 'string') message.model = payload.model_id;
  else if (typeof payload.model === 'string') message.model = payload.model;
  if (typeof payload.cwd === 'string' && payload.cwd) message.workingDir = payload.cwd;
  else if (Array.isArray(payload.workspace_roots) && payload.workspace_roots.length === 1 && typeof payload.workspace_roots[0] === 'string') {
    message.workingDir = payload.workspace_roots[0];
  }
  if (context.terminal) message.terminal = context.terminal;
  if (context.termSessionId) message.termSessionId = context.termSessionId;

  switch (event) {
    case 'sessionStart':
    case 'sessionEnd':
      if (payload.session_id !== undefined && text(payload, 'session_id') !== conversation) {
        throw new CursorHookError('invalid_payload', 'Cursor session_id differs from conversation_id');
      }
      message.type = event === 'sessionStart' ? 'session_start' : 'session_end';
      if (event === 'sessionEnd') message.observedState = 'completed';
      break;
    case 'beforeSubmitPrompt':
      message.type = 'session_start';
      message.prompt = text(payload, 'prompt', true);
      break;
    case 'preToolUse':
    case 'postToolUse':
    case 'postToolUseFailure': {
      message.type = event === 'preToolUse' ? 'tool_start' : 'tool_complete';
      message.tool = text(payload, 'tool_name');
      message.toolCallId = text(payload, 'tool_use_id');
      const input = object(payload.tool_input);
      if (!input) throw new CursorHookError('invalid_payload', 'Cursor generic tool_input must be an object');
      message.toolInput = serializeInput(input);
      if (event === 'postToolUse') message.toolResult = text(payload, 'tool_output', true);
      if (event === 'postToolUseFailure') {
        message.toolResult = text(payload, 'error_message', true);
        if (payload.is_interrupt !== true) message.observedState = 'error';
      }
      break;
    }
    case 'afterAgentResponse':
      message.status = text(payload, 'text', true);
      message.statusIsAssistantReply = true;
      break;
    case 'stop': {
      const status = text(payload, 'status');
      if (!['completed', 'aborted', 'error'].includes(status)) throw new CursorHookError('invalid_payload', 'Invalid Cursor stop status');
      message.observedState = status === 'error' ? 'error' : 'idle';
      break;
    }
    case 'preCompact':
      message.type = 'context_compact';
      break;
    case 'beforeShellExecution':
      message.type = 'permission_request';
      message.tool = 'Shell';
      message.permDescription = text(payload, 'command');
      message.toolInput = message.permDescription;
      break;
    case 'beforeMCPExecution': {
      message.type = 'permission_request';
      const name = text(payload, 'tool_name');
      const server = text(payload, 'mcp_server_name');
      message.tool = `MCP:${server}/${name}`;
      // 此专用 hook 的参数是 JSON 字符串，与通用 preToolUse 的对象字段不同。
      message.toolInput = text(payload, 'tool_input', true);
      message.permDescription = `${message.tool}\n${message.toolInput}`;
      break;
    }
    case 'beforeReadFile':
      message.type = 'permission_request';
      message.tool = 'Read';
      message.filePath = text(payload, 'file_path');
      message.permDescription = message.filePath;
      // 仅显示访问路径；不把原生 hook 附带的整份文件正文写入会话历史。
      break;
  }
  return message;
}

/** 空响应按每个事件的官方合同处理，不能统一打印 {} 或将 exit 1 当拒绝。 */
export function cursorHookResponse(value: unknown, response: DIResponse | null): CursorHookOutput {
  const payload = object(value);
  const event = payload?.hook_event_name;
  if (response === null) {
    if (event === 'preToolUse') return { stdout: '{"permission":"allow"}', exitCode: 0 };
    if (event === 'beforeSubmitPrompt') return { stdout: '{"continue":true}', exitCode: 0 };
    if (event === 'beforeShellExecution' || event === 'beforeMCPExecution') return { stdout: '{"permission":"ask"}', exitCode: 0 };
    if (event === 'beforeReadFile') return {
      stdout: JSON.stringify({ permission: 'deny', user_message: 'XIsland 未收到有效决定，已阻止本次读取；请在原应用重新发起。' }), exitCode: 0,
    };
    if (typeof event === 'string' && (CURSOR_HOOK_EVENTS as readonly string[]).includes(event)) return { stdout: '{}', exitCode: 0 };
    // 未知 schema 不伪造成功响应；是否阻断由原 hook 的 failClosed 策略决定。
    return { stdout: '', exitCode: 1 };
  }
  const message = normalizeCursorHook(value);
  if (response.type !== 'permission_response' || typeof response.approved !== 'boolean'
    || response.sessionId !== message.sessionId
    || !['preToolUse', 'beforeShellExecution', 'beforeMCPExecution', 'beforeReadFile'].includes(message.nativeEvent!)) {
    throw new CursorHookError('invalid_response', 'Cursor response does not match a supported permission hook');
  }
  // 官方允许 exit 0 + deny JSON 或 exit 2；沿用 Swift 专用 helper 的结构化 exit 0。
  return { stdout: JSON.stringify({ permission: response.approved ? 'allow' : 'deny' }), exitCode: 0 };
}
