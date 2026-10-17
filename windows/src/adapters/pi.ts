import { isRecord, parseDIMessage, type DIMessage, type DIResponse } from '../core/protocol';

export const PI_HOOK_EVENTS = [
  'session_start', 'before_agent_start', 'agent_start', 'tool_execution_start',
  'tool_execution_end', 'agent_end', 'agent_settled', 'session_shutdown',
] as const;

function text(value: unknown, field: string, empty = false): string {
  if (typeof value !== 'string' || value.includes('\0') || (!empty && !value.trim())) throw new Error(`invalid_pi_${field}`);
  return value;
}
function optionalText(data: Record<string, unknown>, field: string): string | undefined {
  return data[field] == null ? undefined : text(data[field], field, true);
}
function output(value: unknown): string | undefined {
  return value == null ? undefined : typeof value === 'string' ? value : JSON.stringify(value);
}

/** Pi ExtensionAPI 观察事件；不把 tool_call 伪装成可批准的权限请求。 */
export function normalizePiHook(value: unknown, context: { timestamp?: string; hookEventName?: string } = {}): DIMessage {
  if (!isRecord(value)) throw new Error('invalid_pi_payload');
  const event = text(value.native_event, 'native_event');
  if (!(PI_HOOK_EVENTS as readonly string[]).includes(event)) throw new Error('unsupported_pi_event');
  if (context.hookEventName !== undefined && context.hookEventName !== event) throw new Error('pi_event_mismatch');
  const message: DIMessage = {
    type: 'status_update', sessionId: `pi-${text(value.session_id, 'session_id')}`,
    timestamp: context.timestamp ?? new Date().toISOString(), agentType: 'pi', nativeEvent: event,
    workingDir: optionalText(value, 'cwd'), terminal: optionalText(value, 'terminal'), model: optionalText(value, 'model'),
    statusIsAssistantReply: false,
  };
  switch (event) {
    case 'session_start': message.type = 'session_start'; break;
    case 'before_agent_start': message.type = 'session_start'; message.prompt = optionalText(value, 'prompt'); break;
    case 'agent_start': message.observedState = 'active'; break;
    case 'tool_execution_start':
    case 'tool_execution_end':
      message.type = event === 'tool_execution_start' ? 'tool_start' : 'tool_complete';
      message.tool = text(value.tool_name, 'tool_name'); message.toolCallId = text(value.tool_use_id, 'tool_use_id');
      message.toolInput = output(value.tool_input); message.toolResult = output(value.tool_response);
      if (value.native_status !== undefined && !['done', 'error'].includes(text(value.native_status, 'native_status'))) throw new Error('invalid_pi_native_status');
      if (event === 'tool_execution_end' && value.native_status === 'error') message.observedState = 'error';
      break;
    // agent_end 后仍可能自动重试、压缩和续跑，不能提前报告 idle。
    case 'agent_end': break;
    case 'agent_settled': message.observedState = 'idle'; break;
    case 'session_shutdown': message.type = 'session_end'; message.observedState = 'completed'; break;
  }
  return parseDIMessage(message);
}

export function piHookResponse(_payload: unknown, response: DIResponse | null): { stdout: string; exitCode: number } {
  if (response !== null) throw new Error('pi_observation_cannot_answer');
  return { stdout: '', exitCode: 0 };
}
