import type { ManagedAgent } from '../adapters/registry';
import type { IntegrationPlatform, IntegrationStatus } from '../ui/platform';
import { version as applicationVersion } from '../../package.json';

export type SetupPhase = 'notInstalled' | 'disabled' | 'needsConfiguration' | 'needsAuthorization'
  | 'waitingForActivity' | 'connected' | 'checkFailed';
export interface SetupRow {
  agent: ManagedAgent; enabled: boolean; phase: SetupPhase;
  status?: IntegrationStatus; error?: string; fingerprint?: string;
}
export interface SetupSnapshot {
  rows: SetupRow[]; refreshing: boolean; error?: string; attentionCount: number; needsAttention: boolean;
}
export interface SetupState {
  version: 1;
  enabled: Record<ManagedAgent, boolean>;
  attempts: Partial<Record<ManagedAgent, string>>;
  attemptErrors: Partial<Record<ManagedAgent, string>>;
  reminders: Partial<Record<ManagedAgent, string>>;
  introductions: Partial<Record<ManagedAgent, string>>;
}
export interface SetupStorage { load(): Promise<unknown>; save(state: SetupState): Promise<void> }
export interface SetupCallbacks { changed?(snapshot: SetupSnapshot): void; needsAttention?(): void }

// 本表只含可管理来源；类型检查会要求新增 ManagedAgent 时同步补齐。
const defaults: Record<ManagedAgent, boolean> = {
  claude_code: true, codex: true, cursor: true, gemini_cli: true, windsurf: true, trae_cn: true,
  qwen: true, code_buddy: true, droid: true, opencode: true, kimi_code: true,
};
const agents = Object.keys(defaults) as ManagedAgent[];
const record = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);
const message = (error: unknown) => error instanceof Error ? error.message : String(error);
const blocking = (phase: SetupPhase) => ['needsConfiguration', 'needsAuthorization', 'checkFailed'].includes(phase);
const freshState = (): SetupState => ({ version: 1, enabled: { ...defaults }, attempts: {}, attemptErrors: {}, reminders: {}, introductions: {} });
const copyState = (state: SetupState): SetupState => ({ ...state, enabled: { ...state.enabled }, attempts: { ...state.attempts },
  attemptErrors: { ...state.attemptErrors }, reminders: { ...state.reminders }, introductions: { ...state.introductions } });

function readState(value: unknown): SetupState {
  if (value === undefined || value === null) return freshState();
  if (!record(value) || value.version !== 1) throw new Error('接入状态格式无效，自动准备已暂停。');
  const state = freshState();
  for (const field of ['enabled', 'attempts', 'attemptErrors', 'reminders', 'introductions'] as const) {
    const values = value[field];
    if (values === undefined) continue;
    if (!record(values)) throw new Error('接入状态字段无效，自动准备已暂停。');
    for (const agent of agents) {
      const item = values[agent];
      if (item === undefined) continue;
      if (field === 'enabled') {
        if (typeof item !== 'boolean') throw new Error('接入开关记录无效，自动准备已暂停。');
        state.enabled[agent] = item;
      } else {
        if (typeof item !== 'string' || item.length > 65536) throw new Error('接入记录无效，自动准备已暂停。');
        state[field][agent] = item;
      }
    }
  }
  return state;
}

function inputToken(status: IntegrationStatus): string {
  return JSON.stringify([1, applicationVersion, status.agent, status.configPath ?? null, status.revision ?? null,
    status.runtimeReady, status.managedHandlers, status.updateAvailable ?? false, status.client?.executablePath ?? null,
    status.client?.version ?? null]);
}
const fingerprint = (status: IntegrationStatus) => JSON.stringify([inputToken(status), status.agent === 'codex' ? status.trust?.fingerprint ?? null : null]);
const configured = (status: IntegrationStatus) => status.configurationKnown !== false && status.installed === true
  && status.updateAvailable !== true && status.foreignPlugin !== true;
const reminderToken = (row: SetupRow) => JSON.stringify([row.phase, row.fingerprint ?? null]);

/** 只协调平台 API；状态、计划与写入均由调用者注入，不访问文件系统或用户目录。 */
export class IntegrationSetupCoordinator {
  private state = freshState();
  private rows: SetupRow[] = agents.map(agent => ({ agent, enabled: true, phase: 'checkFailed' }));
  private loading?: Promise<void>;
  private started?: Promise<void>;
  private loaded = false;
  private loadFailed = false;
  private inspected = false;
  private flight?: Promise<void>;
  private writes: Promise<void> = Promise.resolve();
  private refreshing = false;
  private refreshPending = false;
  private preparePending = false;
  private presentationPending = false;
  private interactionPending = false;
  private disposed = false;
  private storageError?: string;
  private notifiedToken?: string;
  private generations = new Map<ManagedAgent, number>();
  private enabledOverrides = new Map<ManagedAgent, boolean>();

  constructor(private readonly api: IntegrationPlatform, private readonly storage: SetupStorage,
    private readonly callbacks: SetupCallbacks = {}) {}

  start(): Promise<void> {
    return this.started ??= this.refresh(true);
  }

  async refresh(prepareAutomatically = false): Promise<void> {
    await this.load();
    if (this.disposed) return;
    this.refreshPending = true;
    this.preparePending ||= prepareAutomatically;
    if (this.flight) return this.flight;
    const flight = this.run();
    this.flight = flight;
    try { await flight; }
    finally { if (this.flight === flight) this.flight = undefined; }
  }

  async setEnabled(agent: ManagedAgent, enabled: boolean): Promise<void> {
    if (!agents.includes(agent) || typeof enabled !== 'boolean') throw new Error('接入开关参数无效。');
    await this.load();
    if (this.disposed) return;
    const generation = this.generation(agent) + 1;
    this.generations.set(agent, generation);
    this.enabledOverrides.set(agent, enabled);
    this.rows = this.rows.map(row => row.agent === agent ? { ...row, enabled, phase: enabled ? 'checkFailed' : 'disabled', error: undefined } : row);
    this.publish();
    try {
      await this.save(state => {
        state.enabled[agent] = enabled;
        if (enabled) { delete state.attempts[agent]; delete state.attemptErrors[agent]; }
      });
    } finally {
      if (this.generation(agent) === generation) this.enabledOverrides.delete(agent);
      this.rows = this.rows.map(row => row.agent === agent ? this.row(agent, row.status) : row);
      this.publish();
    }
    await this.refresh(enabled);
  }

  async presented(): Promise<void> {
    // 窗口在状态查询返回前被打开或关闭，也算用户已阅本轮的最终结果。
    if (!this.loaded || this.refreshing) this.presentationPending = true;
    await this.load();
    if (this.disposed) return;
    if (this.refreshing) this.presentationPending = true;
    await this.markPresented(this.rows);
    this.publish();
  }

  setInteractionPending(pending: boolean): void {
    this.interactionPending = pending;
    if (pending) this.notifiedToken = undefined;
    else this.notify();
  }

  dispose(): void { this.disposed = true; this.refreshPending = false; this.preparePending = false; }

  snapshot(): SetupSnapshot {
    return { rows: structuredClone(this.rows), refreshing: this.refreshing, ...(this.storageError ? { error: this.storageError } : {}),
      attentionCount: this.rows.filter(row => blocking(row.phase)).length,
      needsAttention: this.rows.some(row => this.unseen(row)) };
  }

  private generation(agent: ManagedAgent) { return this.generations.get(agent) ?? 0; }
  private enabled(agent: ManagedAgent) { return this.enabledOverrides.get(agent) ?? this.state.enabled[agent]; }
  private current(agent: ManagedAgent, generation: number) { return !this.disposed && this.generation(agent) === generation; }
  private publish() { if (!this.disposed) this.callbacks.changed?.(this.snapshot()); }

  private load(): Promise<void> {
    return this.loading ??= (async () => {
      try { this.state = readState(await this.storage.load()); }
      catch (error) { this.loadFailed = true; this.storageError = `读取接入状态失败：${message(error)}`; }
      this.loaded = true;
      this.rows = this.rows.map(row => this.row(row.agent, row.status));
    })();
  }

  private async save(change: (state: SetupState) => void): Promise<void> {
    const write = this.writes.then(async () => {
      if (this.disposed) return;
      if (this.loadFailed) throw new Error(this.storageError);
      const next = copyState(this.state);
      change(next);
      if (JSON.stringify(next) === JSON.stringify(this.state)) return;
      try { await this.storage.save(copyState(next)); }
      catch (error) {
        // 保存失败后，本实例不再自动写客户端配置；内存仍保留最后真正保存的状态。
        this.storageError = `保存接入状态失败：${message(error)}`;
        this.publish();
        throw error;
      }
      this.state = next;
    });
    this.writes = write.catch(() => {});
    return write;
  }

  private async run(): Promise<void> {
    this.refreshing = true;
    this.publish();
    try {
      do {
        const prepare = this.preparePending;
        this.refreshPending = false; this.preparePending = false;
        await this.inspect(prepare);
        if (this.disposed) return;
        while (!this.refreshPending && this.presentationPending && !this.disposed) {
          this.presentationPending = false;
          try { await this.markPresented(this.rows); } catch { /* save 已公开存储错误。 */ }
        }
      } while (this.refreshPending && !this.disposed);
      this.inspected = true;
    } finally {
      this.refreshing = false;
      this.publish();
    }
    this.notify();
  }

  private async inspect(prepare: boolean): Promise<void> {
    const results = await Promise.all(agents.map(async agent => {
      const generation = this.generation(agent);
      try {
        const status = structuredClone(await this.api.status(agent));
        if (status.agent !== agent) throw new Error('客户端状态来源不匹配。');
        return { agent, generation, status };
      } catch (error) { return { agent, generation, error: message(error) }; }
    }));
    for (const result of results) {
      const { agent, generation } = result;
      if (!this.current(agent, generation)) continue;
      let status = result.status, error = result.error;
      if (status && prepare && this.eligible(status) && this.state.attempts[agent] !== inputToken(status)) {
        const token = inputToken(status);
        try {
          await this.save(state => { state.attempts[agent] = token; delete state.attemptErrors[agent]; });
          if (!this.current(agent, generation) || !this.enabled(agent) || this.storageError) continue;
          const plan = await this.api.plan(agent, 'install');
          if (!this.current(agent, generation) || !this.enabled(agent) || this.storageError) continue;
          if (plan.agent !== agent || plan.operation !== 'install' || plan.revision !== status.revision
            || plan.configPath !== status.configPath || !plan.runtimeReady) throw new Error('接入计划与当前状态不一致，请重新检查。');
          if (plan.changed) await this.api.apply(agent, 'install', plan.revision);
          if (!this.current(agent, generation)) continue;
          status = structuredClone(await this.api.status(agent));
          if (status.agent !== agent) throw new Error('客户端状态来源不匹配。');
          if (!configured(status)) throw new Error('准备完成后仍未确认接入配置完整。');
        } catch (failure) {
          error = message(failure);
          if (this.current(agent, generation) && this.state.attempts[agent] === token) {
            try { await this.save(state => { state.attemptErrors[agent] = error; }); } catch { /* 保留原始准备错误。 */ }
          }
        }
      }
      if (!this.current(agent, generation)) continue;
      if (status && configured(status) && this.state.attempts[agent]) {
        try { await this.save(state => { delete state.attempts[agent]; delete state.attemptErrors[agent]; }); }
        catch { /* 已保存的失败记录不能假装清除。 */ }
      }
      if (!this.current(agent, generation)) continue;
      const row = this.row(agent, status, error);
      this.rows = this.rows.map(previous => previous.agent === agent ? row : previous);
      if (row.phase === 'connected') {
        try {
          await this.save(state => {
            delete state.reminders[agent];
            state.introductions[agent] = reminderToken({ ...row, phase: 'waitingForActivity' });
          });
        } catch { /* 实际连接证据仍有效，存储错误单独展示。 */ }
      }
    }
    this.publish();
  }

  private eligible(status: IntegrationStatus): boolean {
    return !this.storageError && this.enabled(status.agent) && status.client?.state === 'detected'
      && status.platformSupported === true && status.runtimeReady === true && status.configurationKnown !== false
      && status.installed !== null && !configured(status) && !status.foreignPlugin
      && !!status.configPath?.trim() && !!status.revision?.trim();
  }

  private row(agent: ManagedAgent, status?: IntegrationStatus, failure?: string): SetupRow {
    const row: SetupRow = { agent, enabled: this.enabled(agent), phase: 'checkFailed', ...(status ? { status, fingerprint: fingerprint(status) } : {}) };
    if (!row.enabled) return { ...row, phase: 'disabled' };
    if (failure) return { ...row, error: failure };
    if (!status) return { ...row, error: '尚未取得客户端状态。' };
    if (status.client?.state === 'not_found') return { ...row, phase: 'notInstalled' };
    if (status.client?.state !== 'detected') return { ...row, error: status.client?.detail ?? '尚未确认客户端安装。' };
    if (!status.platformSupported || status.configurationKnown === false || status.installed === null) {
      return { ...row, error: status.reason ?? '当前平台或配置状态尚未确认。' };
    }
    const previousFailure = this.state.attempts[agent] === inputToken(status) ? this.state.attemptErrors[agent] : undefined;
    if (!configured(status) && previousFailure) return { ...row, error: previousFailure };
    if (!status.runtimeReady || !configured(status)) return { ...row, phase: 'needsConfiguration', ...(status.reason ? { error: status.reason } : {}) };
    if (agent === 'codex') {
      if (status.trust?.state === 'required') return { ...row, phase: 'needsAuthorization' };
      if (status.trust?.state !== 'granted') return { ...row, error: status.trust?.reason ?? '尚未确认 Codex hook 信任状态。' };
    }
    const activity = status.activity;
    return { ...row, phase: activity && activity.event.trim() && Number.isFinite(activity.receivedAt) && activity.receivedAt >= 0 ? 'connected' : 'waitingForActivity' };
  }

  private unseen(row: SetupRow): boolean {
    if (row.phase === 'waitingForActivity') return this.state.introductions[row.agent] !== reminderToken(row);
    return blocking(row.phase) && this.state.reminders[row.agent] !== reminderToken(row);
  }

  private async markPresented(rows: SetupRow[]): Promise<void> {
    await this.save(state => {
      for (const row of rows) {
        if (row.phase === 'waitingForActivity') state.introductions[row.agent] = reminderToken(row);
        else if (blocking(row.phase)) state.reminders[row.agent] = reminderToken(row);
      }
    });
  }

  private notify(): void {
    if (this.disposed || !this.inspected || this.refreshing || this.interactionPending) return;
    const unseen = this.rows.filter(row => this.unseen(row));
    if (!unseen.length) { this.notifiedToken = undefined; return; }
    const token = JSON.stringify(unseen.map(row => [row.agent, reminderToken(row)]));
    if (this.notifiedToken === token) return;
    this.notifiedToken = token;
    this.callbacks.needsAttention?.();
  }
}
