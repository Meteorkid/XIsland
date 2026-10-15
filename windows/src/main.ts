import { isTauri, invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { SessionStore, type DIMessage, type DIResponse, type StoreSnapshot } from './core';
import { mountIsland, type IslandPlatform, type IslandSettings } from './ui';
import { fixtures } from './fixtures';
import { loadSettings } from './ui/settings';
import { installNativeDrag } from './platform/native-drag';
import './platform/native.css';
import type { SoundEvent } from './ui/audio';

const native = isTauri();
const query = new URLSearchParams(location.search);
const preferencesWindow = native && query.get('window') === 'settings';
const store = new SessionStore({ readOnly: preferencesWindow });
const root = document.querySelector<HTMLElement>('#app')!;
type Envelope = { message: DIMessage; requestId?: string; expiresAt?: number };
type HistoryAction = { kind: 'dismiss'; sessionId: string } | { kind: 'clear' };
let ui: ReturnType<typeof mountIsland>;
let ownerFrozen = false;
const deferredEvents: Array<() => void> = [];
function mutateOwner(action: () => void): void {
  if (ownerFrozen) deferredEvents.push(action); else action();
}

function report(error: unknown): void {
  ui?.showError(error instanceof Error ? error.message : String(error));
}

const platform: IslandPlatform = native ? {
  preview: false,
  preferencesWindow,
  initialSettingsPane: query.get('pane') ?? 'general',
  resize: (width, height, expanded) => preferencesWindow ? Promise.resolve() : invoke('resize_island', { width, height, expanded }),
  focus: () => invoke('focus_input'),
  respond: (requestId, response) => invoke('respond', { requestId, response }),
  jump: session => invoke('jump_to_session', { title: session.workingDirectory.split(/[\\/]/).filter(Boolean).at(-1) ?? session.prompt }),
  exportHistory: content => invoke('export_history', { content }),
  openSettings: pane => invoke('open_preferences', { pane }),
  closeSettings: () => invoke('close_preferences'),
  settingsChanged: settings => invoke('save_preferences', { settings }),
  deleteHistory: sessionId => invoke('history_action', { action: { kind: 'dismiss', sessionId } }),
  clearHistory: () => invoke('history_action', { action: { kind: 'clear' } }),
  previewSound: event => invoke('preview_sound', { event }),
  integrations: {
    exportWorkBuddy: () => invoke('integration_command', { agent: 'workbuddy', action: 'export' }),
    status: agent => invoke('integration_command', { agent, action: 'status' }),
    plan: (agent, operation) => invoke('integration_command', { agent, action: 'plan', operation }),
    apply: (agent, operation, revision) => invoke('integration_command', { agent, action: 'apply', operation, revision }),
  },
} : {
  preview: true,
  resize: async () => {},
  focus: async () => { window.focus(); },
  respond: async (requestId: string, _response: DIResponse) => {
    if (!requestId.startsWith('preview:')) throw new Error('浏览器预览不能响应真实 Agent');
  },
  jump: async () => { throw new Error('预览样例没有实际终端窗口'); },
  exportHistory: async content => {
    const url = URL.createObjectURL(new Blob([content], { type: 'application/json' }));
    const link = document.createElement('a'); link.href = url; link.download = 'XIsland-preview-history.json'; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  },
};

ui = mountIsland(root, store, platform);
if (native && !preferencesWindow) {
  const disposeDrag = installNativeDrag(root, phase => invoke('drag_island', { phase }), report);
  window.addEventListener('pagehide', disposeDrag, { once: true });
}
const cancel = (requestId: string) => invoke('cancel_request', { requestId }).catch(report);
function applyEnvelope(envelope: Envelope): void {
  if (ownerFrozen) { deferredEvents.push(() => applyEnvelope(envelope)); return; }
  const transport = envelope.requestId && envelope.expiresAt ? { requestId: envelope.requestId, expiresAt: envelope.expiresAt } : undefined;
  const result = store.apply(envelope.message, transport);
  for (const id of result.cancelRequestIds) void cancel(id);
  if (!result.accepted && result.reason) report(`事件未接纳：${result.reason}`);
}

async function syncSettings(): Promise<void> {
  const info = await invoke<{ capabilities: NonNullable<IslandPlatform['capabilities']>; nativeAutoplayAudio?: boolean }>('platform_info');
  platform.capabilities = info.capabilities;
  platform.nativeAutoplayAudio = info.nativeAutoplayAudio === true;
  ui.applySettings(loadSettings());
  let changed = false;
  await listen<IslandSettings>('preferences-changed', event => { changed = true; ui.applySettings(event.payload); });
  try {
    const settings = await invoke<IslandSettings | null>('read_preferences');
    if (settings && !changed) ui.applySettings(settings);
  } catch (error) { report(error); }
}

async function connectPreferences(): Promise<void> {
  await listen<StoreSnapshot>('session-snapshot', event => { try { store.receiveSnapshot(event.payload); } catch (error) { report(error); } });
  await listen<string>('settings-pane', event => { ui.showSettings(event.payload as Parameters<typeof ui.showSettings>[0]); });
  const snapshot = await invoke<StoreSnapshot | null>('read_snapshot');
  if (snapshot) store.receiveSnapshot(snapshot);
}

async function connectOwner(): Promise<void> {
  let historyWritable = true;
  try {
    const history = await invoke<string | null>('load_history');
    if (history) store.restore(history);
  } catch (error) {
    historyWritable = false;
    report(`历史载入失败，原文件已保留。新会话暂不写入历史：${String(error)}`);
  }
  let timer: ReturnType<typeof setTimeout> | undefined;
  let saving = Promise.resolve();
  let historyActions = Promise.resolve();
  let ownerToken: string | undefined;
  let protectedInteraction: boolean | undefined;
  const publish = (snapshot: StoreSnapshot) => {
    if (ownerToken) void invoke('publish_snapshot', { snapshot, ownerToken }).catch(report);
    const protectedValue = snapshot.sessions.some(session => session.pendingInteractions.some(request => request.phase !== 'failed'));
    if (protectedValue !== protectedInteraction) {
      protectedInteraction = protectedValue;
      void invoke('protect_interaction', { protected: protectedValue }).catch(report);
    }
  };
  const persist = (content?: string): Promise<void> => {
    if (!historyWritable) return Promise.reject(new Error('原历史尚未恢复，请先导出当前记录'));
    const next = saving.catch(() => {}).then(() => invoke<void>('save_history', { content: content ?? store.serialize(), ownerToken }));
    saving = next; return next;
  };
  // 主窗口维护状态，设置窗口只接收去除回传凭据的实时副本。
  store.subscribe(snapshot => {
    publish(snapshot);
    clearTimeout(timer);
    if (historyWritable && !ownerFrozen && ownerToken) timer = setTimeout(() => { void persist().catch(report); }, 300);
  });
  await listen<{ requestId: string; action: HistoryAction }>('history-action', event => {
    historyActions = historyActions.catch(report).then(async () => {
      let error: string | null = null;
      try {
        if (!historyWritable) throw new Error('历史载入失败，不能执行删除');
        ownerFrozen = true; clearTimeout(timer);
        const plan = store.prepareHistoryRemoval(event.payload.action.kind === 'dismiss' ? event.payload.action.sessionId : undefined);
        await persist(plan.serialized);
        store.commitHistoryRemoval(plan);
      } catch (failure) { error = failure instanceof Error ? failure.message : String(failure); }
      finally {
        ownerFrozen = false;
        for (const action of deferredEvents.splice(0)) action();
        if (historyWritable) {
          clearTimeout(timer);
          timer = setTimeout(() => { void persist().catch(report); }, 300);
        }
      }
      await invoke('finish_history_action', { requestId: event.payload.requestId, error });
    }).catch(report);
  });
  await listen<{ requestId: string; event: SoundEvent }>('preview-sound', event => {
    void (async () => {
      let error: string | null = null;
      try { await ui.previewSound(event.payload.event); }
      catch (failure) { error = failure instanceof Error ? failure.message : String(failure); }
      await invoke('finish_sound_preview', { requestId: event.payload.requestId, error });
    })().catch(report);
  });
  let booting = true;
  const live: Array<Envelope | string> = [];
  await listen<Envelope>('di-message', event => { if (booting) live.push(event.payload); else applyEnvelope(event.payload); });
  const ended = (requestId: string) => mutateOwner(() => { store.endTransport(requestId, '连接已结束，请回原客户端处理'); });
  await listen<string>('di-request-ended', event => { if (booting) live.push(event.payload); else ended(event.payload); });
  await listen<string>('di-error', event => report(event.payload));
  const initial = await invoke<{ events: Envelope[]; endedRequestIds: string[]; ownerToken: string; error?: string }>('frontend_ready');
  ownerToken = initial.ownerToken;
  for (const envelope of initial.events) applyEnvelope(envelope);
  for (const requestId of initial.endedRequestIds) ended(requestId);
  for (const event of live) typeof event === 'string' ? ended(event) : applyEnvelope(event);
  booting = false;
  publish(store.snapshot());
  if (initial.error) report(initial.error);
  setInterval(() => mutateOwner(() => { for (const id of store.expire()) void cancel(id); }), 1000);
}

async function connect(): Promise<void> {
  if (!native) {
    document.documentElement.classList.add('preview-mode');
    const fixture = query.get('fixture');
    if (fixture) {
      if (!(fixture in fixtures)) throw new Error('未知的预览样例');
      store.loadFixture(fixtures[fixture]);
    }
    if (query.get('expanded') === '1') ui.expand();
    if (query.get('settings') === '1') ui.showSettings();
    setInterval(() => store.expire(), 1000);
    return;
  }
  await syncSettings();
  await (preferencesWindow ? connectPreferences() : connectOwner());
}

void connect().catch(report);
