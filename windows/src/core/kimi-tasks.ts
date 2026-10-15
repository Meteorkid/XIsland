import { isRecord, utf8Length, type DIMessage, type DINativeBackgroundTask } from './protocol';
import { SESSION_STATUSES, type SessionStatus, type ToolEvent } from './types';

export const KIMI_TASK_STATUSES = ['running', 'unconfirmed', 'lost', 'completed', 'failed', 'timed_out', 'killed'] as const;
export type KimiTaskStatus = typeof KIMI_TASK_STATUSES[number];
export interface KimiApprovalIdentity { id: string; agentId: string; turnId: string; toolCallId: string }
export interface KimiObservationState {
  version: 1;
  baseStatus: SessionStatus;
  baseStatusText: string;
  pending: KimiApprovalIdentity[];
  resolved: KimiApprovalIdentity[];
  hasUnidentifiedRequest: boolean;
  wasInterrupted: boolean;
  backgroundTasks: DINativeBackgroundTask[];
}
export interface KimiTaskEvent extends ToolEvent { backgroundTaskStatus: KimiTaskStatus; isFailed: boolean }
export class KimiStateError extends Error {
  constructor(field: string) { super(`Invalid Kimi Code observation: ${field}`); this.name = 'KimiStateError'; }
}
const clone = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
const validIdentity = (value: unknown): value is string => typeof value === 'string' && !!value.trim()
  && utf8Length(value) <= 1024 && !/[\p{Cc}\p{Cf}]/u.test(value);
const sameRequest = (left: KimiApprovalIdentity, right: KimiApprovalIdentity): boolean =>
  left.id === right.id && left.agentId === right.agentId && left.turnId === right.turnId && left.toolCallId === right.toolCallId;

export function isKimiCodeMessage(message: DIMessage): boolean {
  return message.agentType === 'kimi' && message.sessionId.startsWith('kimi_code-') && message.nativeEvent?.startsWith('kimi_code.') === true;
}

export function kimiApprovalIdentity(message: DIMessage): KimiApprovalIdentity | undefined {
  const values = [message.nativeRequestId, message.nativeAgentId, message.nativeTurnId, message.toolCallId];
  if (!values.every(validIdentity)) return undefined;
  return { id: message.nativeRequestId!, agentId: message.nativeAgentId!, turnId: message.nativeTurnId!, toolCallId: message.toolCallId! };
}

export function isValidKimiTask(value: unknown): value is DINativeBackgroundTask {
  if (!isRecord(value) || !validIdentity(value.id) || !KIMI_TASK_STATUSES.includes(value.status as KimiTaskStatus)) return false;
  if (value.kind !== undefined && !['agent', 'process', 'question'].includes(value.kind as string)) return false;
  if (value.startedAtMilliseconds !== undefined && (!Number.isSafeInteger(value.startedAtMilliseconds) || (value.startedAtMilliseconds as number) < 0)) return false;
  for (const key of ['description', 'result']) if (value[key] !== undefined && (typeof value[key] !== 'string' || value[key].includes('\0'))) return false;
  return true;
}

export function isFailedKimiTaskStatus(status: string | undefined): boolean {
  return status !== undefined && ['failed', 'timed_out', 'killed'].includes(status);
}

const taskRank = (status: string): number => status === 'running' ? 0 : status === 'unconfirmed' ? 1 : status === 'lost' ? 2 : 3;

/** 同级终态保留首个事实；迟到开始只能补全元数据，不能撤销结束、失败或未知结果证据。 */
export function mergeKimiTask(previous: DINativeBackgroundTask | undefined, incoming: DINativeBackgroundTask, closed = false): DINativeBackgroundTask | undefined {
  if (previous && !isValidKimiTask(previous)) throw new KimiStateError('stored task');
  if (!isValidKimiTask(incoming)) return previous ? clone(previous) : undefined;
  const next = clone(incoming);
  if (closed && next.status === 'running') next.status = 'unconfirmed';
  if (!previous) return next;
  if (previous.id !== next.id) throw new KimiStateError('task identity mismatch');
  if (previous.kind !== undefined && next.kind !== undefined && previous.kind !== next.kind) return clone(previous);
  const merged = clone(previous);
  merged.kind ??= next.kind; merged.description ??= next.description; merged.startedAtMilliseconds ??= next.startedAtMilliseconds;
  if (taskRank(next.status) > taskRank(merged.status)) { merged.status = next.status; merged.result = next.result; }
  else if (merged.status === next.status) merged.result ??= next.result;
  return clone(merged);
}

/** 与模型 toolCallId 使用不同字段/命名空间；不依赖可被模型选择的字符串前缀。 */
export function kimiTaskEventId(sessionId: string, taskId: string): string {
  return JSON.stringify(['kimi_code.background_task', sessionId, taskId]);
}

export function parseKimiObservationState(value: unknown): KimiObservationState {
  if (!isRecord(value) || value.version !== 1 || !SESSION_STATUSES.includes(value.baseStatus as SessionStatus)
    || typeof value.baseStatusText !== 'string' || typeof value.hasUnidentifiedRequest !== 'boolean'
    || typeof value.wasInterrupted !== 'boolean' || !Array.isArray(value.pending) || !Array.isArray(value.resolved)) throw new KimiStateError('snapshot');
  const requests = (rows: unknown[], field: string): KimiApprovalIdentity[] => {
    const ids = new Set<string>();
    return rows.map(row => {
      if (!isRecord(row) || ![row.id, row.agentId, row.turnId, row.toolCallId].every(validIdentity) || ids.has(row.id as string)) throw new KimiStateError(field);
      ids.add(row.id as string);
      return { id: row.id as string, agentId: row.agentId as string, turnId: row.turnId as string, toolCallId: row.toolCallId as string };
    });
  };
  const pending = requests(value.pending, 'pending'), resolved = requests(value.resolved, 'resolved');
  if (pending.some(request => resolved.some(completed => completed.id === request.id))) throw new KimiStateError('pending/resolved overlap');
  const tasks = value.backgroundTasks ?? [];
  if (!Array.isArray(tasks) || !tasks.every(isValidKimiTask) || new Set(tasks.map(task => task.id)).size !== tasks.length) throw new KimiStateError('backgroundTasks');
  return clone({ version: 1, baseStatus: value.baseStatus as SessionStatus, baseStatusText: value.baseStatusText,
    pending, resolved, hasUnidentifiedRequest: value.hasUnidentifiedRequest, wasInterrupted: value.wasInterrupted, backgroundTasks: tasks });
}

/** 仅保存 Node Kimi Code 的原生事实，不含响应回调，也不能批准 Wire 请求。每个session独立持有。 */
export class KimiCodeObservationLedger {
  private state: KimiObservationState;
  constructor(initial?: KimiObservationState) {
    this.state = initial === undefined ? { version: 1, baseStatus: 'idle', baseStatusText: '', pending: [], resolved: [],
      hasUnidentifiedRequest: false, wasInterrupted: false, backgroundTasks: [] } : parseKimiObservationState(initial);
  }
  snapshot(): KimiObservationState { return clone(this.state); }
  get hasPendingApproval(): boolean { return this.state.pending.length > 0 || this.state.hasUnidentifiedRequest; }

  setBase(status: SessionStatus, text: string): void {
    if (!SESSION_STATUSES.includes(status) || typeof text !== 'string') throw new KimiStateError('base state');
    this.state.baseStatus = ['waitingPermission', 'waitingAnswer', 'waitingPlanReview'].includes(status) ? 'active' : status;
    this.state.baseStatusText = text;
  }

  observeRequest(request?: KimiApprovalIdentity): void {
    if (!request || ![request.id, request.agentId, request.turnId, request.toolCallId].every(validIdentity)) { this.state.hasUnidentifiedRequest = true; return; }
    const resolved = this.state.resolved.find(existing => existing.id === request.id);
    if (resolved) { if (!sameRequest(resolved, request)) this.state.hasUnidentifiedRequest = true; return; }
    const pending = this.state.pending.find(existing => existing.id === request.id);
    if (pending) { if (!sameRequest(pending, request)) this.state.hasUnidentifiedRequest = true; return; }
    this.state.pending.push(clone(request));
  }

  observeResult(request?: KimiApprovalIdentity): void {
    if (!request || ![request.id, request.agentId, request.turnId, request.toolCallId].every(validIdentity)) return;
    const pending = this.state.pending.find(existing => existing.id === request.id);
    const resolved = this.state.resolved.find(existing => existing.id === request.id);
    if ((pending && !sameRequest(pending, request)) || (resolved && !sameRequest(resolved, request))) return;
    if (!resolved) this.state.resolved.push(clone(request));
    this.state.pending = this.state.pending.filter(existing => existing.id !== request.id);
    if (!this.state.pending.length) this.state.wasInterrupted = false;
  }

  observeInterrupt(): void { if (this.hasPendingApproval) this.state.wasInterrupted = true; }

  endSession(): void {
    for (const pending of this.state.pending) if (!this.state.resolved.some(request => request.id === pending.id)) this.state.resolved.push(clone(pending));
    this.state.pending = []; this.state.hasUnidentifiedRequest = false; this.state.wasInterrupted = false;
    this.state.baseStatus = 'completed'; this.markTasksUnconfirmed();
  }

  observeTask(incoming: DINativeBackgroundTask, closed = false): boolean {
    const index = this.state.backgroundTasks.findIndex(task => task.id === incoming.id);
    const previous = index < 0 ? undefined : this.state.backgroundTasks[index];
    const merged = mergeKimiTask(previous, incoming, closed || ['completed', 'observationUnavailable'].includes(this.state.baseStatus));
    if (!merged || JSON.stringify(merged) === JSON.stringify(previous)) return false;
    if (index < 0) this.state.backgroundTasks.push(merged); else this.state.backgroundTasks[index] = merged;
    return true;
  }

  markTasksUnconfirmed(): void {
    for (const task of this.state.backgroundTasks) if (task.status === 'running') task.status = 'unconfirmed';
  }

  projection(): { status?: SessionStatus; text?: string } {
    if (!this.hasPendingApproval) return {};
    const unconfirmed = this.state.hasUnidentifiedRequest || this.state.wasInterrupted;
    return { status: unconfirmed ? 'completionUnconfirmed' : 'waitingPermission',
      text: unconfirmed ? 'Kimi Code approval result is unconfirmed' : 'Waiting for permission in Kimi Code' };
  }

  canCreateSessionForTask(taskId: string): boolean {
    return !['completed', 'observationUnavailable'].includes(this.state.baseStatus)
      && this.state.backgroundTasks.some(task => task.id === taskId && task.kind === 'agent' && task.status === 'running');
  }

  taskEvents(sessionId: string, now: number, existing: readonly ToolEvent[] = []): KimiTaskEvent[] {
    if (!Number.isFinite(now)) throw new KimiStateError('clock');
    return [...this.state.backgroundTasks].filter(task => task.kind === 'agent')
      .sort((left, right) => (left.startedAtMilliseconds ?? 0) - (right.startedAtMilliseconds ?? 0) || left.id.localeCompare(right.id))
      .map(task => {
        const id = kimiTaskEventId(sessionId, task.id), previous = existing.find(event => event.id === id);
        const status = task.status as KimiTaskStatus;
        const isComplete = ['completed', 'failed', 'timed_out', 'killed'].includes(status);
        return { id, tool: 'Subagent', input: task.description, timestamp: previous?.timestamp ?? task.startedAtMilliseconds ?? now,
          isComplete, completionUnconfirmed: ['lost', 'unconfirmed'].includes(status),
          result: task.result ?? (isComplete ? `Background task: ${status}` : undefined),
          backgroundTaskStatus: status, isFailed: isFailedKimiTaskStatus(status) };
      });
  }

  merge(incoming: KimiObservationState): void {
    const other = parseKimiObservationState(incoming);
    for (const request of other.resolved) this.observeResult(request);
    for (const request of other.pending) this.observeRequest(request);
    this.state.hasUnidentifiedRequest ||= other.hasUnidentifiedRequest;
    this.state.wasInterrupted = this.hasPendingApproval && (this.state.wasInterrupted || other.wasInterrupted);
    for (const task of other.backgroundTasks) this.observeTask(task);
  }
}
