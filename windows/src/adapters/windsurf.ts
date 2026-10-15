import { isRecord, parseDIMessage, type DIMessage, type DIResponse } from '../core/protocol';

// 当前 Swift 的 10 项 Cascade 合同；不读取 transcript，也不套用 Devin Local Agent 协议。
// 官方核查：2026-10-14 https://docs.devin.ai/desktop/cascade/hooks
export const WINDSURF_HOOK_EVENTS = [
  'pre_user_prompt', 'pre_read_code', 'post_read_code', 'pre_write_code', 'post_write_code',
  'pre_run_command', 'post_run_command', 'pre_mcp_tool_use', 'post_mcp_tool_use', 'post_cascade_response',
] as const;
const PRE_TOOL_EVENTS = ['pre_read_code', 'pre_write_code', 'pre_run_command', 'pre_mcp_tool_use'];

export interface WindsurfHookContext {
  terminal?: string;
  termSessionId?: string;
  hookEventName?: string;
  /** 显式本地前置门禁，不是 Cascade 原生权限请求；normalize/respond 必须使用相同配置。 */
  preToolGate?: boolean;
}
export interface WindsurfHookOutput { stdout: string; exitCode: 0 | 2 }
export class WindsurfHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'unsupported_interaction' | 'invalid_response', message: string) {
    super(message); this.name = 'WindsurfHookError';
  }
}

function text(source: Record<string, unknown>, field: string, allowEmpty = false): string {
  const value = source[field];
  if (typeof value !== 'string' || value.includes('\0') || (!allowEmpty && !value.trim())) throw new WindsurfHookError('invalid_payload', `Invalid Cascade field: ${field}`);
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
      const result = Array.isArray(value) ? value.map(ordered)
        : Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])]));
      ancestors.delete(value); return result;
    }
    throw new Error('non-JSON value');
  };
  try { return JSON.stringify(ordered(value)); }
  catch { throw new WindsurfHookError('invalid_payload', 'Cascade payload must contain finite JSON values'); }
}

/** 默认纯观察；trajectory 是会话，execution 是轮次，不能据轮次伪造每次工具调用身份。 */
export function normalizeWindsurfHook(value: unknown, context: WindsurfHookContext = {}): DIMessage {
  if (!isRecord(value)) throw new WindsurfHookError('invalid_payload', 'Cascade payload must be an object');
  json(value);
  const event = text(value, 'agent_action_name');
  if (context.hookEventName !== undefined && context.hookEventName !== event) throw new WindsurfHookError('invalid_payload', 'Cascade event differs from invoked hook');
  if (!(WINDSURF_HOOK_EVENTS as readonly string[]).includes(event)) throw new WindsurfHookError('unsupported_event', `Unsupported Cascade event: ${event}`);
  const trajectory = text(value, 'trajectory_id');
  const execution = text(value, 'execution_id');
  const message: DIMessage = { type: 'status_update', sessionId: `windsurf-${trajectory}`, agentType: 'windsurf', nativeEvent: event,
    nativeTurnId: execution, timestamp: text(value, 'timestamp'), model: text(value, 'model_name'), statusIsAssistantReply: false,
    terminal: context.terminal, termSessionId: context.termSessionId };
  const info = value.tool_info;
  if (!isRecord(info)) throw new WindsurfHookError('invalid_payload', 'Cascade tool_info must be an object');
  if (event === 'pre_user_prompt') {
    message.type = 'session_start'; message.prompt = text(info, 'user_prompt', true);
  } else if (event === 'post_cascade_response') {
    message.status = text(info, 'response', true); message.observedState = 'idle'; message.statusIsAssistantReply = true;
  } else {
    message.type = event.startsWith('pre_') ? 'tool_start' : 'tool_complete';
    if (event.endsWith('read_code') || event.endsWith('write_code')) {
      message.filePath = text(info, 'file_path'); message.tool = event.endsWith('write_code') ? 'Write' : 'Read';
      if (message.tool === 'Write') {
        if (!Array.isArray(info.edits) || !info.edits.every(isRecord)) throw new WindsurfHookError('invalid_payload', 'Cascade edits must be an object array');
        for (const edit of info.edits) { text(edit, 'old_string', true); text(edit, 'new_string', true); }
      }
    } else if (event.endsWith('run_command')) {
      text(info, 'command_line'); message.workingDir = text(info, 'cwd'); message.tool = 'Bash';
    } else {
      const server = text(info, 'mcp_server_name'), tool = text(info, 'mcp_tool_name');
      if (!isRecord(info.mcp_tool_arguments)) throw new WindsurfHookError('invalid_payload', 'Cascade mcp_tool_arguments must be an object');
      message.tool = `mcp__${server}__${tool}`;
      if (event === 'post_mcp_tool_use') {
        if (!Object.hasOwn(info, 'mcp_result')) throw new WindsurfHookError('invalid_payload', 'Cascade mcp_result is missing');
        message.toolResult = typeof info.mcp_result === 'string' ? info.mcp_result : json(info.mcp_result);
      }
    }
    message.toolInput = json(info);
    if (context.preToolGate === true && PRE_TOOL_EVENTS.includes(event)) {
      message.type = 'permission_request';
      message.permDescription = typeof info.command_line === 'string' ? info.command_line : message.filePath ?? message.toolInput;
    }
  }
  try { return parseDIMessage(message); }
  catch (error) { throw new WindsurfHookError('invalid_payload', error instanceof Error ? error.message : 'Invalid Cascade message'); }
}

/** 默认观察链路永远不阻断；显式门禁失败用 exit 2，不能把 exit 1 当可靠拒绝。 */
export function windsurfHookResponse(payload: unknown, response: DIResponse | null, context: WindsurfHookContext = {}): WindsurfHookOutput {
  const event = isRecord(payload) ? payload.agent_action_name : undefined;
  const gate = context.preToolGate === true && typeof event === 'string' && PRE_TOOL_EVENTS.includes(event);
  if (response === null) return { stdout: '', exitCode: gate ? 2 : 0 };
  if (!gate) throw new WindsurfHookError('unsupported_interaction', 'Cascade observations cannot accept permission, question or plan decisions');
  const message = normalizeWindsurfHook(payload, context);
  if (message.type !== 'permission_request' || response.type !== 'permission_response' || response.sessionId !== message.sessionId || typeof response.approved !== 'boolean') {
    throw new WindsurfHookError('invalid_response', 'Cascade response does not match the explicit pre-tool gate');
  }
  return { stdout: '', exitCode: response.approved ? 0 : 2 };
}
