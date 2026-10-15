import { isRecord, ProtocolError, utf8Length, type DIMessage } from './protocol';

export interface ObservationSource { id: string; agent: string; namespace: string; instance: string }
interface Lease { source: ObservationSource; sequence: number; lastSeen: number; ended: boolean; expired: boolean }
export type ObservationDecision = { kind: 'rejected' } | { kind: 'event' | 'heartbeat' | 'ended'; source: ObservationSource };

export function taskSessionId(sourceId: string, task: string): string {
  const bytes = new TextEncoder().encode(task);
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  let result = '', bits = 0, count = 0;
  for (const byte of bytes) {
    bits = (bits << 8) | byte; count += 8;
    while (count >= 6) { count -= 6; result += alphabet[(bits >>> count) & 63]; }
  }
  if (count) result += alphabet[(bits << (6 - count)) & 63];
  return `${sourceId}-${result}`;
}

export class ObservationLedger {
  private leases = new Map<string, Lease>();

  accept(message: DIMessage, monotonicNow: number, wallNow: number): ObservationDecision {
    const { agentType: agent, sourceNamespace: namespace, sourceInstanceId: instance, observationSequence: sequence } = message;
    if (!agent || !['roo_code', 'pearai'].includes(agent) || !namespace || !/^[0-9a-f]{24}$/.test(namespace)
      || !instance || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(instance)
      || !Number.isSafeInteger(sequence) || (sequence ?? 0) < 1) return { kind: 'rejected' };
    const source = { id: `${agent}-${namespace}-${instance}`, agent, namespace, instance };
    const age = wallNow - Date.parse(message.timestamp);
    if (age < -5000 || age > (message.type === 'observation_heartbeat' ? 5000 : 30_000)) return { kind: 'rejected' };
    const control = message.type === 'observation_heartbeat' || message.type === 'observation_ended';
    if (control) {
      if (message.nativeTaskId !== undefined || message.sessionId !== source.id) return { kind: 'rejected' };
    } else {
      const task = message.nativeTaskId;
      if (!['session_start', 'status_update', 'subagent_start', 'subagent_end'].includes(message.type)
        || !task || utf8Length(task) > 16_384 || /[\u0000-\u001f]/.test(task)
        || message.sessionId !== taskSessionId(source.id, task)) return { kind: 'rejected' };
      if (message.type === 'subagent_start' || message.type === 'subagent_end') {
        const child = message.subagentId;
        if (message.parentSessionId !== message.sessionId || !child?.startsWith(source.id + '-')) return { kind: 'rejected' };
        const encoded = child.slice(source.id.length + 1);
        if (!encoded || !/^[A-Za-z0-9_-]+$/.test(encoded) || encoded.length % 4 === 1) return { kind: 'rejected' };
        // 规范 base64url 尾部的填充位必须为零。
        const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
        const tail = alphabet.indexOf(encoded.at(-1)!);
        if ((encoded.length % 4 === 2 && (tail & 15)) || (encoded.length % 4 === 3 && (tail & 3))) return { kind: 'rejected' };
        let bits = 0, count = 0; const bytes: number[] = [];
        for (const char of encoded) { bits = (bits << 6) | alphabet.indexOf(char); count += 6;
          if (count >= 8) { count -= 8; bytes.push((bits >>> count) & 255); } }
        let childTask: string;
        try { childTask = new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array(bytes)); }
        catch { return { kind: 'rejected' }; }
        if (!childTask || bytes.length > 16_384 || /[\u0000-\u001f]/.test(childTask)
          || child !== taskSessionId(source.id, childTask)) return { kind: 'rejected' };
      }
    }
    const previous = this.leases.get(source.id);
    if (previous && (previous.ended || sequence! <= previous.sequence)) return { kind: 'rejected' };
    for (const [id, lease] of this.leases) {
      if ((lease.ended && monotonicNow - lease.lastSeen > 60_000) || (lease.expired && monotonicNow - lease.lastSeen > 300_000)) this.leases.delete(id);
    }
    if (!this.leases.has(source.id) && this.leases.size >= 1024) return { kind: 'rejected' };
    this.leases.set(source.id, { source, sequence: sequence!, lastSeen: monotonicNow, expired: false, ended: message.type === 'observation_ended' });
    return { kind: message.type === 'observation_ended' ? 'ended' : message.type === 'observation_heartbeat' ? 'heartbeat' : 'event', source };
  }

  expire(now: number): ObservationSource[] {
    const expired: ObservationSource[] = [];
    for (const lease of this.leases.values()) if (!lease.ended && !lease.expired && now - lease.lastSeen >= 30_000) {
      lease.expired = true; expired.push(lease.source);
    }
    return expired;
  }

  serialize(): unknown[] {
    return [...this.leases.values()].map(lease => ({ source: { ...lease.source }, sequence: lease.sequence, ended: lease.ended }));
  }

  restore(value: unknown, now: number): void {
    if (!Array.isArray(value) || value.length > 1024) throw new ProtocolError('history.observations');
    const restored = new Map<string, Lease>();
    for (const item of value) {
      if (!isRecord(item) || !isRecord(item.source) || typeof item.ended !== 'boolean'
        || !Number.isSafeInteger(item.sequence) || (item.sequence as number) < 1) throw new ProtocolError('history.observation');
      const { agent, namespace, instance, id } = item.source;
      if (typeof agent !== 'string' || !['roo_code', 'pearai'].includes(agent)
        || typeof namespace !== 'string' || !/^[0-9a-f]{24}$/.test(namespace)
        || typeof instance !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(instance)
        || id !== `${agent}-${namespace}-${instance}` || restored.has(id)) throw new ProtocolError('history.observation.source');
      restored.set(id, { source: { id, agent, namespace, instance }, sequence: item.sequence as number,
        ended: item.ended, expired: true, lastSeen: now });
    }
    this.leases = restored;
  }
}
