import type { Session } from './types';

export interface HistoryUsageSummary {
  agentType: string;
  startedAt: number;
  durationMs: number;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  costUSD: number;
  active: boolean;
}

export function historyDate(session: Pick<Session, 'completedAt' | 'observationEndedAt' | 'startedAt'>): number {
  return session.completedAt ?? session.observationEndedAt ?? session.startedAt;
}

export function compareHistorySessions(left: Session, right: Session): number {
  return historyDate(right) - historyDate(left) || (left.id < right.id ? -1 : left.id > right.id ? 1 : 0);
}

/** 历史片段保持独立；统计同一原生任务时合并累计快照及重叠观察区间。 */
export function aggregateHistoryUsage(sessions: readonly Session[], now = Date.now()): HistoryUsageSummary[] {
  const groups = new Map<string, Session[]>();
  for (const session of sessions) {
    const observed = session.sourceInstanceId !== undefined && session.sourceNamespace !== undefined && session.nativeTaskId !== undefined;
    // 不规范化原生 ID：规范等价的 Unicode 字符串仍可能代表不同任务。
    const key = JSON.stringify(observed ? ['native', session.agentType, session.sourceNamespace, session.nativeTaskId] : ['session', session.id]);
    const records = groups.get(key) ?? [];
    records.push(session); groups.set(key, records);
  }
  return [...groups.values()].map(records => {
    const sorted = [...records].sort((left, right) => left.startedAt - right.startedAt);
    const first = sorted[0]!;
    let durationMs = 0, end = first.startedAt;
    for (const session of sorted) {
      const stop = Math.max(session.startedAt, session.completedAt ?? session.observationEndedAt ?? now);
      durationMs += Math.max(0, stop - Math.max(end, session.startedAt));
      end = Math.max(end, stop);
    }
    return { agentType: first.agentType, startedAt: first.startedAt, durationMs,
      inputTokens: Math.max(...records.map(session => session.usage.inputTokens)),
      outputTokens: Math.max(...records.map(session => session.usage.outputTokens)),
      totalTokens: Math.max(...records.map(session => session.sourceInstanceId === undefined ? session.usage.totalTokens
        : Math.max(session.usage.totalTokens, session.usage.inputTokens + session.usage.outputTokens))),
      costUSD: Math.max(...records.map(session => session.usage.costUSD)),
      active: records.some(session => ['active', 'thinking', 'compacting'].includes(session.status)),
    };
  });
}
