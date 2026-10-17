import { t, locale, setLanguage } from './i18n';
import { isArchivedSession, type Decision, type PendingInteraction, type Session, type SessionStore, type StoreSnapshot, type ToolEvent } from '../core/index';
import { aggregateHistoryUsage, compareHistorySessions, historyDate } from '../core/history-summary';
import { GLM_MODEL_FILTER, isGLMModel, matchesSessionFilters, buildFilteredSessionTree, type SessionTreeNode } from '../core/session-filter';
import { agentColor, agentName, badge, button, el, icon, markdown, mascot, statusColor, statusLabel } from './components';
import { DEFAULT_SETTINGS, IslandSound, isQuiet, loadSettings, normalizeSettings, saveSettings } from './settings';
import type { IslandPlatform, IslandSettings, IslandLinkPreferences } from './platform';
import { IslandMotion, motionPolicy } from './motion';
import { IntegrationControls } from './integration-controls';
import { SOUND_EVENTS, SOUND_LABELS, type SoundEvent } from './audio';
import './styles.css';
import { IslandSwitchGesture } from './island-switch';

export type { IslandPlatform, IslandSettings } from './platform';

type SettingsPane = 'general' | 'display' | 'integration' | 'agents' | 'sound' | 'history' | 'statistics' | 'about';
const PANES: Array<[SettingsPane, string, string]> = [
  ['general', '通用', 'settings'], ['display', '显示', 'screen'], ['integration', '集成', 'flow'], ['agents', 'Agents', 'terminal'],
  ['sound', '声音', 'sound'], ['history', '历史', 'history'], ['statistics', '统计', 'chart'], ['about', '关于', 'info'],
];
const LIVE = new Set(['active', 'thinking', 'compacting']);

function toolOutcome(event: ToolEvent): { symbol: string; icon: string; color: string } {
  if (event.isFailed || ['failed', 'timed_out', 'killed'].includes(event.backgroundTaskStatus ?? '')) return { symbol: '✕', icon: 'warning', color: 'var(--red)' };
  if (event.completionUnconfirmed || ['lost', 'unconfirmed'].includes(event.backgroundTaskStatus ?? '')) return { symbol: '?', icon: 'question', color: 'var(--orange)' };
  return event.isComplete ? { symbol: '✓', icon: 'check', color: 'var(--green)' } : { symbol: '…', icon: 'terminal', color: 'var(--muted)' };
}

function displayedEvents(session: Session): ToolEvent[] {
  // 原生进程/未知类型任务单独显示，不伪装成子 Agent，也不按名称猜配工具调用。
  return [...session.events, ...session.backgroundTasks.filter(task => task.kind !== 'agent').map(task => ({
    id: `native-background:${task.id}`, tool: `${t(task.kind === 'process' ? '后台进程' : '后台任务')} · ${task.description || task.id}`,
    timestamp: task.startedAtMilliseconds ?? session.lastActivityAt,
    isComplete: ['completed', 'failed', 'timed_out', 'killed'].includes(task.status),
    completionUnconfirmed: ['lost', 'unconfirmed'].includes(task.status),
    isFailed: ['failed', 'timed_out', 'killed'].includes(task.status), backgroundTaskStatus: task.status, result: task.result,
  }))];
}

function title(session: Session): string {
  return session.prompt.split('\n').find(line => line.trim())?.trim() || workspace(session) || agentName(session.agentType);
}
function workspace(session: Session): string { return session.workingDirectory.split(/[\\/]/).filter(Boolean).at(-1) ?? ''; }
function duration(session: Session): string {
  return durationText((session.completedAt ?? session.observationEndedAt ?? Date.now()) - session.startedAt);
}
function durationText(milliseconds: number): string {
  const elapsed = Math.max(0, Math.floor(milliseconds / 1000));
  return elapsed < 60 ? '<1m' : elapsed < 3600 ? `${Math.floor(elapsed / 60)}m` : `${Math.floor(elapsed / 3600)}h ${Math.floor(elapsed % 3600 / 60)}m`;
}
function time(timestamp: number): string { return new Date(timestamp).toLocaleTimeString(locale(), { hour: '2-digit', minute: '2-digit' }); }
function formatNumber(value: number): string { return new Intl.NumberFormat(locale(), { notation: 'compact', maximumFractionDigits: 1 }).format(value); }
function modelLabel(model: string): HTMLElement {
  const label = el('span', 'session-model', model); label.title = model;
  label.setAttribute('aria-label', t('模型：{model}', { model })); return label;
}

export function mountIsland(element: HTMLElement, store: SessionStore, platform: IslandPlatform) {
  let snapshot: StoreSnapshot = store.snapshot();
  let settings: IslandSettings;
  let message = '';
  setLanguage(DEFAULT_SETTINGS.language);
  try { settings = loadSettings(); } catch { settings = { ...DEFAULT_SETTINGS }; message = t('设置无法读取，已使用默认值。'); }
  setLanguage(settings.language);
  let expanded = !!platform.preferencesWindow;
  let overview = false;
  let settingsPane: SettingsPane | undefined = platform.preferencesWindow ? (PANES.some(([id]) => id === platform.initialSettingsPane) ? platform.initialSettingsPane as SettingsPane : 'general') : undefined;
  let settingsWrite = Promise.resolve();
  let showFilter = false, query = '', filter = 'all', agentFilter = 'all', showActivity = false;
  let detailSession: string | undefined;
  let lastDimensions = '';
  let autoHide: ReturnType<typeof setTimeout> | undefined;
  let hoverExit: ReturnType<typeof setTimeout> | undefined;
  let toastTimer: ReturnType<typeof setTimeout> | undefined;
  let resizeTimer: ReturnType<typeof setTimeout> | undefined;
  let disposed = false;
  let switchingIsland = false;
  let linkPreferences: IslandLinkPreferences = { swipeEnabled: true, sensitivity: 'medium', startupDisplay: 'lastUsed' };
  let linkPreferencesReady = !platform.getIslandPreferences, linkReadBusy = false, linkWriteBusy = false, linkRevision = 0;
  let linkPreferencesError = '';
  const switchGesture = new IslandSwitchGesture();
  let composing = false, renderAfterComposition = false;
  const details = new Set<string>(), childGroups = new Set<string>(), projectGroups = new Set<string>();
  const drafts = new Map<string, string>(), choices = new Map<string, Set<string>>();
  const sound = new IslandSound();
  const previousStatuses = new Map<string, string>();
  const previousUserMessages = new Map<string, string | undefined>();
  const seenToolEvents = new Set<string>();
  const seenRequests = new Set<string>();
  const scheme = matchMedia('(prefers-color-scheme: dark)');
  const systemMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const shell = el('main', 'island-shell');
  shell.setAttribute('aria-label', 'XIsland');
  shell.setAttribute('tabindex', '-1');
  const toast = el('div', 'island-toast'); toast.setAttribute('role', 'status');
  element.replaceChildren(shell, toast);
  const motion = new IslandMotion(shell,settings,systemMotion.matches);
  const integrations = new IntegrationControls(platform.integrations,!!platform.preview,render);

  const pendingCount = () => snapshot.sessions.reduce((sum, session) => sum + session.pendingInteractions.length, 0);
  const visibleSessions = () => snapshot.sessions.filter(session => !isArchivedSession(session) || session.pendingInteractions.length > 0 ||
    (session.status === 'completed' && session.completedAt !== undefined && Date.now() - session.completedAt < 120_000));
  const showError = (error: unknown) => showMessage(error instanceof Error ? error.message : String(error));
  const run = (task: () => Promise<unknown>) => { void task().catch(showError); };

  async function switchIsland() {
    if (switchingIsland || !platform.switchIsland || platform.preferencesWindow) return;
    switchingIsland = true; render();
    try {
      const status = await platform.islandPeerStatus?.();
      if (status && (!status.installed || !status.compatible)) throw new Error(status.detail);
      await platform.switchIsland();
    } catch (error) { showError(error); }
    finally { switchingIsland = false; if (!disposed) render(); }
  }

  async function refreshLinkPreferences() {
    if (!platform.getIslandPreferences || linkReadBusy || linkWriteBusy || disposed) return;
    linkReadBusy = true; const revision = linkRevision;
    try {
      const value = await platform.getIslandPreferences();
      if (revision !== linkRevision || disposed) return;
      const changed = !linkPreferencesReady || JSON.stringify(value) !== JSON.stringify(linkPreferences) || !!linkPreferencesError;
      linkPreferences = value; linkPreferencesReady = true; linkPreferencesError = '';
      if (changed && settingsPane === 'general' && !shell.querySelector('input:focus,select:focus,textarea:focus')) render();
    } catch (error) {
      linkPreferencesError = error instanceof Error ? error.message : String(error);
    } finally { linkReadBusy = false; }
  }
  async function changeLinkPreferences(patch: Partial<IslandLinkPreferences>) {
    if (!platform.setIslandPreferences || !linkPreferencesReady || linkWriteBusy) return;
    linkWriteBusy = true; linkRevision++; render();
    try { linkPreferences = await platform.setIslandPreferences({ ...linkPreferences, ...patch }); linkPreferencesError = ''; }
    catch (error) { showError(error); }
    finally { linkWriteBusy = false; if (!disposed) render(); }
  }
  function linkPreferencesCard(): HTMLElement {
    const zh = locale().startsWith('zh');
    const enabled = el('label','setting-row');
    enabled.append(rowLabel(zh?'横滑切换 XNook':'Swipe to switch XNook',zh?'两个应用共享此设置；按钮切换仍可使用。':'Shared by both apps; the switch button remains available.'));
    const toggle = el('input','switch'); toggle.type='checkbox';toggle.checked=linkPreferences.swipeEnabled;
    toggle.disabled=!linkPreferencesReady||linkWriteBusy||!platform.setIslandPreferences;
    toggle.setAttribute('aria-label',zh?'横滑切换 XNook':'Swipe to switch XNook');
    toggle.addEventListener('change',()=>{void changeLinkPreferences({swipeEnabled:toggle.checked});});enabled.append(toggle);
    const sensitivity = el('label','setting-row');sensitivity.append(rowLabel(zh?'切换灵敏度':'Switch sensitivity',''));
    const level=select(zh?'切换灵敏度':'Switch sensitivity', [['low',zh?'低':'Low'],['medium',zh?'中':'Medium'],['high',zh?'高':'High']],linkPreferences.sensitivity,value=>{void changeLinkPreferences({sensitivity:value as IslandLinkPreferences['sensitivity']});});
    level.disabled=toggle.disabled;sensitivity.append(level);
    const startup = el('label','setting-row');startup.append(rowLabel(zh?'启动时显示':'Show at startup',zh?'首选应用不可用时显示当前应用。':'Falls back to this app if the preferred app is unavailable.'));
    const target=select(zh?'启动时显示':'Show at startup',[['lastUsed',zh?'上次使用':'Last used'],['xnook','XNook'],['xisland','XIsland']],linkPreferences.startupDisplay,value=>{void changeLinkPreferences({startupDisplay:value as IslandLinkPreferences['startupDisplay']});});target.disabled=toggle.disabled;startup.append(target);
    const card=settingCard(enabled,sensitivity,startup);
    if(linkPreferencesError)card.append(el('p','setting-description',linkPreferencesError));
    return card;
  }

  function showMessage(text: string) {
    message = text;
    toast.textContent = text;
    toast.classList.add('visible');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { message = ''; toast.classList.remove('visible'); }, 5000);
  }

  function scheduleAutoHide() {
    if (autoHide) clearTimeout(autoHide);
    if (expanded && !settingsPane && pendingCount() === 0 && settings.autoHideSeconds > 0) {
      autoHide = setTimeout(collapse, settings.autoHideSeconds * 1000);
    }
  }

  function expand() { if (platform.preferencesWindow) return; expanded = true; settingsPane = undefined; render(); scheduleAutoHide(); }
  function collapse() {
    if (platform.preferencesWindow) { run(() => platform.closeSettings?.() ?? Promise.resolve()); return; }
    expanded = false; settingsPane = undefined; detailSession = undefined;
    if (autoHide) clearTimeout(autoHide);
    render();
  }
  function showSettings(pane: SettingsPane = 'general') {
    if (platform.openSettings && !platform.preferencesWindow) { run(() => platform.openSettings!(pane)); return; }
    expanded = true; settingsPane = pane; detailSession = undefined;
    if (autoHide) clearTimeout(autoHide);
    render(); run(() => platform.focus());
  }

  function applySettings(value: IslandSettings) {
    settings = normalizeSettings(value);
    if (platform.nativeAutoplayAudio && !platform.preferencesWindow) void sound.prime();
    render(); scheduleAutoHide();
  }

  function changeSettings(patch: Partial<IslandSettings>) {
    settingsWrite = settingsWrite.then(async () => {
      const next = normalizeSettings({ ...settings, ...patch });
      await platform.settingsChanged?.(next);
      settings = next;
      saveSettings(settings);
    }).catch(showError).finally(() => { render(); scheduleAutoHide(); });
    return settingsWrite;
  }

  function notify(kind: SoundEvent) {
    if (platform.preferencesWindow) return;
    if (settings.soundEnabled && settings.eventSounds[kind] && !isQuiet(settings)) {
      if (platform.notify) platform.notify(kind);
      else if (platform.nativeAutoplayAudio) void sound.prime().then(ready => { if (ready) sound.play(kind, settings.soundVolume); }).catch(showError);
      else sound.play(kind, settings.soundVolume);
    }
  }

  async function previewSound(event: SoundEvent): Promise<void> {
    if (!SOUND_EVENTS.includes(event)) throw new Error(t('未知声音事件'));
    if (platform.preferencesWindow) {
      if (!platform.previewSound) throw new Error(t('声音试听尚未连接'));
      await platform.previewSound(event); return;
    }
    if (isQuiet(settings)) throw new Error(t('当前处于勿扰时段。'));
    if (!await sound.prime() || !sound.play(event, settings.soundVolume)) throw new Error(t('音频设备尚未就绪'));
  }

  async function decide(session: Session, interaction: PendingInteraction, decision: Decision) {
    const prepared = store.prepareResponse(session.id, interaction.id, decision);
    if (!prepared) { showMessage(t('这项请求已失效，或当前无法回复。')); return; }
    try {
      await platform.respond(prepared.transportRequestId, prepared.response);
      if (store.confirmResponse(interaction.id, true)) {
        notify(decision.kind === 'question' ? 'answered' : decision.approved ? 'approved' : 'denied');
        drafts.delete(interaction.id); choices.delete(interaction.id);
        showMessage(t('已发送到 Agent'));
      }
    } catch (error) {
      store.confirmResponse(interaction.id, false, error instanceof Error ? error.message : String(error));
      showError(error);
    }
  }

  function resize(width: number, height: number) {
    const dimensions = `${width}:${height}:${expanded}`;
    if (dimensions === lastDimensions) return;
    lastDimensions = dimensions;
    if (resizeTimer) clearTimeout(resizeTimer);
    const request = () => run(() => platform.resize(width, height, expanded));
    // 收起动画完成后才缩小原生容器，避免内容被窗口边界截断。
    const policy=motionPolicy(settings,systemMotion.matches);
    if (!expanded && !policy.disabled) resizeTimer = setTimeout(request, policy.preset.finish*1000);
    else request();
  }

  function render() {
    if (disposed) return;
    if (composing) { renderAfterComposition = true; return; }
    setLanguage(settings.language);
    element.lang = locale();
    document.documentElement.lang = locale();
    const focused = document.activeElement as HTMLInputElement | HTMLTextAreaElement | null;
    const focusKey = focused?.dataset.focusKey;
    const selectionStart = focused && 'selectionStart' in focused ? focused.selectionStart : null;
    const selectionEnd = focused && 'selectionEnd' in focused ? focused.selectionEnd : null;
    const scroll = shell.querySelector<HTMLElement>('.session-scroll, .settings-content')?.scrollTop ?? 0;
    const toolbarScroll=shell.querySelector<HTMLElement>('.settings-tabs')?.scrollLeft??0;
    const previousBounds=shell.getBoundingClientRect();
    const theme = settings.theme === 'system' ? (scheme.matches ? 'dark' : 'light') : settings.theme;
    element.dataset.theme = theme;
    const policy=motionPolicy(settings,systemMotion.matches);
    element.classList.toggle('reduce-motion', !policy.continuous);
    element.classList.toggle('disable-animations', policy.disabled);
    motion.configure(settings,systemMotion.matches,expanded);
    element.classList.toggle('preview-mode', !!platform.preview);
    shell.className = `island-shell ${expanded ? 'expanded' : 'collapsed'} ${settingsPane ? 'settings-window' : ''}`;
    const count = visibleSessions().length;
    const width = settingsPane ? (platform.preferencesWindow ? Math.min(760,window.innerWidth) : 760) : expanded ? settings.panelWidth : settings.collapsedWidth;
    const regularHeight = 64 + Math.min(count * 80 + 30, 620) + (showActivity ? 140 : 0);
    const interactionHeight = pendingCount() ? Math.min(560, Math.max(360, 190 + snapshot.sessions.reduce((height, session) => height + session.pendingInteractions.reduce((sum, request) => sum + (request.kind === 'question' ? Math.min(200, request.options.length * 44) + (request.allowsCustomAnswer ? 80 : 0) : details.has(request.id) ? 240 : 120), 0), 0))) : 0;
    let height = settingsPane ? (platform.preferencesWindow ? Math.min(520,window.innerHeight) : 520) : expanded ? Math.max(count ? regularHeight : 174, interactionHeight, detailSession ? 380 : 0) : settings.collapsedHeight + (settings.showTicker ? 22 : 0);
    shell.style.width = `${width}px`; shell.style.height = `${height}px`;
    shell.style.setProperty('--pill-height', `${settings.collapsedHeight}px`);
    if (settingsPane) shell.replaceChildren(settingsHeader(), settingsToolbar(), settingsContent());
    else if (expanded) shell.replaceChildren(expandedHeader(), expandedBody());
    else shell.replaceChildren(collapsedBody());
    // 待办按钮和筛选后的空结果应留在首屏；长列表仍使用滚动区。
    if (expanded && !settingsPane && (pendingCount() || showFilter)) {
      const list = shell.querySelector<HTMLElement>('.session-scroll');
      if (list) {
        height = Math.min(620, Math.max(height, 48 + 24 + list.scrollHeight + 16 + (showFilter ? 70 : 0) + (showActivity ? 140 : 0)));
        shell.style.height = `${height}px`;
      }
    }
    shell.querySelector<HTMLElement>('.session-scroll, .settings-content')?.scrollTo({ top: scroll });
    const toolbar=shell.querySelector<HTMLElement>('.settings-tabs');
    if(toolbar){toolbar.scrollLeft=toolbarScroll;toolbar.querySelector<HTMLElement>('[aria-current="page"]')?.scrollIntoView({block:'nearest',inline:'nearest'});}
    if (focusKey) {
      const next = Array.from(shell.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>('[data-focus-key]')).find(node => node.dataset.focusKey === focusKey);
      next?.focus({ preventScroll: true });
      if (next && selectionStart !== null && selectionEnd !== null && ['text', 'search', 'textarea'].includes(next.type)) {
        next.setSelectionRange(selectionStart, selectionEnd);
      }
    }
    resize(width, height);
    motion.resize(previousBounds,width,height,expanded);
    if (message) { toast.textContent = message; toast.classList.add('visible'); }
  }

  function collapsedBody(): HTMLElement {
    const body = el('div', 'collapsed-body');
    const pill = button(t('展开 XIsland'), 'collapsed-button', expand);
    pill.replaceChildren();
    const icons = el('span', 'collapsed-agents');
    const sessions = visibleSessions();
    for (const session of sessions.slice(0, 5)) icons.append(mascot(session.agentType, session.status, 22));
    if (sessions.length > 5) icons.append(el('span', 'overflow-count', `+${sessions.length - 5}`));
    if (!sessions.length) {
      icons.append(mascot('codex', 'idle', 22), el('span', 'empty-pill-label', 'X Island'));
    }
    pill.append(icons);
    const active = sessions.filter(session => LIVE.has(session.status)).length;
    const totalMode = Math.floor(Date.now() / 5000) % 2 === 1;
    const count = el('span', 'collapsed-count');
    count.append(el('b', '', String(totalMode ? snapshot.sessions.length : active)), el('span', '', totalMode ? t('全部') : t('活跃')));
    pill.append(count);
    if (isQuiet(settings)) pill.append(icon('moon'));
    if (pendingCount()) { const dot = el('span', 'attention-dot'); dot.setAttribute('aria-label', t('{count} 项待处理', {count:pendingCount()})); pill.append(dot); }
    body.append(pill);
    if (settings.showTicker) {
      const latest = [...sessions].sort((a,b) => b.lastActivityAt - a.lastActivityAt)[0];
      const ticker = el('div', 'ticker');
      const text = latest ? `${workspace(latest)} · ${latest.currentTool || latest.statusText || statusLabel(latest.status)}` : t('等待 Agent 会话');
      ticker.append(el('span', 'ticker-text', text));
      body.append(ticker);
      requestAnimationFrame(() => {
        const child = ticker.firstElementChild as HTMLElement;
        if (child && child.scrollWidth > ticker.clientWidth + 4) {
          child.style.setProperty('--travel', `${-(child.scrollWidth - ticker.clientWidth + 16)}px`);
          child.style.animationDuration = `${(child.scrollWidth - ticker.clientWidth + 16) / 25 + 1.2}s`;
          child.classList.add('scrolling');
        }
      });
    }
    return body;
  }

  function expandedHeader(): HTMLElement {
    const header = el('header', 'island-header');
    header.append(button(settings.soundEnabled ? t('静音') : t('开启声音'), 'icon-button', () => { void changeSettings({ soundEnabled: !settings.soundEnabled }); }, settings.soundEnabled ? 'sound' : 'mute'));
    header.append(button(t('设置'), 'icon-button', () => showSettings(), 'settings'));
    if (platform.switchIsland) {
      const peerButton = button('切换到 XNook', 'text-button island-peer-button', () => { void switchIsland(); });
      peerButton.textContent = switchingIsland ? '切换中…' : 'XNook →';
      peerButton.title = '切换到 XNook（也可在标题区横向滚动）';
      peerButton.disabled = switchingIsland;
      header.append(peerButton);
    }
    const count = visibleSessions().filter(session => LIVE.has(session.status)).length;
    header.append(el('span', 'header-spacer'));
    if (platform.preview) header.append(el('span', 'preview-tag', t('样例预览')));
    header.append(el('span', 'header-count', pendingCount() ? t('{count} 项待处理',{count:pendingCount()}) : t('{count} 个活跃会话',{count})));
    if (pendingCount()) header.append(button(overview ? t('待办') : t('总览'), 'overview-button', () => { overview = !overview; render(); }));
    header.append(button(t('收起'), 'icon-button close-button', collapse, 'close'));
    return header;
  }

  function expandedBody(): HTMLElement {
    const body = el('div', 'expanded-body');
    if (detailSession) {
      const session = snapshot.sessions.find(item => item.id === detailSession);
      if (session) { body.append(sessionDetail(session)); return body; }
      detailSession = undefined;
    }
    const top = el('div', 'list-toolbar');
    top.append(button(t('会话历史'), 'icon-button small', () => showSettings('history'), 'history'));
    top.append(button(showActivity ? t('收起活动记录') : t('展开活动记录'), `icon-button small ${showActivity ? 'selected' : ''}`, () => { showActivity = !showActivity; render(); }, 'terminal'));
    top.append(el('span', 'header-spacer'));
    top.append(button(t('搜索与筛选'), `icon-button small ${showFilter ? 'selected' : ''}`, () => { showFilter = !showFilter; render(); if (showFilter) shell.querySelector<HTMLInputElement>('.search-input')?.focus(); }, 'filter'));
    body.append(top);
    if (showFilter) body.append(filterBar());
    const list = el('div', 'session-scroll');
    list.setAttribute('aria-label', t('会话列表'));
    if (!pendingCount() || overview) list.append(agentFlow());
    const sessions = visibleSessions();
    const matches = (session: Session) => matchesSessionFilters(session, { agent: agentFilter, status: filter, query },
      `${title(session)} ${session.workingDirectory} ${agentName(session.agentType)} ${session.statusText}`);
    const filtered = sessions.filter(matches);
    const tree = buildFilteredSessionTree(filtered);
    for (const session of tree.pending) list.append(pendingCard(session));
    for (const node of tree.roots) list.append(sessionCard(node));
    const filtering = !!sessions.length || agentFilter !== 'all' || filter !== 'all' || !!query;
    if (!filtered.length) list.append(emptyState(filtering ? t('没有匹配的会话') : t('Agent 开始工作时，会话会出现在这里。'), filtering ? t('试试其他关键词或筛选条件。') : t('从已配置 XIsland 的终端开始一段任务。')));
    body.append(list);
    if (showActivity) body.append(activityPanel());
    return body;
  }

  function filterBar(): HTMLElement {
    const container = el('div', 'filter-bar');
    const search = el('input', 'search-input'); search.type = 'search'; search.placeholder = t('搜索会话、项目、Agent 或模型'); search.value = query; search.dataset.focusKey = 'search'; search.setAttribute('aria-label', search.placeholder);
    search.addEventListener('input', () => { query = search.value; render(); });
    const row = el('div', 'filter-selects');
    row.append(select(t('会话状态'), [['all',t('全部状态')], ['pending',t('待处理')], ['active',t('运行中')], ['idle',t('空闲')], ['error',t('错误')]], filter, value => { filter = value; render(); }));
    const agents = [...new Set(snapshot.sessions.map(session => session.agentType))];
    const agentOptions: Array<[string,string]> = [['all',t('全部 Agent')], ...agents.map(type => [type,agentName(type)] as [string,string])];
    if (agentFilter === GLM_MODEL_FILTER || visibleSessions().some(session => isGLMModel(session.usage.model))) agentOptions.push([GLM_MODEL_FILTER,t('GLM 模型')]);
    row.append(select(t('Agent 或模型'), agentOptions, agentFilter, value => { agentFilter = value; render(); }));
    container.append(search,row); return container;
  }

  function agentFlow(): HTMLElement {
    const flow = el('section','agent-flow');
    const heading = el('div','flow-heading'); heading.append(icon('flow'),el('strong','', 'Agent Flow'));
    if (pendingCount()) heading.append(badge(String(pendingCount()), 'var(--orange)'));
    flow.append(heading);
    const projects = new Map<string, Session[]>();
    for (const session of snapshot.sessions.filter(item => item.pendingInteractions.length || item.status === 'error')) {
      const path = session.workingDirectory || t('未指定项目'); projects.set(path,[...(projects.get(path) ?? []),session]);
    }
    if (!projects.size) { const clear = el('div','flow-clear'); clear.append(icon('check'),el('span','', t('没有等待处理的项目'))); flow.append(clear); }
    for (const [path,sessions] of projects) {
      const row = button(`${path} · ${t('{count} 个会话需要关注',{count:sessions.length})}`,'flow-project',() => {
        if (projectGroups.has(path)) projectGroups.delete(path); else projectGroups.add(path); render();
      });
      row.replaceChildren();
      row.append(el('span','flow-project-name',path.split(/[\\/]/).filter(Boolean).at(-1) || path),badge(t('{count} 待处理',{count:sessions.length}),'var(--orange)'),icon('chevron')); flow.append(row);
      if (projectGroups.has(path)) for (const session of sessions) {
        const detail = el('div', 'flow-session');
        const focus = button(title(session), 'flow-session-focus', () => {
          store.select(session.id);
          shell.querySelector<HTMLElement>(`[data-session-id="${CSS.escape(session.id)}"]`)?.scrollIntoView({ block: 'nearest', behavior: settings.reduceMotion ? 'instant' : 'smooth' });
        });
        detail.append(mascot(session.agentType, session.status, 20), focus, button(t('打开 Agent'), 'icon-button small', () => run(() => platform.jump(session)), 'jump'));
        flow.append(detail);
      }
    }
    return flow;
  }

  function sessionCard(node: SessionTreeNode, child=false): HTMLElement {
    const { session, children } = node;
    const card=el('article',`session-card ${child ? 'child-card' : ''}`); card.dataset.sessionId=session.id;
    card.style.setProperty('--agent',agentColor(session.agentType));
    const target=button(t('打开 {title}',{title:title(session)}),'session-main',()=>run(()=>platform.jump(session)));
    target.replaceChildren();
    const header=el('div','session-header'); header.append(mascot(session.agentType,session.status));
    const dot=el('span','status-dot'); dot.style.background=statusColor(session.status); dot.title=statusLabel(session.status); header.append(dot);
    const labels=el('div','session-labels'); labels.append(el('strong','session-title',title(session)),el('span','workspace',workspace(session)||statusLabel(session.status))); if(session.usage.model)labels.append(modelLabel(session.usage.model)); header.append(labels);
    header.append(badge(agentName(session.agentType),agentColor(session.agentType)),badge(duration(session))); target.append(header);
    if(session.agentResponse) target.append(el('p','session-response',session.agentResponse));
    if(session.currentTool){const tool=el('div','current-tool');tool.append(el('span','spinner'),el('span','',session.currentTool));target.append(tool);}
    const activities=displayedEvents(session);if(activities.length){const event=activities.at(-1)!;const line=el('div','last-event');const outcome=toolOutcome(event);const glyph=icon(outcome.icon);glyph.style.color=outcome.color;line.append(glyph,el('span','',`${event.tool}${event.input ? ` · ${event.input}` : ''}`));target.append(line);}
    card.append(target);
    const footer=el('div','session-footer');footer.append(el('span','session-state',statusLabel(session.status)));
    footer.append(button(t('查看活动与对话'),'text-button',()=>{detailSession=session.id;store.select(session.id);render();}));
    card.append(footer);
    if(children.length){card.append(button(t('{action} {count} 个子 Agent',{action:childGroups.has(session.id)?t('收起'):t('展开'),count:children.length}),'children-toggle',()=>{if(childGroups.has(session.id))childGroups.delete(session.id);else childGroups.add(session.id);render();}));if(childGroups.has(session.id))for(const item of children)card.append(sessionCard(item,true));}
    return card;
  }

  function pendingCard(session:Session):HTMLElement {
    const card=el('article','pending-card');card.dataset.sessionId=session.id;
    const header=el('div','pending-header'); header.append(mascot(session.agentType,session.status,20));
    const text=el('div','session-labels');text.append(el('strong','pending-title',title(session)),el('span','workspace',session.workingDirectory||agentName(session.agentType)));header.append(text,button(t('打开 Agent'),'icon-button',()=>run(()=>platform.jump(session)),'jump'));card.append(header);
    for(const request of session.pendingInteractions)card.append(interactionView(session,request));
    return card;
  }

  function interactionView(session:Session, request:PendingInteraction):HTMLElement {
    const view=el('section',`interaction interaction-${request.kind}`);view.dataset.requestId=request.id;
    const heading=el('h3','request-heading');heading.append(icon(request.kind==='permission'?'warning':request.kind==='question'?'question':'plan'),document.createTextNode(request.kind==='permission'?t('权限请求'):request.kind==='question'?t('等待回答'):t('计划审核')));view.append(heading);
    const sending=request.phase==='sending';
    if(request.kind==='permission'){
      view.append(el('strong','request-tool',request.tool||t('操作授权')));
      const well=el('div',`request-details ${details.has(request.id)?'open':''}`);
      if(request.description)well.append(el('pre','',request.description));
      if(request.filePath)well.append(el('code','request-path',request.filePath));
      if(request.diff){if(details.has(request.id))well.append(diffView(request.diff));else well.append(el('span','muted',t('包含文件变更')));}
      view.append(well,button(details.has(request.id)?t('收起详情'):t('查看权限详情'),'text-button details-button',()=>toggleDetails(request.id)));
      const actions=el('div','decision-row');actions.append(decisionButton(t('拒绝'),'deny',sending,()=>{void decide(session,request,{kind:'permission',approved:false});}),decisionButton(t('允许'),'allow',sending,()=>{void decide(session,request,{kind:'permission',approved:true});}));view.append(actions);
    }else if(request.kind==='question'){
      view.append(el('p','question-text',request.text||t('问题内容不可用，请回到 Agent 查看。')));
      const options=el('div','question-options');
      if(request.allowsMultipleAnswers){
        const selected=choices.get(request.id)??new Set<string>(); choices.set(request.id,selected);
        for(const [index,value]of request.options.entries()){
          const row=el('label','question-option multi-option');const checkbox=el('input');checkbox.type='checkbox';checkbox.checked=selected.has(value);checkbox.disabled=sending;checkbox.dataset.focusKey=`${request.id}:option:${index}`;
          checkbox.addEventListener('change',()=>{if(checkbox.checked)selected.add(value);else selected.delete(value);render();});row.append(checkbox,el('span','',value));options.append(row);
        }
      }else for(const [index,value]of request.options.entries()){
        const option=button(value,'question-option',()=>{void decide(session,request,{kind:'question',answer:value});});option.disabled=sending;option.replaceChildren(el('span','option-number',String(index+1)),el('span','',value));options.append(option);
      }
      view.append(options);
      if(request.allowsCustomAnswer){const input=el('textarea','answer-input');input.placeholder=t('输入你的回答…');input.rows=2;input.value=drafts.get(request.id)??'';input.disabled=sending;input.dataset.focusKey=request.id;input.setAttribute('aria-label',t('自定义回答'));input.addEventListener('input',()=>{drafts.set(request.id,input.value);const send=view.querySelector<HTMLButtonElement>('.send-answer');if(send)send.disabled=sending||(!(choices.get(request.id)?.size)&&!input.value.trim());});view.append(input);}
      if(request.allowsMultipleAnswers||request.allowsCustomAnswer){
        const send=decisionButton(t('发送回答'),'allow send-answer',sending,()=>{
          const custom=drafts.get(request.id)?.trim()??'';
          if(request.allowsMultipleAnswers){const values=[...(choices.get(request.id)??[]),...(custom?[custom]:[])];if(values.length)void decide(session,request,{kind:'question',selectedAnswers:values});}
          else if(custom)void decide(session,request,{kind:'question',answer:custom});
        });send.disabled=sending||(!(choices.get(request.id)?.size)&&!(drafts.get(request.id)?.trim()));view.append(send);
      }
      if(!request.options.length&&!request.allowsCustomAnswer)view.append(button(t('打开 Agent'),'text-button',()=>run(()=>platform.jump(session))));
    }else{
      const content=el('div',`plan-markdown ${details.has(request.id)?'open':''}`);content.append(markdown(request.markdown||t('尚无计划内容。')));view.append(content,button(details.has(request.id)?t('收起计划'):t('查看完整计划'),'text-button details-button',()=>toggleDetails(request.id)));
      const feedback=el('textarea','answer-input');feedback.placeholder=t('可填写反馈或修改意见');feedback.rows=2;feedback.value=drafts.get(request.id)??'';feedback.dataset.focusKey=request.id;feedback.disabled=sending;feedback.setAttribute('aria-label',t('计划反馈'));feedback.addEventListener('input',()=>drafts.set(request.id,feedback.value));view.append(feedback);
      const actions=el('div','decision-row');for(const [approved,label]of [[false,t('需要修改')],[true,t('批准计划')]]as const)actions.append(decisionButton(label,approved?'allow':'deny',sending,()=>{void decide(session,request,{kind:'plan',approved,feedback:drafts.get(request.id)?.trim()||undefined});}));view.append(actions);
    }
    if(sending){const status=el('div','delivery-status');status.append(el('span','spinner'),el('span','',t('正在发送…')));status.setAttribute('role','status');view.append(status);}
    if(request.phase==='failed'){const status=el('div','delivery-status failed',request.error||t('发送失败，请重试或回到 Agent 处理。'));status.setAttribute('role','alert');view.append(status,button(t('打开 Agent'),'text-button',()=>run(()=>platform.jump(session))));}
    return view;
  }

  function decisionButton(label:string,className:string,disabled:boolean,action:()=>void){const node=button(label,`decision-button ${className}`,action);node.disabled=disabled;return node;}
  function toggleDetails(id:string){if(details.has(id))details.delete(id);else details.add(id);render();}
  function diffView(diff:string):HTMLElement{const pre=el('pre','diff');for(const line of diff.split('\n'))pre.append(el('span',line.startsWith('+')?'added':line.startsWith('-')?'removed':'',`${line}\n`));return pre;}

  function activityPanel():HTMLElement{
    const panel=el('section','activity-panel');panel.append(el('h3','',t('最近活动')));
    const entries=snapshot.sessions.flatMap(session=>displayedEvents(session).map(event=>({session,event}))).sort((a,b)=>b.event.timestamp-a.event.timestamp).slice(0,20);
    const list=el('div','activity-list');for(const {session,event}of entries){const row=el('div','activity-row');const outcome=toolOutcome(event),mark=el('span','tool-outcome',outcome.symbol);mark.style.color=outcome.color;row.append(el('span','activity-time',time(event.timestamp)),el('span','activity-agent',agentName(session.agentType)),el('span','activity-tool',event.tool),mark);list.append(row);}if(!entries.length)list.append(el('p','muted',t('尚无工具活动')));panel.append(list);return panel;
  }

  function sessionDetail(session:Session):HTMLElement{
    const detail=el('section','session-detail');const bar=el('div','detail-toolbar');bar.append(button(t('返回会话列表'),'text-button',()=>{detailSession=undefined;render();}),button(t('打开 Agent'),'icon-button',()=>run(()=>platform.jump(session)),'jump'));detail.append(bar);
    const heading=el('div','detail-heading'),labels=el('div','session-labels');labels.append(el('strong','',title(session)));if(session.usage.model)labels.append(modelLabel(session.usage.model));heading.append(mascot(session.agentType,session.status),labels);detail.append(heading);
    const list=el('div','session-scroll chat-history');
    if(session.chatHistory.length)for(const entry of session.chatHistory){const bubble=el('article',`chat-entry ${entry.role}`);bubble.append(el('div','chat-meta',`${entry.role==='user'?t('你'):entry.role==='system'?t('系统'):agentName(session.agentType)} · ${time(entry.timestamp)}`),markdown(entry.content));list.append(bubble);}
    else if(session.agentResponse)list.append(markdown(session.agentResponse));
    else list.append(emptyState(t('暂无对话内容'),t('工具活动仍会显示在下方。')));
    for(const event of displayedEvents(session)){const row=el('details','event-detail');const outcome=toolOutcome(event);const summary=el('summary','',`${time(event.timestamp)} · ${event.tool} ${outcome.symbol}`);row.append(summary);if(event.input)row.append(el('pre','',event.input));if(event.result)row.append(el('pre','',event.result));list.append(row);}
    detail.append(list);return detail;
  }

  function closeSettings() { if (platform.preferencesWindow) run(() => platform.closeSettings?.() ?? Promise.resolve()); else { settingsPane=undefined;render();scheduleAutoHide(); } }
  function settingsHeader():HTMLElement{const header=el('header','settings-heading');header.append(el('strong','',t('X Island 设置')),el('span','header-spacer'));if(platform.preview)header.append(el('span','preview-tag',t('样例预览')));header.append(button(t(platform.preferencesWindow?'关闭设置':'返回灵动岛'),'icon-button',closeSettings,'close'));return header;}
  function settingsToolbar():HTMLElement{const bar=el('nav','settings-tabs');bar.setAttribute('aria-label',t('设置分类'));for(const [id,label,glyph]of PANES){const tab=button(t(label),`settings-tab ${settingsPane===id?'selected':''}`,()=>{settingsPane=id;detailSession=undefined;shell.querySelector<HTMLElement>('.settings-content')?.scrollTo({top:0});render();});tab.replaceChildren(icon(glyph),el('span','',t(label)));tab.setAttribute('aria-current',settingsPane===id?'page':'false');bar.append(tab);}return bar;}

  function settingsContent():HTMLElement{
    const content=el('div','settings-content');
    if (detailSession && platform.preferencesWindow) { const session=snapshot.sessions.find(item=>item.id===detailSession);if(session){content.append(sessionDetail(session));return content;}detailSession=undefined; }
    if(settingsPane==='general'){
      if(platform.getIslandPreferences)content.append(sectionTitle(locale().startsWith('zh')?'与 XNook 联动':'XNook integration'),linkPreferencesCard());
      content.append(sectionTitle(t('语言')), settingCard(selectRow(t('语言'),t('界面语言立即生效，Agent 原文保持不变。'),'language',[
        ['system',t('跟随系统')],['zh','简体中文'],['en','English'],['ja','日本語'],['ko','한국어'],['fr','Français'],
      ])));
      content.append(sectionTitle(t('窗口与交互')),settingCard(
        toggleRow(t('悬停展开'),t('默认点击展开；启用后指针停留会展开。'),'hoverToExpand'),
        toggleRow(t('跟随鼠标显示器'),t('待处理请求期间固定在当前显示器。'),'followPointer'),
        toggleRow(t('全屏时隐藏'),t('仅影响原生 Windows 窗口。'),'hideInFullscreen'),
        numberRow(t('无操作自动收起'),t('秒；0 表示保持展开。'),'autoHideSeconds',0,300),
      ),sectionTitle(t('数据')),settingCard(actionRow(t('导出本地会话'),t('包含当前保存的会话、工具活动和对话。'),t('导出 JSON'),()=>exportAll())));
    }else if(settingsPane==='display'){
      const theme=el('div','theme-options');for(const [value,label,glyph]of [['dark',t('深色'),'moon'],['light',t('浅色'),'sun'],['system',t('跟随系统'),'screen']]as const){const choice=button(label,`theme-option ${settings.theme===value?'selected':''}`,()=>{void changeSettings({theme:value});});choice.replaceChildren(icon(glyph),el('span','',label));theme.append(choice);}
      content.append(sectionTitle(t('外观')),theme,sectionTitle(t('灵动岛')),settingCard(toggleRow(t('收起活动文字'),t('在图标下显示最近活动。'),'showTicker'),toggleRow(t('减少动态效果'),t('关闭脉冲、滚动和弹性动效。'),'reduceMotion'),numberRow(t('收起宽度'),t('逻辑像素'),'collapsedWidth',200,400),numberRow(t('收起主条高度'),t('活动文字开启时额外增加 22。'),'collapsedHeight',30,60),numberRow(t('展开宽度'),t('逻辑像素'),'panelWidth',320,520)));
      content.append(sectionTitle(t('动画')),settingCard(
        selectRow(t('动画强度'),t('展开和收起的弹簧与淡入速度。'),'animationIntensity',[['low',t('低')],['medium',t('中')],['high',t('高')]]),
        selectRow(t('果冻强度'),t('从下方向上进入收起条时轻轻回弹。'),'jellyIntensity',[['weak',t('弱')],['medium',t('中')],['strong',t('强')]]),
        toggleRow(t('关闭所有动画'),t('立即切换状态；数字和会话仍正常更新。'),'disableAnimations'),
      ));
    }else if(settingsPane==='sound'){
      const volume=el('label','setting-row');volume.append(rowLabel(t('音量'),`${Math.round(settings.soundVolume*100)}%`));
      const slider=el('input','sound-volume');slider.type='range';slider.min='0';slider.max='1';slider.step='0.05';slider.value=String(settings.soundVolume);slider.setAttribute('aria-label',t('音量'));
      slider.addEventListener('change',()=>{void changeSettings({soundVolume:Number(slider.value)});});volume.append(slider);
      content.append(sectionTitle(t('提示音')),settingCard(toggleRow(t('播放提示音'),t('授权、问答、完成和错误使用不同短音。'),'soundEnabled'),volume),sectionTitle(t('声音事件')));
      for(const event of SOUND_EVENTS){
        const row=el('div','setting-row');row.append(rowLabel(t(SOUND_LABELS[event]),''));
        const enabled=el('input','switch');enabled.type='checkbox';enabled.checked=settings.eventSounds[event];enabled.setAttribute('aria-label',t(SOUND_LABELS[event]));
        enabled.addEventListener('change',()=>{void changeSettings({eventSounds:{...settings.eventSounds,[event]:enabled.checked}});});
        const preview=button(t('试听 {event}',{event:t(SOUND_LABELS[event])}),'icon-button',()=>run(()=>previewSound(event)),'sound');
        preview.disabled=!!platform.preferencesWindow&&!platform.previewSound;row.append(enabled,preview);content.append(row);
      }
      content.append(sectionTitle(t('勿扰时段')),settingCard(toggleRow(t('定时勿扰'),t('此时段保留视觉提醒，停止提示音。'),'quietHours'),timeRow(t('开始时间'),'quietStart'),timeRow(t('结束时间'),'quietEnd')));
      content.append(el('p','settings-note',isQuiet(settings)?t('当前处于勿扰时段。'):t('当前不在勿扰时段。')));
    }else if(settingsPane==='history'){
      content.append(sectionTitle(t('会话历史')));
      const history=snapshot.sessions.filter(session=>isArchivedSession(session)||session.status==='completionUnconfirmed').sort(compareHistorySessions);
      if(!history.length)content.append(emptyState(t('暂无历史记录'),t('已结束或观测中断的会话会显示在这里。')));
      for(const session of history){const row=el('div','history-row');const labels=el('div','session-labels');labels.append(el('strong','',title(session)),el('span','muted',`${agentName(session.agentType)} · ${duration(session)} · ${statusLabel(session.status)}`));const date=new Date(historyDate(session)),dateLabel=session.completedAt!==undefined?t('已完成于'):session.observationEndedAt!==undefined?t('观测中断于'):t('开始于');const timestamp=el('time','history-date',`${dateLabel} ${date.toLocaleString(locale(),{year:'numeric',month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'})}`);timestamp.dateTime=date.toISOString();labels.append(timestamp);row.append(labels,button(t('查看记录'),'text-button',()=>{if(!platform.preferencesWindow)settingsPane=undefined;detailSession=session.id;expanded=true;render();}),button(t('导出此会话'),'icon-button',()=>run(()=>platform.exportHistory(JSON.stringify({version:1,sessions:[session]},null,2))),'download'));if(isArchivedSession(session)&&!session.pendingInteractions.length)row.append(button(t('删除此记录'),'icon-button danger',()=>{if(confirm(t('删除这条本地会话记录？'))){if(platform.deleteHistory)run(()=>platform.deleteHistory!(session.id));else store.dismiss(session.id);}},'trash'));content.append(row);}
      if(history.length)content.append(actionRow(t('导出记录'),t('导出当前所有会话，可用于备份与排查。'),t('导出 JSON'),exportAll));
      if(history.some(session=>isArchivedSession(session)&&!session.pendingInteractions.length))content.append(actionRow(t('清空已归档记录'),t('仅删除已完成或观测中断且没有待办的本地记录。'),t('清空历史'),()=>{
        if(confirm(t('清空所有已归档记录？'))){if(platform.clearHistory)run(()=>platform.clearHistory!());else store.clearHistory();}
      }));
    }else if(settingsPane==='statistics'){
      content.append(sectionTitle(t('本地会话统计')));
      const summaries=aggregateHistoryUsage(snapshot.sessions);
      const totals=summaries.reduce((sum,session)=>({input:sum.input+session.inputTokens,output:sum.output+session.outputTokens,total:sum.total+session.totalTokens,cost:sum.cost+session.costUSD,duration:sum.duration+session.durationMs}),{input:0,output:0,total:0,cost:0,duration:0});
      const grid=el('div','stats-grid');for(const [label,value]of [[t('会话'),String(summaries.length)],[t('活跃'),String(summaries.filter(session=>session.active).length)],[t('输入 token'),formatNumber(totals.input)],[t('输出 token'),formatNumber(totals.output)],[t('总 token'),formatNumber(totals.total)],[t('已上报费用'),`$${totals.cost.toFixed(4)}`],[t('总时长'),durationText(totals.duration)]]){const item=el('div','stat-card');item.append(el('strong','',value),el('span','muted',label));grid.append(item);}content.append(grid,el('p','settings-note',t('统计来自 Agent 已上报事件。未上报用量不代表真实用量为零；这里不显示推算的额度或余额。')));
    }else if(settingsPane==='agents'){
      content.append(integrations.view());
      if(integrations.isReviewing)return content;
      content.append(sectionTitle(t('已观测到的 Agent')));
      const agents=[...new Set(snapshot.sessions.map(session=>session.agentType))];if(!agents.length)content.append(emptyState(t('等待 Agent 连接'),t('每种工具需通过对应的 XIsland 适配器发送事件。')));
      for(const type of agents){const sessions=snapshot.sessions.filter(session=>session.agentType===type);const row=el('div','agent-setting-row');row.append(mascot(type,'idle'),el('strong','',agentName(type)),el('span','header-spacer'),badge(t('{count} 个会话',{count:sessions.length})));content.append(row);}
      content.append(el('p','settings-note',t('出现在列表中表示收到过该工具的事件，不代表已验证其全部原生客户端能力。')));
    }else if(settingsPane==='integration'){
      content.append(sectionTitle(t('本地桥接')),settingCard(infoRow(t('连接方式'),t('Agent → XIsland bridge → 当前用户的本地管道 → 灵动岛')),infoRow(t('审批回传'),t('只有本地连接实际接收响应后，才从界面移除待办。')),infoRow(t('失效与断连'),t('过期或断开的请求回到 Agent 处理；不会自动批准。'))));
      content.append(sectionTitle(t('当前状态')),el('p','settings-note',platform.preview?t('当前是浏览器样例预览。所有样例审批只用于界面演示，不控制真实 Agent。'):t('原生客户端已加载。请使用项目提供的桥接与配置流程接入 Agent；本页不自动修改工具配置。')));
    }else{
      const about=el('div','about');about.append(mascot('codex','idle',52),el('h2','','X Island'),el('p','muted',t('Windows 客户端')),el('p','',t('让正在工作、需要回答和已完成的 Agent 留在屏幕顶部。')));content.append(about,settingCard(infoRow(t('界面基准'),t('按照当前 macOS XIsland 的色彩、尺寸和交互重建。')),infoRow(t('运行状态'),platform.preview?t('浏览器样例预览；不代表 Windows 原生验收通过。'):t('Windows 原生能力需在实际系统与 Agent 上分别验收。'))));
    }
    return content;
  }

  function sectionTitle(text:string){return el('h2','settings-section-title',text);}
  function settingCard(...rows:HTMLElement[]){const card=el('section','setting-card');card.append(...rows);return card;}
  function rowLabel(label:string,description:string){const labels=el('div','setting-label');labels.append(el('strong','',label),el('span','',description));return labels;}
  function toggleRow(label:string,description:string,key:'soundEnabled'|'quietHours'|'hoverToExpand'|'followPointer'|'hideInFullscreen'|'showTicker'|'reduceMotion'|'disableAnimations'){
    const row=el('label','setting-row');const unavailable=(key==='followPointer'&&!platform.capabilities?.monitorFollowing)||(key==='hideInFullscreen'&&!platform.capabilities?.fullscreenHiding);row.append(rowLabel(label,unavailable?`${description} ${t('当前版本尚未接入。')}`:description));const input=el('input','switch');input.type='checkbox';input.checked=settings[key];input.disabled=unavailable;input.setAttribute('aria-label',label);input.addEventListener('change',()=>{void changeSettings({[key]:input.checked});});row.append(input);return row;
  }
  function numberRow(label:string,description:string,key:'autoHideSeconds'|'collapsedWidth'|'collapsedHeight'|'panelWidth',min:number,max:number){const row=el('label','setting-row');row.append(rowLabel(label,description));const input=el('input','number-input');input.type='number';input.min=String(min);input.max=String(max);input.step=key==='collapsedWidth'||key==='collapsedHeight'?'0.01':'1';input.value=String(settings[key]);input.setAttribute('aria-label',label);input.addEventListener('change',()=>{const value=Number(input.value);if(!Number.isFinite(value)||value<min||value>max){input.value=String(settings[key]);showMessage(t('请输入 {min} 到 {max} 之间的数值',{min,max}));return;}void changeSettings({[key]:value});});row.append(input);return row;}
  function selectRow(label:string,description:string,key:'language'|'animationIntensity'|'jellyIntensity',options:Array<[string,string]>) { const row=el('label','setting-row');row.append(rowLabel(label,description),select(label,options,settings[key],value=>{void changeSettings({[key]:value});}));return row; }
  function timeRow(label:string,key:'quietStart'|'quietEnd'){const row=el('label','setting-row');row.append(rowLabel(label,''));const input=el('input','time-input');input.type='time';input.value=settings[key];input.setAttribute('aria-label',label);input.addEventListener('change',()=>{if(/^([01]\d|2[0-3]):[0-5]\d$/.test(input.value))void changeSettings({[key]:input.value});});row.append(input);return row;}
  function actionRow(label:string,description:string,actionLabel:string,action:()=>void){const row=el('div','setting-row');row.append(rowLabel(label,description),button(actionLabel,'settings-action',action));return row;}
  function infoRow(label:string,description:string){const row=el('div','setting-row');row.append(rowLabel(label,description));return row;}
  function select(label:string,options:Array<[string,string]>,selected:string,onChange:(value:string)=>void){const input=el('select');input.setAttribute('aria-label',label);for(const[value,text]of options){const option=el('option','',text);option.value=value;option.selected=value===selected;input.append(option);}input.addEventListener('change',()=>onChange(input.value));return input;}
  function emptyState(title:string,description:string){const state=el('div','empty-state');state.append(icon('terminal'),el('strong','',title),el('p','',description));return state;}
  function exportAll(){run(()=>platform.exportHistory(store.serialize()));}

  function onSnapshot(next:StoreSnapshot){
    const previousPending = pendingCount();
    snapshot=next;
    let hasNewRequest=false;
    for(const session of next.sessions){
      const previous=previousStatuses.get(session.id);
      if(previous&&previous!==session.status){if(session.status==='error')notify('error');else if(session.status==='compacting')notify('context_compacting');}
      const userMessage=session.chatHistory.filter(message=>message.role==='user').at(-1)?.id;
      if(userMessage&&previousUserMessages.get(session.id)!==userMessage&&LIVE.has(session.status))notify('session_start');
      previousUserMessages.set(session.id,userMessage);
      for(const event of session.events){if(!seenToolEvents.has(event.id)){seenToolEvents.add(event.id);if(!event.isComplete&&!event.completionUnconfirmed&&LIVE.has(session.status))notify('tool_start');}}
      previousStatuses.set(session.id,session.status);
      for(const request of session.pendingInteractions)if(!seenRequests.has(request.id)){seenRequests.add(request.id);hasNewRequest=true;notify(request.kind==='question'?'question':request.kind==='plan'?'plan_review':'permission_request');}
    }
    if(hasNewRequest&&!settingsPane){expanded=true;overview=false;}
    render();
    if (pendingCount() || previousPending > 0) scheduleAutoHide();
  }

  const unsubscribe=store.subscribe(onSnapshot);
  const unsubscribeCompletion=store.subscribeCompletion(()=>notify('session_end'));
  const onPointerDown=(event:PointerEvent)=>{if(!platform.preferencesWindow)void sound.prime();scheduleAutoHide();if(event.target instanceof HTMLInputElement||event.target instanceof HTMLTextAreaElement||event.target instanceof HTMLSelectElement)run(()=>platform.focus());};
  let previousPointerY=Number.POSITIVE_INFINITY;
  const onPointerMove=(event:PointerEvent)=>{motion.pointer(event.clientX,event.clientY,settings.collapsedHeight);previousPointerY=event.clientY;};
  const onPointerEnter=(event:PointerEvent)=>{if(hoverExit)clearTimeout(hoverExit);motion.enter(settings.jellyIntensity,previousPointerY>event.clientY);if(settings.hoverToExpand&&!expanded&&visibleSessions().length)expand();};
  const onPointerLeave=()=>{motion.resetHover();if(settings.hoverToExpand&&expanded&&!settingsPane&&!pendingCount())hoverExit=setTimeout(collapse,500);};
  const onFocus=(event:FocusEvent)=>{if(event.target instanceof HTMLInputElement||event.target instanceof HTMLTextAreaElement||event.target instanceof HTMLSelectElement)run(()=>platform.focus());};
  const onCompositionStart=()=>{composing=true;};
  const onCompositionEnd=()=>{composing=false;if(renderAfterComposition){renderAfterComposition=false;setTimeout(render,0);}};
  const onKey=(event:KeyboardEvent)=>{
    scheduleAutoHide();
    if(event.key==='Escape'){event.preventDefault();if(detailSession){detailSession=undefined;render();}else if(settingsPane)closeSettings();else collapse();return;}
    if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='f'&&!platform.preferencesWindow){event.preventDefault();expanded=true;settingsPane=undefined;showFilter=true;render();shell.querySelector<HTMLInputElement>('.search-input')?.focus();return;}
    if(event.target instanceof HTMLInputElement||event.target instanceof HTMLTextAreaElement)return;
    if(platform.preferencesWindow)return;
    if(event.ctrlKey||event.metaKey){const session=snapshot.sessions.find(item=>item.id===snapshot.selectedSessionId&&item.pendingInteractions.length)||snapshot.sessions.find(item=>item.pendingInteractions.length);const request=session?.pendingInteractions[0];if(!session||!request)return;const key=event.key.toLowerCase();if(request.kind==='permission'&&(key==='y'||key==='n')){event.preventDefault();void decide(session,request,{kind:'permission',approved:key==='y'});}else if(request.kind==='question'&&!request.allowsMultipleAnswers&&/^[1-9]$/.test(key)){const answer=request.options[Number(key)-1];if(answer){event.preventDefault();void decide(session,request,{kind:'question',answer});}}}
  };
  const onWheel = (event: WheelEvent) => {
    const target = event.target instanceof Element ? event.target : undefined;
    if (!linkPreferencesReady || !linkPreferences.swipeEnabled || platform.preferencesWindow || !platform.switchIsland || switchingIsland || event.ctrlKey || event.metaKey ||
      !target?.closest('.island-header, .collapsed-body') || target.closest('input, textarea, select, [contenteditable=true]')) return;
    if (switchGesture.accept(event.deltaX, event.deltaY, event.deltaMode, performance.now(), linkPreferences.sensitivity)) { event.preventDefault(); void switchIsland(); }
  };
  shell.addEventListener('wheel', onWheel, { passive: false });
  shell.addEventListener('pointerdown',onPointerDown,true);shell.addEventListener('pointerenter',onPointerEnter);shell.addEventListener('pointerleave',onPointerLeave);shell.addEventListener('focusin',onFocus);shell.addEventListener('keydown',onKey);shell.addEventListener('compositionstart',onCompositionStart);shell.addEventListener('compositionend',onCompositionEnd);
  const onScheme=()=>render();scheme.addEventListener('change',onScheme);
  systemMotion.addEventListener('change',onScheme);window.addEventListener('pointermove',onPointerMove);
  const countInterval=setInterval(()=>{if(!expanded){const count=shell.querySelector('.collapsed-count');if(count){const total=Math.floor(Date.now()/5000)%2===1;count.replaceChildren(el('b','',String(total?snapshot.sessions.length:visibleSessions().filter(session=>LIVE.has(session.status)).length)),el('span','',total?t('全部'):t('活跃')));}}},5000);
  if(message)showMessage(message);
  render();
  void refreshLinkPreferences();
  const linkInterval=setInterval(()=>{void refreshLinkPreferences();},2500);
  const onLanguage=()=>{if(settings.language==='system')render();};window.addEventListener('languagechange',onLanguage);
  let viewportFrame:number|undefined;
  const onViewport=()=>{if(!platform.preferencesWindow)return;if(viewportFrame!==undefined)cancelAnimationFrame(viewportFrame);viewportFrame=requestAnimationFrame(()=>{viewportFrame=undefined;render();});};
  window.addEventListener('resize',onViewport);
  return {expand,collapse,showSettings:(pane?:string)=>showSettings(PANES.some(([id])=>id===pane)?pane as SettingsPane:'general'),applySettings,previewSound,showError:showMessage,destroy(){disposed=true;unsubscribe();unsubscribeCompletion();clearInterval(countInterval);clearInterval(linkInterval);for(const timer of[autoHide,hoverExit,toastTimer,resizeTimer])if(timer)clearTimeout(timer);if(viewportFrame!==undefined)cancelAnimationFrame(viewportFrame);scheme.removeEventListener('change',onScheme);systemMotion.removeEventListener('change',onScheme);window.removeEventListener('pointermove',onPointerMove);window.removeEventListener('languagechange',onLanguage);window.removeEventListener('resize',onViewport);integrations.destroy();motion.destroy();sound.destroy();element.replaceChildren();}};
}
