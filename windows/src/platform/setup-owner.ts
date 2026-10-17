import { IntegrationSetupCoordinator, type SetupSnapshot } from '../integrations/setup-coordinator';
import type { IntegrationPlatform, IntegrationAgent } from '../ui/platform';
import type { SessionStore, DIMessage } from '../core';
import type { ConnectionActivityReceipt } from '../integrations/connection-health';

/** 每个来源仅一个在途确认，密集事件合并为最新回执，避免反复启动 Codex 探测。 */
export class AcceptedActivityQueue {
  private pending = new Map<string, ConnectionActivityReceipt>();
  private running = new Set<string>();
  private disposed = false;
  constructor(private readonly record: (receipt: ConnectionActivityReceipt) => Promise<void>, private readonly report: (error: unknown) => void) {}
  push(receipt: ConnectionActivityReceipt): void {
    if (this.disposed) return;
    this.pending.set(receipt.agent, receipt);
    if (!this.running.has(receipt.agent)) void this.drain(receipt.agent);
  }
  private async drain(agent: string): Promise<void> {
    this.running.add(agent);
    try {
      while (!this.disposed) {
        const receipt = this.pending.get(agent); if (!receipt) break;
        this.pending.delete(agent);
        try { await this.record(receipt); } catch (error) { this.report(error); }
      }
    } finally { this.running.delete(agent); }
  }
  dispose(): void { this.disposed = true; this.pending.clear(); }
}

export type SetupAction = { kind: 'refresh'; prepareAutomatically: boolean }
  | { kind: 'setEnabled'; agent: IntegrationAgent; enabled: boolean } | { kind: 'presented' };
interface OwnerPorts {
  invoke<T>(command: string, args?: Record<string, unknown>): Promise<T>;
  listen<T>(event: string, handler: (event: { payload: T }) => void): Promise<() => void>;
  setInterval(handler: () => void, milliseconds: number): unknown;
  clearInterval(handle: unknown): void;
}

/** 桥接 ACK 只说明已投递；只有状态机真正接纳的实时变化能证明接通。 */
export function acceptedIntegrationActivity(message: DIMessage, accepted: boolean, beforeRevision: number, afterRevision: number): boolean {
  return accepted && beforeRevision !== afterRevision && !message.nativeMessageReplay
    && !['observation_heartbeat', 'observation_ended'].includes(message.type)
    && !['observationUnavailable', 'completionUnconfirmed'].includes(message.observedState ?? '')
    && message.nativeEvent !== 'kimi_code.SessionHeartbeat';
}

export async function startIntegrationSetup(api: IntegrationPlatform, store: SessionStore, ownerToken: string,
  ports: OwnerPorts, report: (error: unknown) => void): Promise<{ dispose(): void; activityReceived(): void }> {
  let publishing = Promise.resolve();
  let disposed = false;
  const artifactStates = new Map<string, { preparing: boolean; attempted: boolean; reported: boolean }>();
  const prepareArtifact = async () => {
    await Promise.all([
      { agent: 'workbuddy', status: api.workBuddyStatus, prepare: api.prepareWorkBuddy },
      { agent: 'kiro', status: api.kiroStatus, prepare: api.prepareKiro },
    ].map(async artifact => {
      const state = artifactStates.get(artifact.agent) ?? { preparing: false, attempted: false, reported: false };
      if (disposed || state.preparing || !artifact.status || !artifact.prepare) return;
      artifactStates.set(artifact.agent, state); state.preparing = true;
      try {
        const status = await artifact.status();
        if (!disposed && !state.attempted && status.client.state === 'detected' && status.runtimeReady && status.needsPreparation) {
          state.attempted = true; await artifact.prepare();
        }
      } catch (error) { state.attempted = true; if (!state.reported) { state.reported = true; report(error); } }
      finally { state.preparing = false; }
    }));
  };
  const coordinator = new IntegrationSetupCoordinator(api, {
    load: () => ports.invoke('read_setup_state'),
    save: state => ports.invoke('save_setup_state', { ownerToken, state }),
  }, {
    changed(snapshot: SetupSnapshot) {
      publishing = publishing.then(async () => {
        if (!disposed) await ports.invoke('publish_setup_snapshot', { ownerToken, snapshot });
      }).catch(report);
    },
    needsAttention() { if (!disposed) void ports.invoke('open_preferences', { pane: 'agents' }).catch(report); },
  });
  const stopStore = store.subscribe(snapshot => coordinator.setInteractionPending(snapshot.sessions.some(session =>
    session.pendingInteractions.some(request => request.phase !== 'failed'))));
  const stopActions = await ports.listen<{ requestId: string; action: SetupAction }>('setup-action', event => {
    void (async () => {
      let error: string | null = null;
      try {
        const action = event.payload.action;
        if (action.kind === 'refresh') await coordinator.refresh(action.prepareAutomatically);
        else if (action.kind === 'setEnabled') await coordinator.setEnabled(action.agent, action.enabled);
        else await coordinator.presented();
      } catch (failure) { error = failure instanceof Error ? failure.message : String(failure); }
      await ports.invoke('finish_setup_action', { ownerToken, requestId: event.payload.requestId, error });
    })().catch(report);
  });
  const stopDismiss = await ports.listen('setup-dismissed', () => { void coordinator.presented().catch(report); });
  // 主窗口是唯一协调器；设置副窗口仅发送动作并读取快照。
  const timer = ports.setInterval(() => { void prepareArtifact(); void coordinator.refresh(true).catch(report); }, 300_000);
  let activityChanged = false;
  const activityTimer = ports.setInterval(() => {
    if (!activityChanged) return;
    activityChanged = false;
    void coordinator.refresh(false).catch(report);
  }, 2000);
  void prepareArtifact().then(() => { if (!disposed) return coordinator.start(); }).catch(report);
  return { activityReceived() { activityChanged = true; }, dispose() {
    disposed = true; coordinator.dispose(); stopStore(); stopActions(); stopDismiss(); ports.clearInterval(timer); ports.clearInterval(activityTimer);
  } };
}
