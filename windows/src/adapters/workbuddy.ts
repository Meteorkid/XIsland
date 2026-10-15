import { isRecord, parseDIMessage, type DIMessage, type DIResponse } from '../core/protocol';

// WorkBuddy 桌面端固定合同；不能用 CodeBuddy CLI 的审批协议替代。
export const WORKBUDDY_HOOK_EVENTS = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
  'PostToolUseFailure', 'Stop', 'FinalStop', 'SessionEnd', 'SubagentStart', 'SubagentStop', 'Notification'] as const;

function text(data: Record<string, unknown>, key: string, empty = false): string {
  const value = data[key];
  if (typeof value !== 'string' || value.includes('\0') || (!empty && !value.trim())) throw new Error(`invalid_workbuddy_${key}`);
  return value;
}
function optionalText(data: Record<string, unknown>, key: string): string | undefined {
  return data[key] === undefined || data[key] === null ? undefined : text(data, key, true);
}
function output(value: unknown): string | undefined {
  return value === undefined || value === null ? undefined : typeof value === 'string' ? value : JSON.stringify(value);
}

/** 只观察已核对的 11 个事件；子代理结束不能结束共用 session_id 的父任务。 */
export function normalizeWorkBuddyHook(value: unknown): DIMessage {
  if (!isRecord(value)) throw new Error('invalid_workbuddy_payload');
  const event = text(value, 'hook_event_name');
  if (!(WORKBUDDY_HOOK_EVENTS as readonly string[]).includes(event)) throw new Error('unsupported_workbuddy_event');
  const message: DIMessage = { type: 'status_update', sessionId: `workbuddy-${Buffer.from(text(value, 'session_id'), 'utf8').toString('base64')}`,
    agentType: 'workbuddy', terminal: 'WorkBuddy', workingDir: optionalText(value, 'cwd'),
    nativeEvent: `workbuddy_5_7_6:${event}`, timestamp: new Date().toISOString(), statusIsAssistantReply: false };
  switch (event) {
    case 'SessionStart':
      message.status = 'WorkBuddy 会话已连接';
      if (optionalText(value, 'source') === 'startup') message.observedState = 'idle';
      break;
    case 'UserPromptSubmit': message.type = 'session_start'; message.prompt = text(value, 'prompt'); break;
    case 'PreToolUse':
    case 'PostToolUse':
    case 'PostToolUseFailure': {
      const tool = text(value, 'tool_name'), call = optionalText(value, 'call_id'), use = optionalText(value, 'tool_use_id');
      if ((call !== undefined && use !== undefined && call !== use) || !isRecord(value.tool_input)
        || (call ?? use) !== undefined && !(call ?? use)!.trim()) throw new Error('invalid_workbuddy_tool_identity');
      message.toolCallId = call ?? use;
      message.toolInput = JSON.stringify(value.tool_input);
      if (event === 'PreToolUse') {
        message.status = `WorkBuddy 准备调用：${tool}`; message.observedState = 'active';
      } else {
        message.type = 'tool_complete'; message.tool = tool;
        message.toolResult = output(value[event === 'PostToolUseFailure' ? 'error' : 'tool_response']);
      }
      break;
    }
    case 'Stop': {
      const reply = optionalText(value, 'last_assistant_message');
      message.observedState = 'completionUnconfirmed';
      message.status = reply || 'WorkBuddy 回复阶段已结束'; message.statusIsAssistantReply = !!reply;
      break;
    }
    case 'FinalStop': {
      const reason = text(value, 'final_stop_reason');
      message.status = 'WorkBuddy 本轮处理已结束';
      if (reason === 'failed') message.observedState = 'error';
      else if (['completed', 'cancelled', 'interrupted'].includes(reason)) message.observedState = 'idle';
      break;
    }
    case 'SessionEnd': message.status = '收到 WorkBuddy 会话结束通知'; break;
    case 'SubagentStart':
    case 'SubagentStop':
      message.status = `WorkBuddy 子代理${event === 'SubagentStart' ? '已开始' : '已结束'}：${optionalText(value, 'agent_type') ?? optionalText(value, 'agent_id') ?? '未命名代理'}`;
      break;
    case 'Notification':
      message.status = text(value, 'message', true);
      if (text(value, 'notification_type') === 'permission_prompt') message.observedState = 'waitingPermission';
      break;
  }
  return parseDIMessage(message);
}

export function workBuddyHookResponse(_payload: unknown, response: DIResponse | null): { stdout: string; exitCode: number } {
  if (response !== null) throw new Error('workbuddy_observation_cannot_answer');
  return { stdout: '', exitCode: 0 };
}
