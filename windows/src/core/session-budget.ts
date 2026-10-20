import { MAX_MESSAGE_BYTES, utf8Length, type DIMessage } from './protocol';

// 为重启文案、连接失败和既有审批的收尾保留空间；到限拒收，不裁剪历史。
export const SESSION_BUDGET = { bytes: 14 * 1024 * 1024, boundaryBytes: MAX_MESSAGE_BYTES,
  sessions: 10_000, records: 100_000 } as const;

export interface SessionBudgetUsage { bytes: number; sessions: number; records: number }

export class SessionCapacityError extends Error {
  constructor(detail: string) {
    super(`会话容量不足：${detail}。新数据未接纳，已有记录未删除；请导出并清理已结束的历史后重试，当前操作可在原应用继续。`);
    this.name = 'SessionCapacityError';
  }
}

export function assertSessionBoundary(serialized: string, boundary: string): void {
  if (utf8Length(serialized) > SESSION_BUDGET.boundaryBytes) throw new SessionCapacityError(`${boundary}超过 16 MiB`);
}

/** JSON 字符串字节含转义开销；通用字段最多预留八份，长文本按实际最多副本数预留。 */
export function messageReservation(message: DIMessage, transport?: { requestId: string; expiresAt: number }): number {
  let bytes = utf8Length(JSON.stringify(message)) * 8 + 8192;
  for (const [key, copies] of [['toolResult', 1], ['toolInput', 1], ['prompt', 2], ['status', 4]] as const) {
    if (message[key] !== undefined) bytes -= utf8Length(JSON.stringify(message[key])) * (8 - copies);
  }
  return bytes + (transport ? utf8Length(JSON.stringify(transport)) * 2 : 0);
}

export function capacityError(usage: SessionBudgetUsage, growth: SessionBudgetUsage, completing: boolean): SessionCapacityError | undefined {
  const byteLimit = completing ? SESSION_BUDGET.boundaryBytes - 64 * 1024 : SESSION_BUDGET.bytes;
  if (usage.bytes + growth.bytes > byteLimit) return new SessionCapacityError(`完整记录及安全预留将超过 ${completing ? '16' : '14'} MiB`);
  if (growth.sessions && usage.sessions + growth.sessions > SESSION_BUDGET.sessions) return new SessionCapacityError('会话总数达到 10000');
  if (growth.records && usage.records + growth.records > SESSION_BUDGET.records) return new SessionCapacityError('事件、聊天和去重记录总数达到 100000');
}

export function freezeSnapshot<T>(value: T): T {
  if (value !== null && typeof value === 'object' && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) freezeSnapshot(child);
    Object.freeze(value);
  }
  return value;
}

export function boundedTransportError(error: string): string {
  return utf8Length(error) <= 1024 ? error : '连接失败（错误详情超过大小上限），请在原应用继续处理';
}
