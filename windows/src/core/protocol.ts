export const MESSAGE_TYPES = [
  'session_start', 'session_end', 'tool_start', 'tool_complete',
  'permission_request', 'permission_response', 'question', 'question_response',
  'interaction_resolved', 'plan_review', 'plan_response', 'status_update', 'progress',
  'subagent_start', 'subagent_end', 'context_compact', 'recap',
  'observation_heartbeat', 'observation_ended',
] as const;

export type DIMessageType = typeof MESSAGE_TYPES[number];
export interface DINativeBackgroundTask {
  id: string;
  kind?: string;
  status: string;
  description?: string;
  startedAtMilliseconds?: number;
  result?: string;
}

export interface DIMessage {
  type: DIMessageType;
  sessionId: string;
  timestamp: string;
  agentType?: string;
  nativeEvent?: string;
  nativeAgentId?: string;
  nativeTurnId?: string;
  nativeBackgroundTask?: DINativeBackgroundTask;
  nativeMessageId?: string;
  nativeMessagePartial?: boolean;
  nativeMessageReplay?: boolean;
  sourceNamespace?: string;
  sourceInstanceId?: string;
  nativeTaskId?: string;
  observationSequence?: number;
  terminal?: string;
  termSessionId?: string;
  workingDir?: string;
  prompt?: string;
  toolCallId?: string;
  tool?: string;
  toolInput?: string;
  toolResult?: string;
  linesAdded?: number;
  linesRemoved?: number;
  nativeRequestId?: string;
  nativeRequestKind?: string;
  permDescription?: string;
  diff?: string;
  filePath?: string;
  approved?: boolean;
  questionText?: string;
  options?: string[];
  allowsCustomAnswer?: boolean;
  allowsMultipleAnswers?: boolean;
  answer?: string;
  selectedAnswers?: string[];
  planMarkdown?: string;
  planApproved?: boolean;
  feedback?: string;
  status?: string;
  observedState?: string;
  statusIsAssistantReply?: boolean;
  tokensIn?: number;
  tokensOut?: number;
  totalTokens?: number;
  costUSD?: number;
  usageIsCumulative?: boolean;
  model?: string;
  recapText?: string;
  parentSessionId?: string;
  subagentId?: string;
  subagentEndIsProvisional?: boolean;
}

type ResponseBase = Pick<DIMessage, 'sessionId' | 'timestamp'>;
export type DIResponse = ResponseBase & (
  | { type: 'permission_response'; approved: boolean }
  | { type: 'question_response'; answer: string; selectedAnswers?: never }
  | { type: 'question_response'; selectedAnswers: string[]; answer?: never }
  | { type: 'plan_response'; planApproved: boolean; feedback?: string }
);

export class ProtocolError extends Error {
  constructor(public readonly field: string) { super(`Invalid protocol field: ${field}`); this.name = 'ProtocolError'; }
}

export const MAX_MESSAGE_BYTES = 16 * 1024 * 1024;
export const utf8Length = (value: string): number => new TextEncoder().encode(value).length;
export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

function validTimestamp(value: unknown): value is string {
  if (typeof value !== 'string') return false;
  const parts = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!parts) return false;
  const [, year, month, day, hour, minute, second, , offsetHour, offsetMinute] = parts;
  const y = Number(year), m = Number(month), d = Number(day);
  const leap = y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return m >= 1 && m <= 12 && d >= 1 && d <= days[m - 1]! && Number(hour) < 24
    && Number(minute) < 60 && Number(second) < 60 && Number(offsetHour ?? 0) < 24
    && Number(offsetMinute ?? 0) < 60 && Number.isFinite(Date.parse(value));
}

const strings = [
  'agentType', 'nativeEvent', 'nativeAgentId', 'nativeTurnId', 'nativeMessageId',
  'sourceNamespace', 'sourceInstanceId', 'nativeTaskId', 'terminal', 'termSessionId',
  'workingDir', 'prompt', 'toolCallId', 'tool', 'toolInput', 'toolResult', 'nativeRequestId',
  'nativeRequestKind', 'permDescription', 'diff', 'filePath', 'questionText', 'answer',
  'planMarkdown', 'feedback', 'status', 'observedState', 'model', 'recapText',
  'parentSessionId', 'subagentId',
] as const;
const booleans = [
  'nativeMessagePartial', 'nativeMessageReplay', 'approved', 'allowsCustomAnswer',
  'allowsMultipleAnswers', 'planApproved', 'statusIsAssistantReply', 'usageIsCumulative',
  'subagentEndIsProvisional',
] as const;
const integers = ['observationSequence', 'linesAdded', 'linesRemoved', 'tokensIn', 'tokensOut', 'totalTokens'] as const;

export function parseDIMessage(value: unknown): DIMessage {
  if (!isRecord(value)) throw new ProtocolError('message');
  if (!MESSAGE_TYPES.includes(value.type as DIMessageType)) throw new ProtocolError('type');
  if (typeof value.sessionId !== 'string' || !value.sessionId.trim() || value.sessionId.includes('\0')) throw new ProtocolError('sessionId');
  if (!validTimestamp(value.timestamp)) throw new ProtocolError('timestamp');
  const result: Record<string, unknown> = { type: value.type, sessionId: value.sessionId, timestamp: value.timestamp };
  for (const key of strings) {
    if (value[key] == null) continue;
    if (typeof value[key] !== 'string') throw new ProtocolError(key);
    result[key] = value[key];
  }
  for (const key of booleans) {
    if (value[key] == null) continue;
    if (typeof value[key] !== 'boolean') throw new ProtocolError(key);
    result[key] = value[key];
  }
  for (const key of integers) {
    if (value[key] == null) continue;
    if (!Number.isSafeInteger(value[key])) throw new ProtocolError(key);
    result[key] = value[key];
  }
  for (const key of ['options', 'selectedAnswers'] as const) {
    if (value[key] == null) continue;
    if (!Array.isArray(value[key]) || !value[key].every(item => typeof item === 'string')) throw new ProtocolError(key);
    result[key] = [...value[key]];
  }
  if (value.costUSD != null) {
    if (typeof value.costUSD !== 'number' || !Number.isFinite(value.costUSD)) throw new ProtocolError('costUSD');
    result.costUSD = value.costUSD;
  }
  if (value.nativeBackgroundTask != null) {
    const task = value.nativeBackgroundTask;
    if (!isRecord(task) || typeof task.id !== 'string' || typeof task.status !== 'string') throw new ProtocolError('nativeBackgroundTask');
    const copy: Record<string, unknown> = { id: task.id, status: task.status };
    for (const key of ['kind', 'description', 'result']) {
      if (task[key] == null) continue;
      if (typeof task[key] !== 'string') throw new ProtocolError(`nativeBackgroundTask.${key}`);
      copy[key] = task[key];
    }
    if (task.startedAtMilliseconds != null) {
      if (!Number.isSafeInteger(task.startedAtMilliseconds)) throw new ProtocolError('nativeBackgroundTask.startedAtMilliseconds');
      copy.startedAtMilliseconds = task.startedAtMilliseconds;
    }
    result.nativeBackgroundTask = copy;
  }
  if (utf8Length(JSON.stringify(result)) + 1 > MAX_MESSAGE_BYTES) throw new ProtocolError('message.size');
  return result as unknown as DIMessage;
}

export function encodeMessage(message: DIMessage): string {
  return JSON.stringify(parseDIMessage(message)) + '\n';
}

export function decodeMessage(frame: string): DIMessage {
  if (utf8Length(frame) > MAX_MESSAGE_BYTES) throw new ProtocolError('message.size');
  try { return parseDIMessage(JSON.parse(frame)); }
  catch (error) { if (error instanceof ProtocolError) throw error; throw new ProtocolError('json'); }
}

export function hasObservationMetadata(message: DIMessage): boolean {
  return message.sourceNamespace !== undefined || message.sourceInstanceId !== undefined
    || message.nativeTaskId !== undefined || message.observationSequence !== undefined
    || message.type === 'observation_heartbeat' || message.type === 'observation_ended';
}
