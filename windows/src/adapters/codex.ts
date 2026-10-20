import { isRecord, parseDIMessage, utf8Length, type DIMessage, type DIResponse } from '../core/protocol';

/** 当前 NativeHookProfile.swift 的 Codex 注册事件；未知事件不走名称猜测。 */
export const CODEX_HOOK_EVENTS = [
  'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest',
  'Stop', 'SessionEnd', 'SubagentStart', 'SubagentStop', 'Interrupt', 'PreCompact', 'PostCompact',
] as const;

export interface CodexHookContext { timestamp?: string; terminal?: string; termSessionId?: string; projectDir?: string }
export interface CodexHookOutput { stdout: string; exitCode: 0 }
export class CodexHookError extends Error {
  constructor(readonly code: 'invalid_payload' | 'unsupported_event' | 'unsupported_interaction' | 'invalid_response', message: string) {
    super(message); this.name = 'CodexHookError';
  }
}

function nativeText(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value.trim() || value.includes('\0') || utf8Length(value) > 4096) {
    throw new CodexHookError('invalid_payload', `Invalid Codex field: ${field}`);
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
  try {
    return JSON.stringify(value, (_key, child: unknown) => isRecord(child)
      ? Object.fromEntries(Object.keys(child).sort().map(key => [key, child[key]])) : child);
  } catch { throw new CodexHookError('invalid_payload', 'Codex tool data must be JSON serializable'); }
}
function permissionInput(payload: Record<string, unknown>): { input?: Record<string, unknown>; raw: string; plain?: string } {
  const values = ['tool_input', 'input', 'parameters', 'params', 'args'].map(key => payload[key]);
  values.push(isRecord(payload.tool) ? payload.tool.input : undefined);
  for (const value of values) {
    if (isRecord(value)) return { input: value, raw: outputText(value)! };
    if (typeof value === 'string') {
      try {
        const input: unknown = JSON.parse(value);
        if (isRecord(input)) return { input, raw: value };
      } catch { /* 非 JSON 对象的原始文本保留供审批查看。 */ }
      return { raw: value, plain: value };
    }
    if (Array.isArray(value)) return { raw: outputText(value)!, plain: outputText(value) };
  }
  return { raw: outputText(payload)! };
}
function permissionText(sources: (Record<string, unknown> | undefined)[], keys: string[]): string | undefined {
  for (const source of sources) if (source) for (const key of keys) {
    const value = text(source[key]); if (value) return value;
  }
  return undefined;
}
function descriptionFromInput(input: Record<string, unknown> | undefined): string | undefined {
  if (!input) return undefined;
  const direct = permissionText([input], ['command', 'query', 'content', 'code', 'url', 'pattern', 'text']);
  if (direct) return direct;
  if (Object.keys(input).length > 3) return undefined;
  const parts = Object.entries(input).filter((entry): entry is [string, string] => typeof entry[1] === 'string' && entry[1].length > 0)
    .map(([key, value]) => `${key}: ${value}`);
  return parts.length ? parts.join('\n') : undefined;
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

/** 仅移植 DIBridge 的 Codex 原生分支，不读环境、猜会话或注册配置。 */
export function normalizeCodexHook(value: unknown, context: CodexHookContext = {}): DIMessage {
  if (!isRecord(value)) throw new CodexHookError('invalid_payload', 'Codex hook must be an object');
  const event = nativeText(value.hook_event_name, 'hook_event_name');
  if (!(CODEX_HOOK_EVENTS as readonly string[]).includes(event)) throw new CodexHookError('unsupported_event', `Unsupported Codex event: ${event}`);
  const sessionId = `codex-${nativeText(value.session_id, 'session_id')}`;
  const message: DIMessage = { type: 'status_update', sessionId, agentType: 'codex', nativeEvent: event,
    timestamp: context.timestamp ?? new Date().toISOString(), workingDir: text(value.cwd) };
  const turnObservation = ['Interrupt', 'PreCompact', 'PostCompact'].includes(event);
  if (value.turn_id !== undefined || turnObservation) message.nativeTurnId = nativeText(value.turn_id, 'turn_id');
  if (turnObservation) {
    if (event !== 'Interrupt' && !['manual', 'auto'].includes(value.trigger as string)) {
      throw new CodexHookError('invalid_payload', 'Codex compaction trigger must be manual or auto');
    }
    message.type = event === 'PreCompact' ? 'context_compact' : 'status_update';
    message.statusIsAssistantReply = false;
    if (event !== 'PreCompact') message.observedState = 'completionUnconfirmed';
    return parseDIMessage(message);
  }
  const tool = text(value.tool_name) ?? text(value.tool) ?? 'unknown';
  if (event === 'SubagentStart' || event === 'SubagentStop') {
    message.type = event === 'SubagentStart' ? 'subagent_start' : 'subagent_end';
    message.parentSessionId = sessionId;
    message.subagentId = `codex-${nativeText(value.agent_id, 'agent_id')}`;
    // Codex 两种子事件均要求非空 agent_type，不能沿用 Claude Stop 的例外。
    message.prompt = nativeText(value.agent_type, 'agent_type');
    message.statusIsAssistantReply = false;
    if (event === 'SubagentStop') message.subagentEndIsProvisional = true;
  } else {
    if (typeof value.tool_use_id === 'string' && value.tool_use_id.length > 0) message.toolCallId = value.tool_use_id;
    switch (event) {
      case 'SessionStart':
      case 'UserPromptSubmit': {
        message.type = 'session_start'; message.prompt = userPrompt(value.prompt);
        message.terminal = text(value.terminal) || context.terminal || 'Terminal';
        message.termSessionId = context.termSessionId || undefined;
        const directory = firstText(value, ['working_dir', 'cwd', 'projectPath', 'workspace', 'workspaceFolder'])
          ?? (Array.isArray(value.workspace_roots) ? text(value.workspace_roots[0]) : undefined);
        message.workingDir = directory || context.projectDir; copyUsage(value, message); break;
      }
      case 'PreToolUse':
        message.type = 'tool_start'; message.tool = tool;
        message.toolInput = outputText(value.tool_input) ?? text(value.input);
        // Codex 的问答工具在当前合同中只是工具事件，没有已验证的回答接管。
        break;
      case 'PostToolUse':
        message.type = 'tool_complete'; message.tool = tool; message.toolInput = outputText(value.tool_input);
        message.toolResult = outputText(value.tool_result) ?? outputText(value.tool_response) ?? outputText(value.result) ?? outputText(value.error);
        if (Number.isSafeInteger(value.lines_added)) message.linesAdded = value.lines_added as number;
        if (Number.isSafeInteger(value.lines_removed)) message.linesRemoved = value.lines_removed as number;
        copyUsage(value, message); break;
      case 'PermissionRequest': {
        message.type = 'permission_request'; message.tool = tool;
        const { input, raw, plain } = permissionInput(value), sources = [input, value];
        // 命令位于参数外层时保留整包，避免 UI 将参数中的友好文本误当命令。
        message.toolInput = permissionText([value], ['command']) && !permissionText([input], ['command'])
          ? outputText(value)! : raw;
        message.permDescription = permissionText(sources, ['command']) ?? plain
          ?? permissionText(sources, ['description', 'path', 'file_path', 'pattern', 'query', 'content', 'text'])
          ?? descriptionFromInput(input) ?? descriptionFromInput(value) ?? '';
        message.diff = text(value.diff); message.filePath = permissionText(sources, ['file_path', 'path', 'filePath']);
        break;
      }
      case 'Stop':
        message.status = firstText(value, ['message', 'status', 'text', 'last-assistant-message', 'last_assistant_message']) ?? '';
        message.observedState = 'completionUnconfirmed'; message.statusIsAssistantReply = true; copyUsage(value, message); break;
      case 'SessionEnd':
        message.type = 'session_end'; message.observedState = 'completed';
        message.status = firstText(value, ['last_assistant_message', 'message', 'response', 'result']); copyUsage(value, message); break;
    }
  }
  try { return parseDIMessage(message); }
  catch (error) { throw new CodexHookError('invalid_payload', error instanceof Error ? error.message : 'Invalid Codex message'); }
}

/** 无用户裁决时回空 JSON，让原生客户端继续审批；拒绝也用成功退出交付结构化决定。 */
export function codexHookResponse(payload: unknown, response: DIResponse | null): CodexHookOutput {
  if (response === null) return { stdout: '{}', exitCode: 0 };
  const message = normalizeCodexHook(payload);
  if (message.type !== 'permission_request') throw new CodexHookError('unsupported_interaction', 'Only Codex PermissionRequest supports local decisions');
  if (response.type !== 'permission_response' || response.sessionId !== message.sessionId || typeof response.approved !== 'boolean') {
    throw new CodexHookError('invalid_response', 'Codex response does not match the pending permission');
  }
  return { stdout: JSON.stringify({ hookSpecificOutput: { hookEventName: 'PermissionRequest',
    decision: { behavior: response.approved ? 'allow' : 'deny' } } }), exitCode: 0 };
}
