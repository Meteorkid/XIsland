import { utf8Length } from './protocol';
import type { Session } from './types';

export const GLM_MODEL_FILTER = 'model:glm';

/** GLM 是上报的模型来源，不改变会话所属客户端。 */
export function isGLMModel(model: string): boolean {
  const name = model.trim().toLowerCase();
  return utf8Length(name) <= 256 && /^(?:[a-z0-9._-]+\/)*glm(?:-[a-z0-9][a-z0-9._-]*(?:\[[a-z0-9]+\])?|[0-9][a-z0-9._-]*)?$/.test(name);
}

export interface SessionFilters { agent: string; status: string; query: string }

export function matchesSessionFilters(session: Session, filters: SessionFilters, displayText: string): boolean {
  if (filters.agent !== 'all' && (filters.agent === GLM_MODEL_FILTER ? !isGLMModel(session.usage.model) : session.agentType !== filters.agent)) return false;
  if (filters.status !== 'all' && !(filters.status === 'pending' ? session.pendingInteractions.length > 0
    : filters.status === 'active' ? ['active', 'thinking', 'compacting'].includes(session.status) : session.status === filters.status)) return false;
  return !filters.query || `${displayText} ${session.usage.model}`.toLowerCase().includes(filters.query.toLowerCase());
}

export interface SessionTreeNode { session: Session; children: SessionTreeNode[] }

/** 只使用匹配项构树；被筛掉或显示为待办卡片的父项不会吞掉子会话。 */
export function buildFilteredSessionTree(sessions: readonly Session[]): { pending: Session[]; roots: SessionTreeNode[] } {
  const pending = sessions.filter(session => session.pendingInteractions.length > 0);
  const nodes = new Map(sessions.filter(session => !session.pendingInteractions.length)
    .map(session => [session.id, { session, children: [] } as SessionTreeNode]));
  const roots: SessionTreeNode[] = [];
  for (const node of nodes.values()) {
    const parent = nodes.get(node.session.parentSessionId ?? '');
    const ancestors = new Set([node.session.id]);
    let ancestor = parent;
    while (ancestor && !ancestors.has(ancestor.session.id)) {
      ancestors.add(ancestor.session.id);
      ancestor = nodes.get(ancestor.session.parentSessionId ?? '');
    }
    // 畸形循环关系退回顶层，避免丢失会话或递归渲染。
    if (parent && !ancestor) parent.children.push(node);
    else roots.push(node);
  }
  return { pending, roots };
}
