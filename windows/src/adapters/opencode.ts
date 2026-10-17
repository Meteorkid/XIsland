import { isAbsolute, win32 } from 'node:path';
import { isRecord, parseDIMessage, utf8Length, type DIMessage, type DIResponse } from '../core/protocol';

/** XIsland 插件产生的事件；供应商事件必须先经插件按原 SDK 转换。 */
export const OPENCODE_HOOK_EVENTS = [
  'session.created', 'prompt.submitted', 'session.deleted', 'tool.started', 'tool.completed', 'tool.failed',
  'permission.asked', 'question.asked', 'interaction.resolved', 'session.compacted',
  'session.idle', 'session.busy', 'session.error', 'assistant.message', 'interaction.unavailable',
] as const;

function text(value: unknown, field: string, empty = false): string {
  if (typeof value !== 'string' || value.includes('\0') || (!empty && !value.trim())) throw new Error(`invalid_opencode_${field}`);
  return value;
}
function optionalText(data: Record<string, unknown>, field: string): string | undefined {
  return data[field] === undefined || data[field] === null ? undefined : text(data[field], field, true);
}
function output(value: unknown): string | undefined {
  return value === undefined || value === null ? undefined : typeof value === 'string' ? value : JSON.stringify(value);
}
function flag(data: Record<string, unknown>, field: string): boolean {
  if (data[field] !== undefined && typeof data[field] !== 'boolean') throw new Error(`invalid_opencode_${field}`);
  return data[field] === true;
}
function labels(value: unknown): string[] {
  if (!Array.isArray(value) || value.some(item => typeof item !== 'string' || !item.trim() || item.includes('\0'))
    || new Set(value).size !== value.length) throw new Error('invalid_opencode_options');
  return [...value];
}

export function normalizeOpenCodeHook(value: unknown, context: { timestamp?: string; hookEventName?: string } = {}): DIMessage {
  if (!isRecord(value)) throw new Error('invalid_opencode_payload');
  const event = text(value.native_event, 'native_event');
  if (!(OPENCODE_HOOK_EVENTS as readonly string[]).includes(event)) throw new Error('unsupported_opencode_event');
  if (context.hookEventName !== undefined && context.hookEventName !== event) throw new Error('opencode_event_mismatch');
  const message: DIMessage = {
    type: 'status_update', sessionId: `opencode-${text(value.session_id, 'session_id')}`,
    timestamp: context.timestamp ?? new Date().toISOString(), agentType: 'opencode', nativeEvent: event,
    workingDir: optionalText(value, 'cwd'), terminal: optionalText(value, 'terminal'), model: optionalText(value, 'model'),
    statusIsAssistantReply: false,
  };
  if (['permission.asked', 'question.asked', 'interaction.resolved', 'interaction.unavailable'].includes(event)) {
    message.nativeRequestId = text(value.native_request_id, 'native_request_id');
    const kind = text(value.native_request_kind, 'native_request_kind');
    if (!['permission', 'question'].includes(kind) || event === 'permission.asked' && kind !== 'permission'
      || event === 'question.asked' && kind !== 'question') throw new Error('invalid_opencode_native_request_kind');
    message.nativeRequestKind = kind;
  }
  switch (event) {
    case 'session.created': message.type = 'session_start'; break;
    case 'prompt.submitted': message.type = 'session_start'; message.prompt = optionalText(value, 'prompt'); break;
    case 'session.deleted': message.type = 'session_end'; message.observedState = 'observationUnavailable'; break;
    case 'tool.started':
    case 'tool.completed':
    case 'tool.failed':
      message.type = event === 'tool.started' ? 'tool_start' : 'tool_complete';
      message.tool = text(value.tool_name, 'tool_name'); message.toolCallId = text(value.tool_use_id, 'tool_use_id');
      message.toolInput = output(value.tool_input); message.toolResult = output(value.tool_response);
      if (event === 'tool.failed') message.observedState = 'error';
      break;
    case 'permission.asked': {
      message.type = 'permission_request'; message.tool = text(value.permission, 'permission');
      if (!Array.isArray(value.patterns) || !value.patterns.every(item => typeof item === 'string' && !item.includes('\0'))) {
        throw new Error('invalid_opencode_patterns');
      }
      message.permDescription = value.patterns.join('\n'); message.toolInput = output(value.metadata);
      const path = value.patterns[0];
      if (['edit', 'write', 'external_directory'].includes(message.tool) && path && (isAbsolute(path) || win32.isAbsolute(path))) message.filePath = path;
      break;
    }
    case 'question.asked':
      message.type = 'question'; message.questionText = text(value.question, 'question'); message.options = labels(value.options);
      message.allowsCustomAnswer = flag(value, 'allow_custom_answer'); message.allowsMultipleAnswers = flag(value, 'allow_multiple_answers');
      if (!message.options.length && !message.allowsCustomAnswer) throw new Error('invalid_opencode_options');
      break;
    case 'interaction.resolved': message.type = 'interaction_resolved'; break;
    case 'session.compacted': message.type = 'recap'; break;
    case 'session.idle': message.observedState = 'idle'; break;
    case 'session.busy': message.observedState = 'active'; break;
    case 'session.error': message.observedState = 'error'; message.status = optionalText(value, 'error'); break;
    case 'assistant.message': message.status = optionalText(value, 'message'); message.statusIsAssistantReply = true; break;
    case 'interaction.unavailable':
      message.observedState = message.nativeRequestKind === 'permission' ? 'waitingPermission' : 'waitingAnswer';
      message.status = '请在 OpenCode 中继续处理此请求。';
      break;
  }
  return parseDIMessage(message);
}

/** 输出仅供本插件消费；为空/失败时插件不调用原 SDK，因此不会默认批准。 */
export function openCodeHookResponse(payload: unknown, response: DIResponse | null): { stdout: string; exitCode: number } {
  const event = isRecord(payload) ? payload.native_event : undefined;
  if (typeof event !== 'string' || !(OPENCODE_HOOK_EVENTS as readonly string[]).includes(event)) return { stdout: '', exitCode: 1 };
  const interactive = event === 'permission.asked' || event === 'question.asked';
  if (response === null) return { stdout: interactive ? '' : '{}', exitCode: interactive ? 1 : 0 };
  const message = normalizeOpenCodeHook(payload);
  if (response.sessionId !== message.sessionId) throw new Error('opencode_response_session_mismatch');
  if (event === 'permission.asked') {
    if (response.type !== 'permission_response' || typeof response.approved !== 'boolean') throw new Error('invalid_opencode_permission_response');
    return { stdout: JSON.stringify({ decision: response.approved ? 'allow' : 'deny' }), exitCode: 0 };
  }
  if (event !== 'question.asked' || response.type !== 'question_response') throw new Error('unexpected_opencode_response');
  if (message.allowsMultipleAnswers) {
    if (response.answer !== undefined) throw new Error('invalid_opencode_question_response');
    const answers = labels(response.selectedAnswers);
    if (!answers.length || answers.length > 128 || answers.reduce((size, item) => size + utf8Length(item), 0) > 8192
      || answers.filter(item => !message.options!.includes(item)).length > (message.allowsCustomAnswer ? 1 : 0)) throw new Error('invalid_opencode_question_response');
    return { stdout: JSON.stringify({ answers }), exitCode: 0 };
  }
  const answer = text(response.answer, 'answer');
  if (response.selectedAnswers !== undefined || utf8Length(answer) > 8192
    || !message.options!.includes(answer) && !message.allowsCustomAnswer) throw new Error('invalid_opencode_question_response');
  return { stdout: JSON.stringify({ answer }), exitCode: 0 };
}
