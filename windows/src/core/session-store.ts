import { hasObservationMetadata, isRecord, parseDIMessage, ProtocolError, utf8Length, type DIMessage, type DIResponse } from './protocol';
import { ObservationLedger, type ObservationSource } from './observation';
import { foldKimiCodeObservation, isKimiCodeMessage, isValidKimiTask, KimiCodeObservationLedger,
  KIMI_TASK_STATUSES, parseKimiObservationState, type KimiCodeFoldResult, type KimiObservationState } from './kimi-tasks';
import { SESSION_STATUSES, isArchivedSession, type ApplyResult, type ChatEntry, type InteractionDecision, type InteractionKind,
  type PendingInteraction, type PreparedResponse, type Session, type SessionStatus, type StoreSnapshot,
  type ToolEvent, type TransportRequest } from './types';

const clone = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
const terminal = isArchivedSession;
const family = (agent: string): boolean => ['cursor', 'trae', 'windsurf'].includes(agent);
const responseTypes = new Set(['permission_response', 'question_response', 'plan_response']);
const activeStates = new Set<SessionStatus>(['active', 'idle', 'waitingPermission', 'waitingAnswer', 'waitingPlanReview']);
const interactionKind = (type: string): InteractionKind | undefined =>
  type === 'permission_request' ? 'permission' : type === 'question' ? 'question' : type === 'plan_review' ? 'plan' : undefined;

function newOwnerInstanceId(): string {
  if (typeof globalThis.crypto.randomUUID === 'function') return globalThis.crypto.randomUUID();
  const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6]! & 15) | 64; bytes[8] = (bytes[8]! & 63) | 128;
  const hex = Array.from(bytes, value => value.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export interface SessionStoreOptions {
  now?: () => number;
  monotonicNow?: () => number;
  id?: () => string;
  readOnly?: boolean;
  ownerInstanceId?: string;
}

export interface HistoryRemoval { sessionIds: string[]; serialized: string; kimiObservationIds?: string[] }
interface KimiStoredObservation {
  sessionId: string;
  sourceNamespace?: string;
  sourceInstanceId?: string;
  nativeTaskId?: string;
  state: KimiObservationState;
}

export function acceptsAnswer(request: PendingInteraction, answer: string): boolean {
  return typeof answer === 'string' && (request.options.includes(answer) || (request.allowsCustomAnswer
    && answer.trim().length > 0 && utf8Length(answer) <= 8192 && !answer.includes('\0')));
}

export function acceptsAnswers(request: PendingInteraction, answers: string[]): boolean {
  return request.allowsMultipleAnswers && Array.isArray(answers) && answers.length > 0 && answers.length <= 128
    && new Set(answers).size === answers.length && answers.every(answer => acceptsAnswer(request, answer))
    && answers.reduce((sum, answer) => sum + utf8Length(answer), 0) <= 8192
    && answers.filter(answer => !request.options.includes(answer)).length <= 1;
}

/** 纯状态核心：平台执行返回的取消/写回意图，不在这里操作连接、窗口或磁盘。 */
export class SessionStore {
  private readOnly = false;
  private mirrorRevision = -1;
  private readonly ownerInstanceId: string;
  private mirrorOwner?: string;
  private retiredOwners = new Set<string>();
  private sessions = new Map<string, Session>();
  private listeners = new Set<(snapshot: StoreSnapshot) => void>();
  private completionListeners = new Set<(sessionId: string) => void>();
  private lastCompletionAt = new Map<string, number>();
  private notifiedReplies = new Set<string>();
  private selectedSessionId?: string;
  private revision = 0;
  private sequence = 0;
  private observation = new ObservationLedger();
  private resolvedRequests = new Set<string>();
  private usedTransports = new Set<string>();
  private submitted = new Map<string, PreparedResponse>();
  private dismissed = new Set<string>();
  private closedWrappers = new Set<string>();
  private closedDeepSeek = new Set<string>();
  private codexTurns = new Map<string, { current: string; observed: Set<string> }>();
  private kimiCodeObservations = new Map<string, KimiStoredObservation>();
  private readonly now: () => number;
  private readonly monotonicNow: () => number;
  private readonly nextId: () => string;

  constructor(options: SessionStoreOptions = {}) {
    this.readOnly = options.readOnly === true;
    this.ownerInstanceId = options.ownerInstanceId ?? newOwnerInstanceId();
    this.now = options.now ?? Date.now;
    this.monotonicNow = options.monotonicNow ?? (() => performance.now());
    this.nextId = options.id ?? (() => `xi-${this.now().toString(36)}-${(++this.sequence).toString(36)}`);
  }

  snapshot(): StoreSnapshot {
    return clone({ sessions: [...this.sessions.values()], selectedSessionId: this.selectedSessionId, revision: this.revision,
      ownerInstanceId: this.readOnly ? this.mirrorOwner : this.ownerInstanceId });
  }

  /** 设置窗口只接收主岛的实时副本，不能持有或提交原生交互通道。 */
  receiveSnapshot(value: unknown): boolean {
    if (!this.readOnly) throw new ProtocolError('snapshot.owner');
    if (!isRecord(value) || !Number.isSafeInteger(value.revision) || (value.revision as number) < 0 || !Array.isArray(value.sessions)) {
      throw new ProtocolError('snapshot');
    }
    const owner = value.ownerInstanceId ?? 'legacy';
    if (typeof owner !== 'string' || !owner || owner.length > 128) throw new ProtocolError('snapshot.ownerInstanceId');
    if (this.retiredOwners.has(owner) || (owner === this.mirrorOwner && (value.revision as number) <= this.mirrorRevision)) return false;
    const sessions = value.sessions.map(validateSession);
    if (new Set(sessions.map(session => session.id)).size !== sessions.length) throw new ProtocolError('snapshot.duplicateSession');
    for (const session of sessions) for (const request of session.pendingInteractions) delete request.transportRequestId;
    if (this.mirrorOwner && this.mirrorOwner !== owner) this.retiredOwners.add(this.mirrorOwner);
    this.mirrorOwner = owner;
    this.sessions = new Map(sessions.map(session => [session.id, session]));
    this.selectedSessionId = typeof value.selectedSessionId === 'string' && this.sessions.has(value.selectedSessionId) ? value.selectedSessionId : sessions[0]?.id;
    this.mirrorRevision = value.revision as number;
    this.revision = this.mirrorRevision;
    for (const listener of this.listeners) listener(this.snapshot());
    return true;
  }

  subscribe(listener: (snapshot: StoreSnapshot) => void): () => void {
    this.listeners.add(listener); listener(this.snapshot());
    return () => { this.listeners.delete(listener); };
  }

  /** 临时通知只来自本实例接受的业务事件，不随历史或设置窗口快照重放。 */
  subscribeCompletion(listener: (sessionId: string) => void): () => void {
    this.completionListeners.add(listener);
    return () => { this.completionListeners.delete(listener); };
  }

  select(id: string): void {
    if (!this.sessions.has(id) || this.selectedSessionId === id) return;
    this.selectedSessionId = id; this.emit();
  }

  apply(value: unknown, transport?: TransportRequest): ApplyResult {
    if (this.readOnly) return { accepted: false, reason: 'Read-only session mirror', cancelRequestIds: [] };
    const cancelled = this.expire();
    const reject = (reason: string, cancel = true): ApplyResult => ({ accepted: false, reason,
      cancelRequestIds: [...cancelled, ...(cancel && transport?.requestId ? [transport.requestId] : [])] });
    let message: DIMessage;
    try { message = parseDIMessage(value); }
    catch (error) { return reject(error instanceof Error ? error.message : 'Invalid message'); }
    if (responseTypes.has(message.type)) return reject('Responses are not incoming session events');
    const kind = interactionKind(message.type);
    if (kind && (!transport || !transport.requestId.trim() || !Number.isFinite(transport.expiresAt) || transport.expiresAt <= this.now())) {
      return reject('Interaction requires a live request channel');
    }
    if (transport && this.usedTransports.has(transport.requestId)) return reject('Duplicate transport request', false);
    const observed = hasObservationMetadata(message);
    let existing = this.findSession(message);
    const observationOnlyAgents = ['workbuddy', 'trae_ide_cn', 'traework_cn', 'kimi', 'kimi_code', 'code_buddy', 'droid', 'kiro', 'copilot_cli', 'pi'];
    if (kind && observationOnlyAgents.some(agent => message.agentType === agent || existing?.agentType === agent || message.sessionId.startsWith(agent + '-'))) {
      return reject('This client source only supports observations');
    }
    if ((!observed && existing?.sourceInstanceId) || (kind && (observed || message.nativeMessageReplay))) return reject('Observation and replay cannot control live interactions');
    if (existing && !this.sameSource(existing, message)) return reject('Session source mismatch');
    const codex = (message.agentType ?? message.sessionId.split('-')[0]) === 'codex';
    const knownTurn = this.codexTurns.get(message.sessionId);
    if (codex && message.nativeEvent === 'UserPromptSubmit' && message.nativeTurnId && knownTurn
      && knownTurn.current !== message.nativeTurnId && knownTurn.observed.has(message.nativeTurnId)) return reject('Retired Codex turn');
    if (codex && ['Interrupt', 'PreCompact', 'PostCompact'].includes(message.nativeEvent ?? '')) {
      if (!existing || !message.nativeTurnId || existing.pendingInteractions.length ||
        ['completed', 'observationUnavailable', 'error', 'waitingPermission', 'waitingAnswer', 'waitingPlanReview'].includes(existing.status)) {
        return reject('Codex turn observation cannot create or interrupt a protected session');
      }
      if (message.nativeEvent === 'PreCompact') {
        if (knownTurn && knownTurn.current !== message.nativeTurnId && knownTurn.observed.has(message.nativeTurnId)) return reject('Retired Codex compaction');
      } else if (knownTurn?.current !== message.nativeTurnId) return reject('Unmatched Codex turn observation');
    }
    if (observed) {
      const decision = this.observation.accept(message, this.monotonicNow(), this.now());
      if (decision.kind === 'rejected') return reject('Invalid or stale observation');
      if (decision.kind === 'ended') { this.endObservation(decision.source, cancelled); this.emit(); return { accepted: true, cancelRequestIds: cancelled }; }
      if (decision.kind === 'heartbeat') return { accepted: true, cancelRequestIds: cancelled };
    }
    if (this.closedWrappers.has(message.sessionId)) {
      if (message.agentType === 'opencode' && message.type === 'session_start' && message.nativeEvent === 'prompt.submitted' && !message.nativeMessageReplay) {
        this.closedWrappers.delete(message.sessionId);
      } else return reject('Wrapper is closed');
    }
    if (message.agentType === 'amazon_q' || message.agentType === 'amazonq') {
      if (message.nativeEvent === 'amazonq_wrapper_end') this.closedWrappers.add(message.sessionId);
    }
    if (message.agentType === 'deepseek') {
      if (message.nativeEvent === 'session_start') this.closedDeepSeek.delete(message.sessionId);
      else if (this.closedDeepSeek.has(message.sessionId)) return reject('DeepSeek session is closed');
      if (message.nativeEvent === 'session_end') this.closedDeepSeek.add(message.sessionId);
    }
    if (existing && family(existing.agentType) && message.sessionId.startsWith('claude_code-')
      && ['session_start', 'session_end'].includes(message.type)) return reject('Mirrored lifecycle is owned by the IDE');
    let kimi: KimiCodeFoldResult | undefined;
    if (isKimiCodeMessage(message)) {
      const stored = this.kimiCodeObservations.get(message.sessionId);
      if (stored && (stored.sourceNamespace !== message.sourceNamespace || stored.sourceInstanceId !== message.sourceInstanceId
        || stored.nativeTaskId !== message.nativeTaskId)) return reject('Kimi observation source mismatch');
      try { kimi = foldKimiCodeObservation(stored?.state, message, { status: existing?.status, statusText: existing?.statusText }); }
      catch (error) { return reject(error instanceof Error ? error.message : 'Invalid Kimi observation'); }
    }
    if (this.dismissed.has(message.sessionId) && !(kimi ? kimi.canRevive : this.isFreshActivity(message))) return reject('Late event for removed session');
    if (kimi) {
      // 心跳/重放不建立孤立账本，也不刷新可见活动时间。
      if (message.nativeEvent === 'kimi_code.SessionHeartbeat' || message.nativeMessageReplay) return { accepted: true, cancelRequestIds: cancelled };
      const stored = this.kimiCodeObservations.get(message.sessionId);
      const changed = JSON.stringify(stored?.state) !== JSON.stringify(kimi.state);
      this.kimiCodeObservations.set(message.sessionId, { sessionId: message.sessionId, sourceNamespace: message.sourceNamespace,
        sourceInstanceId: message.sourceInstanceId, nativeTaskId: message.nativeTaskId, state: kimi.state });
      if (!existing && !kimi.allowCreateSession) {
        if (changed) this.emit();
        return { accepted: true, cancelRequestIds: cancelled };
      }
      if (kimi.handled) {
        const session = existing ?? this.createSession(message);
        this.applyKimiProjection(session, kimi);
        if (message.workingDir) session.workingDirectory = message.workingDir;
        if (changed && !terminal(session)) session.lastActivityAt = this.now();
        if (changed || !existing) this.emit();
        return { accepted: true, cancelRequestIds: cancelled };
      }
    }
    if (message.type === 'interaction_resolved') {
      if (!existing || !message.nativeRequestId || !['permission', 'question'].includes(message.nativeRequestKind ?? '')) return reject('Unmatched interaction resolution');
      const request = existing.pendingInteractions.find(item => item.kind === message.nativeRequestKind && item.nativeRequestId === message.nativeRequestId);
      if (!request) return reject('Unmatched interaction resolution');
      this.cancel(existing, item => item.id === request.id, cancelled); this.updateWaiting(existing); this.emit();
      return { accepted: true, cancelRequestIds: cancelled };
    }
    if (message.type === 'subagent_start' || message.type === 'subagent_end') {
      const parent = this.sessions.get(message.parentSessionId ?? message.sessionId);
      if (!parent || terminal(parent) || (!observed && parent.sourceInstanceId) || !this.sameSource(parent, message)) return reject('Unknown, foreign or closed parent');
      this.applySubagent(parent, message); this.emit(); return { accepted: true, cancelRequestIds: cancelled };
    }
    if (message.type === 'session_end' && !existing) {
      if (message.agentType === 'opencode' && message.nativeEvent === 'session.deleted') {
        this.closedWrappers.add(message.sessionId); this.emit();
        return { accepted: true, cancelRequestIds: cancelled };
      }
      return reject('Unknown session end');
    }
    if (kind === 'question' && (!message.questionText?.trim()
      || (message.questionText.trim() === 'Question' && !message.options?.length && !message.nativeRequestId && !message.allowsCustomAnswer))) return reject('Question placeholder');
    if (kind && message.nativeRequestId && this.resolvedRequests.has(this.requestKey(message, kind))) return reject('Native request already resolved');
    const session = existing ?? this.createSession(message);
    const wasTerminal = terminal(session);
    const latestChatTimestamp = session.chatHistory.at(-1)?.timestamp;
    if (message.agentType && family(message.agentType) && session.id.startsWith('claude_code-')) session.agentType = message.agentType;
    if (message.workingDir) session.workingDirectory = message.workingDir;
    if (message.terminal) session.terminal = message.terminal;
    if (message.termSessionId) session.termSessionId = message.termSessionId;
    if (message.nativeBackgroundTask && !kimi) {
      const index = session.backgroundTasks.findIndex(task => task.id === message.nativeBackgroundTask!.id);
      if (index < 0) session.backgroundTasks.push(clone(message.nativeBackgroundTask));
      else session.backgroundTasks[index] = clone(message.nativeBackgroundTask);
    }
    if (kind) {
      this.cancel(session, request => request.kind === kind, cancelled);
      const request: PendingInteraction = { id: this.nextId(), kind, phase: 'pending', transportRequestId: transport!.requestId,
        wireSessionId: message.sessionId,
        expiresAt: transport!.expiresAt, nativeRequestId: message.nativeRequestId, nativeRequestKind: message.nativeRequestKind,
        tool: message.tool, description: message.permDescription, diff: message.diff, filePath: message.filePath,
        text: message.questionText, options: message.options ?? [], allowsCustomAnswer: message.allowsCustomAnswer === true,
        allowsMultipleAnswers: message.allowsMultipleAnswers === true, markdown: message.planMarkdown };
      session.pendingInteractions.push(request); this.usedTransports.add(transport!.requestId);
      this.resume(session); this.updateWaiting(session); this.selectedSessionId = session.id;
    } else if (message.type === 'session_start') {
      const chatId = this.chatId(message, 'user');
      const duplicate = chatId !== undefined && session.chatHistory.some(chat => chat.id === chatId);
      if (!message.nativeMessageReplay && !duplicate) {
        this.cancel(session, () => true, cancelled); this.resume(session); session.statusText = message.status ?? '';
        if (message.prompt) session.agentResponse = '';
        this.selectedSessionId = session.id;
      }
      if (message.prompt) { session.prompt = message.prompt; this.upsertChat(session, message, 'user', message.prompt); }
    } else if (message.type === 'session_end') {
      this.cancel(session, () => true, cancelled);
      if (message.status) { session.statusText = message.status;
        if (message.statusIsAssistantReply !== false) { session.agentResponse = message.status; this.upsertChat(session, message, 'assistant', message.status); } }
      if (message.observedState === 'observationUnavailable') {
        // 删除或归档结束观察，不意味着任务成功；已有错误和已证终态不能被覆盖。
        if (!['error', 'completed'].includes(session.status)) session.status = 'observationUnavailable';
        session.observationEndedAt ??= this.now();
        for (const event of session.events) if (!event.isComplete) event.completionUnconfirmed = true;
        if (message.agentType === 'opencode' && message.nativeEvent === 'session.deleted') this.closedWrappers.add(message.sessionId);
      } else {
        // 未给出最终事实的轮次结束保持 idle，适配器应显式发送 completed。
        session.status = message.observedState === 'completed' ? 'completed' : 'idle';
        if (session.status === 'completed') session.completedAt = this.now();
      }
      session.currentTool = undefined;
    } else if (message.type === 'tool_start') {
      const event = message.toolCallId ? session.events.find(item => item.toolCallId === message.toolCallId) : undefined;
      if (event) {
        if (['acp', 'continue_snapshot'].includes(message.nativeEvent ?? '')) {
          event.tool = message.tool ?? event.tool; event.input = message.toolInput;
          if (!message.nativeMessageReplay && !terminal(session)) { event.isComplete = false; session.currentTool = event.tool; }
        }
      } else if (!message.nativeMessageReplay) {
        this.resume(session); this.clearLegacyRequests(session, cancelled);
        session.events.push(this.toolEvent(message)); session.currentTool = message.tool; this.updateWaiting(session);
      }
    } else if (message.type === 'tool_complete') {
      this.clearLegacyRequests(session, cancelled);
      const event = [...session.events].reverse().find(item => message.toolCallId !== undefined ? item.toolCallId === message.toolCallId
        : item.toolCallId === undefined && item.tool === (message.tool ?? '') && !item.isComplete);
      const completed = event ?? this.toolEvent(message);
      completed.isComplete = true; completed.result = message.toolResult; completed.linesAdded = message.linesAdded; completed.linesRemoved = message.linesRemoved;
      if (!event) session.events.push(completed);
      if (!terminal(session)) {
        session.currentTool = [...session.events].reverse().find(item => !item.isComplete && !item.completionUnconfirmed)?.tool;
        if (message.observedState === 'error' && !message.nativeMessageReplay && !session.pendingInteractions.length) session.status = 'error';
      }
    } else if (message.type === 'status_update' || message.type === 'progress') {
      this.applyStatus(session, message, cancelled);
    } else if (message.type === 'context_compact' && !message.nativeMessageReplay) {
      this.resume(session, 'compacting'); this.updateWaiting(session);
    } else if (message.type === 'recap') {
      session.recapText = message.recapText ?? message.status ?? '';
    }
    this.updateUsage(session, message);
    if (kimi) this.applyKimiProjection(session, kimi);
    if (codex && session.agentType === 'codex' && message.nativeTurnId && !message.nativeMessageReplay &&
      ['UserPromptSubmit', 'PreCompact', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'Stop'].includes(message.nativeEvent ?? '')) {
      if (['UserPromptSubmit', 'PreCompact'].includes(message.nativeEvent!) || !this.codexTurns.has(session.id)) {
        const known = this.codexTurns.get(session.id) ?? { current: message.nativeTurnId, observed: new Set<string>() };
        known.current = message.nativeTurnId; known.observed.add(message.nativeTurnId); this.codexTurns.set(session.id, known);
      }
    }
    if (!message.nativeMessageReplay && !terminal(session)) session.lastActivityAt = this.now();
    this.emit();
    this.notifyCompletion(session, message, wasTerminal, latestChatTimestamp);
    return { accepted: true, cancelRequestIds: cancelled };
  }

  prepareResponse(sessionId: string, interactionId: string, decision: InteractionDecision): PreparedResponse | null {
    if (this.readOnly) return null;
    const session = this.sessions.get(sessionId);
    const request = session?.pendingInteractions.find(item => item.id === interactionId);
    if (!session || !request || request.kind !== decision.kind || request.phase !== 'pending' || !request.transportRequestId
      || !request.expiresAt || request.expiresAt <= this.now()) return null;
    const base = { sessionId: request.wireSessionId ?? session.id, timestamp: new Date(this.now()).toISOString().replace(/\.\d{3}Z$/, 'Z') };
    let response: DIResponse;
    if (decision.kind === 'permission') {
      if (typeof decision.approved !== 'boolean') return null;
      response = { ...base, type: 'permission_response', approved: decision.approved };
    } else if (decision.kind === 'plan') {
      if (typeof decision.approved !== 'boolean' || (decision.feedback !== undefined && typeof decision.feedback !== 'string')) return null;
      response = { ...base, type: 'plan_response', planApproved: decision.approved, feedback: decision.feedback };
    } else if ('selectedAnswers' in decision && decision.selectedAnswers !== undefined) {
      if ('answer' in decision || !acceptsAnswers(request, decision.selectedAnswers)) return null;
      const selected = request.options.filter(option => decision.selectedAnswers!.includes(option));
      selected.push(...decision.selectedAnswers.filter(answer => !request.options.includes(answer)));
      response = { ...base, type: 'question_response', selectedAnswers: selected };
    } else {
      if (request.allowsMultipleAnswers || !('answer' in decision) || typeof decision.answer !== 'string' || !acceptsAnswer(request, decision.answer)) return null;
      response = { ...base, type: 'question_response', answer: decision.answer };
    }
    request.phase = 'sending';
    const prepared = { interactionId, sessionId, transportRequestId: request.transportRequestId, response };
    this.submitted.set(interactionId, prepared); this.emit(); return clone(prepared);
  }

  confirmResponse(interactionId: string, success: boolean, error?: string): boolean {
    const prepared = this.submitted.get(interactionId);
    if (!prepared) return false;
    this.submitted.delete(interactionId);
    const session = this.sessions.get(prepared.sessionId);
    const request = session?.pendingInteractions.find(item => item.id === interactionId);
    if (!session || !request || request.phase !== 'sending' || request.transportRequestId !== prepared.transportRequestId) return false;
    if (success && request.expiresAt !== undefined && request.expiresAt > this.now()) {
      if (request.nativeRequestId) this.resolvedRequests.add(this.pendingKey(session.id, request));
      session.pendingInteractions = session.pendingInteractions.filter(item => item.id !== interactionId);
      this.updateWaiting(session);
    } else { request.phase = 'failed'; request.error = error ?? '响应未送达，请在原应用继续处理'; }
    this.emit(); return true;
  }

  endTransport(requestId: string, error = '连接已结束，请在原应用继续处理'): boolean {
    let changed = false;
    for (const session of this.sessions.values()) for (const request of session.pendingInteractions) {
      if (request.transportRequestId !== requestId || request.phase === 'failed') continue;
      request.phase = 'failed'; request.error = error;
      this.submitted.delete(request.id); changed = true;
    }
    if (changed) this.emit(); return changed;
  }

  expire(): string[] {
    if (this.readOnly) return [];
    const cancelled: string[] = []; let changed = false;
    for (const source of this.observation.expire(this.monotonicNow())) { this.endObservation(source, cancelled); changed = true; }
    for (const session of this.sessions.values()) for (const request of session.pendingInteractions) {
      if (request.phase !== 'failed' && request.expiresAt !== undefined && request.expiresAt <= this.now()) {
        request.phase = 'failed'; request.error = '请求已超时，请在原应用重新发起';
        if (request.transportRequestId) cancelled.push(request.transportRequestId);
        this.submitted.delete(request.id); changed = true;
      }
    }
    if (changed) this.emit();
    return cancelled;
  }

  dismiss(sessionId: string): boolean {
    if (this.readOnly) return false;
    const session = this.sessions.get(sessionId);
    if (!session || !terminal(session) || session.pendingInteractions.length) return false;
    this.sessions.delete(sessionId); this.kimiCodeObservations.delete(sessionId); this.dismissed.add(sessionId);
    if (this.selectedSessionId === sessionId) this.selectedSessionId = this.sessions.keys().next().value;
    this.emit(); return true;
  }

  clearHistory(): number {
    if (this.readOnly) return 0;
    const ids = [...this.sessions.values()].filter(session => terminal(session) && !session.pendingInteractions.length).map(session => session.id);
    const orphanIds = this.archivedKimiOrphanIds();
    for (const id of ids) { this.sessions.delete(id); this.kimiCodeObservations.delete(id); this.dismissed.add(id); }
    for (const id of orphanIds) { this.kimiCodeObservations.delete(id); this.dismissed.add(id); }
    if (this.selectedSessionId && !this.sessions.has(this.selectedSessionId)) this.selectedSessionId = this.sessions.keys().next().value;
    if (ids.length || orphanIds.length) this.emit(); return ids.length;
  }

  serialize(): string {
    return this.serializeHistory(new Set());
  }

  prepareHistoryRemoval(sessionId?: string): HistoryRemoval {
    if (this.readOnly) throw new ProtocolError('history.owner');
    const candidates = [...this.sessions.values()].filter(session => terminal(session) && !session.pendingInteractions.length);
    const sessionIds = sessionId === undefined ? candidates.map(session => session.id) : candidates.filter(session => session.id === sessionId).map(session => session.id);
    if (sessionId !== undefined && !sessionIds.length) throw new Error('会话仍在运行或存在待处理请求，不能删除');
    const kimiObservationIds = sessionId === undefined ? this.archivedKimiOrphanIds() : [];
    return { sessionIds, serialized: this.serializeHistory(new Set([...sessionIds, ...kimiObservationIds])), kimiObservationIds };
  }

  commitHistoryRemoval(plan: HistoryRemoval): void {
    if (this.readOnly) throw new ProtocolError('history.owner');
    for (const id of plan.sessionIds) {
      const session = this.sessions.get(id);
      if (!session || !terminal(session) || session.pendingInteractions.length) throw new Error('删除计划已失效');
    }
    const orphanIds = new Set(this.archivedKimiOrphanIds());
    if (plan.kimiObservationIds?.some(id => !orphanIds.has(id))) throw new Error('孤立观察删除计划已失效');
    for (const id of plan.sessionIds) { this.sessions.delete(id); this.kimiCodeObservations.delete(id); this.dismissed.add(id); }
    for (const id of plan.kimiObservationIds ?? []) { this.kimiCodeObservations.delete(id); this.dismissed.add(id); }
    if (this.selectedSessionId && !this.sessions.has(this.selectedSessionId)) this.selectedSessionId = this.sessions.keys().next().value;
    if (plan.sessionIds.length || plan.kimiObservationIds?.length) this.emit();
  }

  private archivedKimiOrphanIds(): string[] {
    return [...this.kimiCodeObservations.values()].filter(row => !this.sessions.has(row.sessionId)
      && (['completed', 'observationUnavailable'].includes(row.state.baseStatus)
        || (!row.state.pending.length && !row.state.hasUnidentifiedRequest && !row.state.backgroundTasks.some(task => task.status === 'running'))))
      .map(row => row.sessionId);
  }

  private serializeHistory(excluded: Set<string>): string {
    const sessions = this.snapshot().sessions.filter(session => !excluded.has(session.id));
    // 历史不保存可用于回传的连接凭据。
    for (const session of sessions) for (const request of session.pendingInteractions) {
      delete request.transportRequestId; delete request.expiresAt;
      request.phase = 'failed'; request.error = '应用已重启，请在原应用重新发起请求';
    }
    const selectedSessionId = this.selectedSessionId && !excluded.has(this.selectedSessionId) ? this.selectedSessionId : sessions[0]?.id;
    return JSON.stringify({ version: 1, sessions, selectedSessionId, dismissed: [...new Set([...this.dismissed, ...excluded])],
      closedOpenCodeSessions: [...this.closedWrappers].filter(id => id.startsWith('opencode-')),
      observations: this.observation.serialize(),
      kimiCodeObservations: [...this.kimiCodeObservations.values()].filter(row => !excluded.has(row.sessionId) && !this.dismissed.has(row.sessionId)) });
  }

  restore(serialized: string): void {
    const data: unknown = JSON.parse(serialized);
    if (!isRecord(data) || data.version !== 1 || !Array.isArray(data.sessions)) throw new ProtocolError('history');
    const sessions = data.sessions.map(value => validateSession(value));
    if (new Set(sessions.map(session => session.id)).size !== sessions.length) throw new ProtocolError('history.duplicateSession');
    if (data.selectedSessionId !== undefined && typeof data.selectedSessionId !== 'string') throw new ProtocolError('history.selectedSessionId');
    if (data.dismissed !== undefined && (!Array.isArray(data.dismissed) || !data.dismissed.every(id => typeof id === 'string'))) throw new ProtocolError('history.dismissed');
    const closedOpenCodeSessions = data.closedOpenCodeSessions ?? [];
    if (!Array.isArray(closedOpenCodeSessions) || closedOpenCodeSessions.some(id => typeof id !== 'string' || !id.startsWith('opencode-') || id.length <= 9 || id.includes('\0'))
      || new Set(closedOpenCodeSessions).size !== closedOpenCodeSessions.length) throw new ProtocolError('history.closedOpenCodeSessions');
    const observation = new ObservationLedger();
    observation.restore(data.observations ?? [], this.monotonicNow());
    const kimiCodeObservations = parseKimiStoredObservations(data.kimiCodeObservations ?? [], sessions);
    for (const session of sessions) {
      const legacyKimiApproval = session.agentType === 'kimi' && session.id.startsWith('kimi_code-')
        && session.status === 'waitingPermission' && !kimiCodeObservations.has(session.id);
      for (const request of session.pendingInteractions) {
        delete request.transportRequestId; delete request.expiresAt;
        request.phase = 'failed'; request.error = '应用已重启，请在原应用重新发起请求';
      }
      // 磁盘记录不证明进程仍活着；等待新的业务事实再恢复活动状态。
      if (!terminal(session) && !session.pendingInteractions.length) {
        session.status = 'observationUnavailable'; session.statusText = '已恢复历史，等待原应用的新事件';
        session.observationEndedAt ??= this.now(); session.currentTool = undefined;
      }
      if (session.agentType === 'kimi' && session.id.startsWith('kimi_code-')) {
        const stored = kimiCodeObservations.get(session.id);
        const ledger = new KimiCodeObservationLedger(stored?.state);
        if (!stored) {
          ledger.setBase(session.status, session.statusText);
          for (const task of session.backgroundTasks) ledger.observeTask(task);
          if (legacyKimiApproval) ledger.observeRequest();
        }
        if (session.status === 'completed') ledger.endSession();
        else if (session.status === 'observationUnavailable') {
          ledger.setBase(session.status, session.statusText); ledger.markTasksUnconfirmed(); ledger.observeInterrupt();
        }
        const state = ledger.snapshot();
        session.backgroundTasks = state.backgroundTasks;
        const events = ledger.taskEvents(session.id, this.now(), session.events);
        session.events = session.events.filter(event => !events.some(task => task.id === event.id)).concat(events);
        kimiCodeObservations.set(session.id, { sessionId: session.id, sourceNamespace: session.sourceNamespace,
          sourceInstanceId: session.sourceInstanceId, nativeTaskId: session.nativeTaskId, state });
      }
    }
    this.reset(); this.sessions = new Map(sessions.map(session => [session.id, session]));
    this.observation = observation;
    this.kimiCodeObservations = kimiCodeObservations;
    for (const id of this.closedWrappers) if (id.startsWith('opencode-')) this.closedWrappers.delete(id);
    for (const id of closedOpenCodeSessions) this.closedWrappers.add(id);
    this.dismissed = new Set(data.dismissed as string[] | undefined);
    for (const id of this.dismissed) this.kimiCodeObservations.delete(id);
    this.selectedSessionId = typeof data.selectedSessionId === 'string' && this.sessions.has(data.selectedSessionId) ? data.selectedSessionId : sessions[0]?.id;
    this.emit();
  }

  loadFixture(value: unknown): void {
    if (!isRecord(value) || !Array.isArray(value.sessions)) throw new ProtocolError('fixture');
    // 先在隔离 store 构造，任何坏 fixture 都不能清空当前状态。
    const fixture = new SessionStore({ now: this.now, monotonicNow: this.monotonicNow, id: this.nextId });
    for (const item of value.sessions) {
      if (!isRecord(item) || typeof item.id !== 'string' || typeof item.agentType !== 'string'
        || !SESSION_STATUSES.includes(item.status as SessionStatus)) throw new ProtocolError('fixture.session');
      const message = parseDIMessage({ type: 'session_start', sessionId: item.id, agentType: item.agentType,
        timestamp: new Date(this.now()).toISOString(), workingDir: item.workingDirectory, terminal: item.terminal,
        prompt: item.prompt, status: item.statusText });
      if (fixture.sessions.has(item.id)) throw new ProtocolError('fixture.duplicateSession');
      const session = fixture.createSession(message);
      session.status = item.status as SessionStatus; session.prompt = message.prompt ?? ''; session.statusText = message.status ?? '';
      if (typeof item.agentResponse === 'string') session.agentResponse = item.agentResponse;
      if (session.status === 'completed') session.completedAt = this.now();
      for (const [key, kind] of [['pendingPermission', 'permission'], ['pendingQuestion', 'question'], ['pendingPlanReview', 'plan']] as const) {
        if (item[key] === undefined) continue;
        const pending = item[key]; if (!isRecord(pending)) throw new ProtocolError(`fixture.${key}`);
        const mapped = parseDIMessage({ ...message, type: kind === 'permission' ? 'permission_request' : kind === 'question' ? 'question' : 'plan_review',
          tool: pending.tool, permDescription: pending.description, filePath: pending.filePath, diff: pending.diff,
          questionText: pending.text, options: pending.options, allowsCustomAnswer: pending.allowsCustomAnswer,
          allowsMultipleAnswers: pending.allowsMultipleAnswers, planMarkdown: pending.markdown });
        const result = fixture.apply(mapped, { requestId: `preview:${this.nextId()}`, expiresAt: this.now() + 300_000 });
        if (!result.accepted) throw new ProtocolError(`fixture.${key}`);
      }
    }
    this.reset(); this.sessions = fixture.sessions; this.usedTransports = fixture.usedTransports;
    this.selectedSessionId = typeof value.selectedSessionId === 'string' && this.sessions.has(value.selectedSessionId) ? value.selectedSessionId : this.sessions.keys().next().value;
    this.emit();
  }

  private reset(): void {
    this.sessions.clear(); this.submitted.clear(); this.resolvedRequests.clear(); this.usedTransports.clear(); this.dismissed.clear();
    this.closedWrappers.clear(); this.closedDeepSeek.clear(); this.observation = new ObservationLedger();
    this.codexTurns.clear();
    this.kimiCodeObservations.clear();
    this.lastCompletionAt.clear(); this.notifiedReplies.clear();
  }

  private emit(): void { this.revision++; for (const listener of this.listeners) listener(this.snapshot()); }

  private applyKimiProjection(session: Session, fold: KimiCodeFoldResult): void {
    session.status = fold.status; session.statusText = fold.statusText;
    if (fold.canRevive) { delete session.completedAt; delete session.observationEndedAt; }
    if (fold.status === 'completed') session.completedAt ??= this.now();
    session.backgroundTasks = clone(fold.state.backgroundTasks);
    const events = new KimiCodeObservationLedger(fold.state).taskEvents(session.id, this.now(), session.events);
    const ids = new Set(events.map(event => event.id));
    session.events = session.events.filter(event => !ids.has(event.id)).concat(events);
    if (terminal(session) || fold.status === 'completionUnconfirmed') session.currentTool = undefined;
    else if (events.some(event => !event.isComplete && !event.completionUnconfirmed)) session.currentTool ??= 'Subagent';
    else if (session.currentTool === 'Subagent') session.currentTool = [...session.events].reverse().find(event => !event.isComplete && !event.completionUnconfirmed)?.tool;
  }

  private createSession(message: DIMessage): Session {
    const session: Session = { id: message.sessionId, agentType: message.agentType ?? message.sessionId.split('-')[0] ?? 'unknown',
      status: 'active', prompt: '', statusText: '', agentResponse: '', workingDirectory: message.workingDir ?? '', terminal: message.terminal,
      startedAt: this.now(), lastActivityAt: this.now(), subagentIds: [], events: [], chatHistory: [], pendingInteractions: [],
      usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0, costUSD: 0, model: '' }, backgroundTasks: [],
      sourceNamespace: message.sourceNamespace, sourceInstanceId: message.sourceInstanceId, nativeTaskId: message.nativeTaskId };
    const parentCandidates = [...this.sessions.values()].filter(parent => !terminal(parent)
      && (message.parentSessionId ? parent.id === message.parentSessionId : parent.subagentIds.includes(session.id))
      && parent.agentType === session.agentType && parent.sourceNamespace === session.sourceNamespace
      && parent.sourceInstanceId === session.sourceInstanceId);
    if (parentCandidates.length === 1) {
      const parent = parentCandidates[0]!; session.parentSessionId = parent.id;
      if (!parent.subagentIds.includes(session.id)) parent.subagentIds.push(session.id);
    }
    this.sessions.set(session.id, session); this.dismissed.delete(session.id);
    this.selectedSessionId ??= session.id; return session;
  }

  private findSession(message: DIMessage): Session | undefined {
    const exact = this.sessions.get(message.sessionId); if (exact) return exact;
    const separator = message.sessionId.indexOf('-'); if (separator < 1) return undefined;
    const source = message.sessionId.slice(0, separator), suffix = message.sessionId.slice(separator + 1);
    if (!suffix || (message.agentType && message.agentType !== source) || (source !== 'claude_code' && !family(source))) return undefined;
    const sameSuffix = [...this.sessions.values()].filter(session => session.id.slice(session.id.indexOf('-') + 1) === suffix);
    const candidates = sameSuffix.filter(session => source === 'claude_code'
      ? family(session.agentType) && session.id.startsWith(session.agentType + '-')
      : session.id.startsWith('claude_code-') && (session.agentType === 'claude_code' || session.agentType === source));
    if (candidates.length !== 1) return undefined;
    const session = candidates[0]!;
    if (source !== 'claude_code') {
      if (session.agentType === 'claude_code' && sameSuffix.some(other => family(other.agentType) && other.agentType !== source)) return undefined;
    }
    return session;
  }

  private sameSource(session: Session, message: DIMessage): boolean {
    if (session.sourceNamespace !== message.sourceNamespace || session.sourceInstanceId !== message.sourceInstanceId || session.nativeTaskId !== message.nativeTaskId) return false;
    const sameSuffix = message.sessionId.slice(message.sessionId.indexOf('-') + 1) === session.id.slice(session.id.indexOf('-') + 1);
    const mirror = sameSuffix && ((message.agentType === 'claude_code' && family(session.agentType) && message.sessionId.startsWith('claude_code-'))
      || (message.agentType !== undefined && family(message.agentType) && session.agentType === 'claude_code' && session.id.startsWith('claude_code-')));
    return !message.agentType || message.agentType === session.agentType || mirror;
  }

  private isFreshActivity(message: DIMessage): boolean {
    return !message.nativeMessageReplay && (['session_start', 'tool_start', 'context_compact', 'permission_request', 'question', 'plan_review'].includes(message.type)
      || (['status_update', 'progress'].includes(message.type) && activeStates.has(message.observedState as SessionStatus)));
  }

  private resume(session: Session, status: SessionStatus = 'active'): void {
    session.status = status; delete session.completedAt; delete session.observationEndedAt;
  }

  private cancel(session: Session, matches: (request: PendingInteraction) => boolean, cancelled: string[]): void {
    session.pendingInteractions = session.pendingInteractions.filter(request => {
      if (!matches(request)) return true;
      if (request.transportRequestId) cancelled.push(request.transportRequestId);
      this.submitted.delete(request.id); return false;
    });
  }

  private updateWaiting(session: Session): void {
    const kinds = new Set(session.pendingInteractions.map(request => request.kind));
    if (kinds.has('permission')) session.status = 'waitingPermission';
    else if (kinds.has('question')) session.status = 'waitingAnswer';
    else if (kinds.has('plan')) session.status = 'waitingPlanReview';
    else if (['waitingPermission', 'waitingAnswer', 'waitingPlanReview'].includes(session.status)) session.status = 'active';
  }

  private clearLegacyRequests(session: Session, cancelled: string[]): void {
    this.cancel(session, request => !request.nativeRequestId, cancelled);
    if (!terminal(session)) this.updateWaiting(session);
  }

  private requestKey(message: DIMessage, kind: InteractionKind): string {
    return JSON.stringify([message.sessionId, kind, message.nativeRequestId, kind === 'question' ? [message.questionText, message.options] : null]);
  }

  private pendingKey(sessionId: string, request: PendingInteraction): string {
    return JSON.stringify([sessionId, request.kind, request.nativeRequestId, request.kind === 'question' ? [request.text, request.options] : null]);
  }

  private chatId(message: DIMessage, role: ChatEntry['role']): string | undefined {
    const id = message.nativeMessageId;
    return id && utf8Length(id) <= 512 && !id.includes('\0') ? JSON.stringify([message.sessionId, role, id]) : undefined;
  }

  private notifyCompletion(session: Session, message: DIMessage, wasTerminal: boolean, latestChatTimestamp?: number): void {
    if (message.nativeMessageReplay || message.nativeMessagePartial || (wasTerminal && terminal(session))) return;
    const ended = message.type === 'session_end' && session.status === 'completed';
    const replyEvent = ['status_update', 'progress', 'session_end'].includes(message.type);
    const hasReply = message.statusIsAssistantReply !== false && !!message.status?.trim();
    const replyState = message.observedState === undefined || message.observedState === 'idle'
      || (message.observedState === 'completionUnconfirmed' && message.statusIsAssistantReply === true);
    if (!ended && (!replyEvent || !replyState || !hasReply)) return;
    if (latestChatTimestamp !== undefined && Date.parse(message.timestamp) < latestChatTimestamp) return;
    const replyId = this.chatId(message, 'assistant');
    if (!ended || hasReply) {
      const latest = session.chatHistory.at(-1);
      if (latest?.role !== 'assistant' || (message.nativeMessageId !== undefined && (!replyId || latest.id !== replyId))) return;
    }
    if (replyId) {
      const key = JSON.stringify([session.id, replyId]);
      if (this.notifiedReplies.has(key)) return;
      this.notifiedReplies.add(key);
    }
    const now = this.monotonicNow(), last = this.lastCompletionAt.get(session.id);
    if (last !== undefined && now - last < 1800) return;
    this.lastCompletionAt.set(session.id, now);
    for (const listener of this.completionListeners) listener(session.id);
  }

  private upsertChat(session: Session, message: DIMessage, role: ChatEntry['role'], content: string): void {
    const id = this.chatId(message, role);
    const index = id ? session.chatHistory.findIndex(chat => chat.id === id) : -1;
    if (index >= 0) {
      if (!content) session.chatHistory.splice(index, 1);
      else session.chatHistory[index]!.content = content;
    } else if (content) {
      const last = session.chatHistory.at(-1);
      if (!id && role === 'assistant' && last?.role === role) last.content = content;
      else session.chatHistory.push({ id: id ?? this.nextId(), role, content, timestamp: Date.parse(message.timestamp) });
    }
  }

  private toolEvent(message: DIMessage): ToolEvent {
    return { id: this.nextId(), tool: message.tool ?? 'unknown', toolCallId: message.toolCallId, input: message.toolInput,
      isComplete: false, completionUnconfirmed: false, timestamp: Date.parse(message.timestamp) };
  }

  private applySubagent(parent: Session, message: DIMessage): void {
    let event = message.subagentId ? parent.events.find(item => item.tool === 'Subagent' && item.toolCallId === message.subagentId) : undefined;
    if (message.type === 'subagent_start') {
      if (event) {
        if (['claude_code', 'qwen'].includes(message.agentType ?? '') && message.nativeEvent === 'SubagentStart' && !event.isComplete) event.completionUnconfirmed = false;
        return;
      }
      const childId = message.subagentId ?? this.nextId();
      if (!parent.subagentIds.includes(childId)) parent.subagentIds.push(childId);
      event = this.toolEvent({ ...message, tool: 'Subagent', toolCallId: message.subagentId, toolInput: message.prompt });
      parent.events.push(event);
      const child = this.sessions.get(childId); if (child) child.parentSessionId = parent.id;
    } else {
      if (message.subagentEndIsProvisional && !message.subagentId) return;
      event ??= message.subagentId ? undefined : [...parent.events].reverse().find(item => item.tool === 'Subagent' && !item.isComplete);
      if (!event || event.isComplete) return;
      if (message.subagentEndIsProvisional) event.completionUnconfirmed = true;
      else { event.isComplete = true; event.completionUnconfirmed = false; event.result = 'Completed';
        parent.subagentIds = parent.subagentIds.filter(id => id !== message.subagentId); this.updateUsage(parent, message); }
    }
    parent.lastActivityAt = this.now();
  }

  private applyStatus(session: Session, message: DIMessage, cancelled: string[]): void {
    if (message.prompt !== undefined && message.nativeMessageId) {
      this.upsertChat(session, message, 'user', message.prompt);
      session.prompt = [...session.chatHistory].reverse().find(chat => chat.role === 'user')?.content ?? '';
    }
    if (message.status !== undefined && message.statusIsAssistantReply !== false) {
      this.upsertChat(session, message, 'assistant', message.status);
      session.agentResponse = [...session.chatHistory].reverse().find(chat => chat.role === 'assistant')?.content ?? '';
    }
    const protectedState = terminal(session) || session.status === 'error' || session.pendingInteractions.length > 0;
    const informational = message.statusIsAssistantReply === false && message.observedState === undefined;
    if (!((informational || message.observedState === 'completionUnconfirmed') && protectedState) && message.status !== undefined) session.statusText = message.status;
    if (message.nativeMessageReplay) return;
    if (message.observedState === 'completionUnconfirmed') {
      if (!protectedState) { session.status = 'completionUnconfirmed'; session.currentTool = undefined; }
    } else if (activeStates.has(message.observedState as SessionStatus)) {
      if (message.observedState === 'idle') { this.cancel(session, () => true, cancelled); session.currentTool = undefined; }
      this.resume(session, message.observedState as SessionStatus);
      if (session.pendingInteractions.length) this.updateWaiting(session);
    } else if (message.observedState === 'error' && !terminal(session) && !session.pendingInteractions.length) session.status = 'error';
  }

  private updateUsage(session: Session, message: DIMessage): void {
    for (const [field, target] of [['tokensIn', 'inputTokens'], ['tokensOut', 'outputTokens'], ['totalTokens', 'totalTokens'], ['costUSD', 'costUSD']] as const) {
      const value = message[field]; if (value === undefined || value < 0) continue;
      if (message.usageIsCumulative) session.usage[target] = Math.max(session.usage[target], value);
      else if (field === 'totalTokens') session.usage[target] = value;
      else session.usage[target] += value;
    }
    if (message.model) session.usage.model = message.model;
  }

  private endObservation(source: ObservationSource, cancelled: string[]): void {
    for (const session of this.sessions.values()) if (session.agentType === source.agent && session.sourceNamespace === source.namespace
      && session.sourceInstanceId === source.instance && session.status !== 'completed') {
      this.cancel(session, () => true, cancelled); session.status = 'observationUnavailable';
      session.statusText = '观察已中断，请在原应用确认任务状态'; session.observationEndedAt ??= this.now(); session.currentTool = undefined;
      const stored = this.kimiCodeObservations.get(session.id);
      if (stored) {
        const ledger = new KimiCodeObservationLedger(stored.state);
        ledger.setBase(session.status, session.statusText); ledger.markTasksUnconfirmed(); ledger.observeInterrupt();
        stored.state = ledger.snapshot();
        this.applyKimiProjection(session, { state: stored.state, handled: true, allowCreateSession: false, canRevive: false,
          status: session.status, statusText: session.statusText });
      }
    }
  }
}

function parseKimiStoredObservations(value: unknown, sessions: Session[]): Map<string, KimiStoredObservation> {
  if (!Array.isArray(value)) throw new ProtocolError('history.kimiCodeObservations');
  const result = new Map<string, KimiStoredObservation>();
  for (const row of value) {
    if (!isRecord(row) || typeof row.sessionId !== 'string' || !row.sessionId.startsWith('kimi_code-')
      || row.sessionId.length === 'kimi_code-'.length || row.sessionId.includes('\0') || result.has(row.sessionId)) throw new ProtocolError('history.kimiCodeObservation');
    for (const key of ['sourceNamespace', 'sourceInstanceId', 'nativeTaskId']) {
      if (row[key] !== undefined && typeof row[key] !== 'string') throw new ProtocolError(`history.kimiCodeObservation.${key}`);
    }
    const session = sessions.find(item => item.id === row.sessionId);
    if (session && (session.agentType !== 'kimi' || session.sourceNamespace !== row.sourceNamespace
      || session.sourceInstanceId !== row.sourceInstanceId || session.nativeTaskId !== row.nativeTaskId)) throw new ProtocolError('history.kimiCodeObservation.source');
    const ledger = new KimiCodeObservationLedger(parseKimiObservationState(row.state));
    // 孤立任务的 running 也不是重启后仍存活的证据。
    if (!session) ledger.markTasksUnconfirmed();
    result.set(row.sessionId, { sessionId: row.sessionId, sourceNamespace: row.sourceNamespace as string | undefined,
      sourceInstanceId: row.sourceInstanceId as string | undefined, nativeTaskId: row.nativeTaskId as string | undefined, state: ledger.snapshot() });
  }
  return result;
}

function validateSession(value: unknown): Session {
  if (!isRecord(value)) throw new ProtocolError('history.session');
  for (const key of ['id', 'agentType', 'prompt', 'statusText', 'agentResponse', 'workingDirectory']) {
    if (typeof value[key] !== 'string') throw new ProtocolError(`history.${key}`);
  }
  if (!(value.id as string).trim() || !SESSION_STATUSES.includes(value.status as SessionStatus)) throw new ProtocolError('history.status');
  for (const key of ['startedAt', 'lastActivityAt']) if (typeof value[key] !== 'number' || !Number.isFinite(value[key])) throw new ProtocolError(`history.${key}`);
  for (const key of ['completedAt', 'observationEndedAt']) if (value[key] !== undefined && (typeof value[key] !== 'number' || !Number.isFinite(value[key]))) throw new ProtocolError(`history.${key}`);
  for (const key of ['terminal', 'termSessionId', 'parentSessionId', 'sourceNamespace', 'sourceInstanceId', 'nativeTaskId', 'currentTool', 'recapText']) {
    if (value[key] !== undefined && typeof value[key] !== 'string') throw new ProtocolError(`history.${key}`);
  }
  if (!Array.isArray(value.subagentIds) || !value.subagentIds.every(id => typeof id === 'string')) throw new ProtocolError('history.subagentIds');
  if (!isRecord(value.usage) || typeof value.usage.model !== 'string') throw new ProtocolError('history.usage');
  for (const key of ['inputTokens', 'outputTokens', 'totalTokens', 'costUSD']) {
    if (typeof value.usage[key] !== 'number' || !Number.isFinite(value.usage[key]) || value.usage[key] < 0) throw new ProtocolError(`history.usage.${key}`);
  }
  for (const key of ['events', 'chatHistory', 'pendingInteractions', 'backgroundTasks']) if (!Array.isArray(value[key])) throw new ProtocolError(`history.${key}`);
  for (const event of value.events as unknown[]) {
    if (!isRecord(event) || typeof event.id !== 'string' || typeof event.tool !== 'string' || typeof event.isComplete !== 'boolean'
      || typeof event.completionUnconfirmed !== 'boolean' || typeof event.timestamp !== 'number' || !Number.isFinite(event.timestamp)) throw new ProtocolError('history.event');
    for (const key of ['toolCallId', 'input', 'result']) if (event[key] !== undefined && typeof event[key] !== 'string') throw new ProtocolError(`history.event.${key}`);
    for (const key of ['linesAdded', 'linesRemoved']) if (event[key] !== undefined && !Number.isSafeInteger(event[key])) throw new ProtocolError(`history.event.${key}`);
    if (event.isFailed !== undefined && typeof event.isFailed !== 'boolean') throw new ProtocolError('history.event.isFailed');
    if (event.backgroundTaskStatus !== undefined && !KIMI_TASK_STATUSES.includes(event.backgroundTaskStatus as typeof KIMI_TASK_STATUSES[number])) throw new ProtocolError('history.event.backgroundTaskStatus');
  }
  for (const chat of value.chatHistory as unknown[]) if (!isRecord(chat) || typeof chat.id !== 'string' || !['user', 'assistant', 'system'].includes(chat.role as string)
    || typeof chat.content !== 'string' || typeof chat.timestamp !== 'number' || !Number.isFinite(chat.timestamp)) throw new ProtocolError('history.chat');
  for (const request of value.pendingInteractions as unknown[]) {
    if (!isRecord(request) || typeof request.id !== 'string' || !['permission', 'question', 'plan'].includes(request.kind as string)
      || !['pending', 'sending', 'failed'].includes(request.phase as string) || !Array.isArray(request.options)
      || !request.options.every(option => typeof option === 'string') || typeof request.allowsCustomAnswer !== 'boolean'
      || typeof request.allowsMultipleAnswers !== 'boolean') throw new ProtocolError('history.interaction');
    for (const key of ['transportRequestId', 'wireSessionId', 'nativeRequestId', 'nativeRequestKind', 'tool', 'description', 'diff', 'filePath', 'text', 'markdown', 'error']) {
      if (request[key] !== undefined && typeof request[key] !== 'string') throw new ProtocolError(`history.interaction.${key}`);
    }
  }
  for (const task of value.backgroundTasks as unknown[]) {
    parseDIMessage({ type: 'status_update', sessionId: value.id, timestamp: '2026-10-13T00:00:00Z', nativeBackgroundTask: task });
    if (value.agentType === 'kimi' && (value.id as string).startsWith('kimi_code-') && !isValidKimiTask(task)) throw new ProtocolError('history.kimiBackgroundTask');
  }
  return clone(value) as unknown as Session;
}
