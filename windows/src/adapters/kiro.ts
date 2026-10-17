import { isRecord, parseDIMessage, type DIMessage, type DIResponse } from '../core/protocol';

/** 已核对的 Kiro CLI 2.31.0 V3 独立 hook 合同；不把 IDE 或 Classic 事件猜成此协议。 */
export const KIRO_HOOK_EVENTS = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd'] as const;

function text(data: Record<string, unknown>, field: string, allowEmpty = false): string {
  const value = data[field];
  if (typeof value !== 'string' || value.includes('\0') || (!allowEmpty && !value.trim())) throw new Error(`invalid_kiro_${field}`);
  return value;
}

/** 前置工具事件只表示准备，所有权限与回答继续由 Kiro 处理。 */
export function normalizeKiroHook(value: unknown): DIMessage {
  if (!isRecord(value)) throw new Error('invalid_kiro_payload');
  const event = text(value, 'hook_event_name');
  if (!(KIRO_HOOK_EVENTS as readonly string[]).includes(event)) throw new Error('unsupported_kiro_event');
  const nativeId = text(value, 'session_id'), cwd = text(value, 'cwd');
  if (/[\u0000-\u001f\u007f]/.test(nativeId) || /[\u0000-\u001f\u007f]/.test(cwd)) throw new Error('invalid_kiro_identity');
  const message: DIMessage = { type: 'status_update', sessionId: `kiro-cli-${Buffer.from(nativeId, 'utf8').toString('base64')}`,
    agentType: 'kiro', terminal: 'Kiro CLI', workingDir: cwd, nativeEvent: `kiro_cli_${event}`,
    timestamp: new Date().toISOString(), statusIsAssistantReply: false };
  switch (event) {
    case 'SessionStart': message.type = 'session_start'; message.status = 'Kiro 会话已开始'; break;
    case 'UserPromptSubmit': message.type = 'session_start'; message.prompt = text(value, 'prompt', true); break;
    case 'PreToolUse': {
      const tool = text(value, 'tool_name');
      if (!isRecord(value.tool_input)) throw new Error('invalid_kiro_tool_input');
      message.status = `Kiro 准备调用：${tool}`; message.observedState = 'active';
      break;
    }
    case 'PostToolUse':
      message.type = 'tool_complete'; message.tool = text(value, 'tool_name');
      if (!isRecord(value.tool_input) || !isRecord(value.tool_response)) throw new Error('invalid_kiro_tool_payload');
      message.toolInput = JSON.stringify(value.tool_input); message.toolResult = JSON.stringify(value.tool_response);
      if (value.tool_response.success === false) message.observedState = 'error';
      break;
    case 'Stop':
      if (value.assistant_response !== undefined) {
        message.status = text(value, 'assistant_response', true); message.statusIsAssistantReply = true;
      } else message.status = 'Kiro 本轮结束待确认';
      // 其他 Stop hook 仍可请求继续；没有答案正文也不能丢掉本轮结束事实。
      message.observedState = 'completionUnconfirmed'; break;
    case 'SessionEnd':
      message.type = 'session_end'; message.observedState = 'completed'; message.status = 'Kiro 会话已结束'; break;
  }
  return parseDIMessage(message);
}

/** hook stdout 会进入 Kiro 上下文；观察失败也由外围限时启动器保持空输出。 */
export function kiroHookResponse(_payload: unknown, response: DIResponse | null): { stdout: string; exitCode: number } {
  if (response !== null) throw new Error('kiro_observation_cannot_answer');
  return { stdout: '', exitCode: 0 };
}
