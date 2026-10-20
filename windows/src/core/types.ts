import type { DIResponse, DINativeBackgroundTask } from './protocol';

export const SESSION_STATUSES = ['active', 'idle', 'thinking', 'waitingPermission', 'waitingAnswer',
  'waitingPlanReview', 'completed', 'error', 'compacting', 'observationUnavailable', 'completionUnconfirmed'] as const;
export type SessionStatus = typeof SESSION_STATUSES[number];
export type InteractionKind = 'permission' | 'question' | 'plan';
export interface PendingInteraction {
  id: string;
  kind: InteractionKind;
  phase: 'pending' | 'sending' | 'failed';
  transportRequestId?: string;
  wireSessionId?: string;
  expiresAt?: number;
  nativeRequestId?: string;
  nativeRequestKind?: string;
  tool?: string;
  toolInput?: string;
  description?: string;
  diff?: string;
  filePath?: string;
  text?: string;
  options: string[];
  allowsCustomAnswer: boolean;
  allowsMultipleAnswers: boolean;
  markdown?: string;
  error?: string;
}
export type InteractionDecision =
  | { kind: 'permission'; approved: boolean }
  | { kind: 'question'; answer: string; selectedAnswers?: never }
  | { kind: 'question'; selectedAnswers: string[]; answer?: never }
  | { kind: 'plan'; approved: boolean; feedback?: string };
export type Decision = InteractionDecision;
export interface PreparedResponse {
  interactionId: string;
  sessionId: string;
  transportRequestId: string;
  response: DIResponse;
}
export interface ToolEvent {
  id: string;
  tool: string;
  toolCallId?: string;
  input?: string;
  result?: string;
  linesAdded?: number;
  linesRemoved?: number;
  isComplete: boolean;
  completionUnconfirmed: boolean;
  backgroundTaskStatus?: string;
  isFailed?: boolean;
  timestamp: number;
}
export interface ChatEntry {
  id: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: number;
}
export interface TokenUsage { inputTokens: number; outputTokens: number; totalTokens: number; costUSD: number; model: string }
export interface Session {
  id: string;
  agentType: string;
  status: SessionStatus;
  prompt: string;
  statusText: string;
  agentResponse: string;
  workingDirectory: string;
  terminal?: string;
  termSessionId?: string;
  startedAt: number;
  lastActivityAt: number;
  completedAt?: number;
  observationEndedAt?: number;
  parentSessionId?: string;
  subagentIds: string[];
  events: ToolEvent[];
  chatHistory: ChatEntry[];
  pendingInteractions: PendingInteraction[];
  usage: TokenUsage;
  sourceNamespace?: string;
  sourceInstanceId?: string;
  nativeTaskId?: string;
  currentTool?: string;
  recapText?: string;
  backgroundTasks: DINativeBackgroundTask[];
}
export interface StoreSnapshot { sessions: Session[]; selectedSessionId?: string; revision: number; ownerInstanceId?: string }
export function isArchivedSession(session: Pick<Session, 'status' | 'observationEndedAt'>): boolean {
  return ['completed', 'observationUnavailable'].includes(session.status) || (session.status === 'error' && session.observationEndedAt !== undefined);
}
export interface TransportRequest { requestId: string; expiresAt: number }
export interface ApplyResult { accepted: boolean; reason?: string; cancelRequestIds: string[] }
