import { agentName, badge, button, el, mascot } from './components';
import { t } from './i18n';
import type { IntegrationAgent, IntegrationApplyResult, IntegrationOperation, IntegrationPlanSummary, IntegrationPlatform, IntegrationStatus } from './platform';

const AGENTS: IntegrationAgent[] = ['claude_code', 'codex', 'cursor', 'gemini_cli', 'windsurf', 'trae_cn'];
interface AgentState { loading: boolean; status?: IntegrationStatus; error?: string; result?: IntegrationApplyResult }
interface Review { agent: IntegrationAgent; operation: IntegrationOperation; plan?: IntegrationPlanSummary; loading: boolean; applying: boolean; error?: string }
function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (error && typeof error === 'object' && 'message' in error && typeof error.message === 'string') return error.message;
  return String(error);
}

export class IntegrationControls {
  private states = new Map<IntegrationAgent, AgentState>();
  private review?: Review;
  private opened = false;
  private disposed = false;
  private generation = 0;
  private statusEpochs = new Map<IntegrationAgent, number>();
  private exporting = false;
  private exportedPath?: string;
  private exportError?: string;
  constructor(private readonly api: IntegrationPlatform | undefined, private readonly preview: boolean, private readonly rerender: () => void) {}
  get isReviewing(): boolean { return this.review !== undefined; }

  view(): HTMLElement {
    if (!this.opened && this.api && !this.preview) {
      this.opened = true;
      queueMicrotask(() => { if (!this.disposed) void this.refresh(); });
    }
    if (this.review) return this.reviewView(this.review);
    const section = el('section', 'integration-controls');
    const header = el('div', 'integration-section-header');
    header.append(el('h2', 'settings-section-title', t('Agent 接入')));
    if (this.api && !this.preview) header.append(button(t('刷新接入状态'), 'text-button', () => { void this.refresh(); }));
    section.append(header, el('p', 'settings-note integration-evidence-note', t('配置状态不等于兼容性验收；实际客户端均待验证。')));
    if (!this.api || this.preview) section.append(el('p', 'integration-unavailable', t(this.preview ? '浏览器预览不安装或移除接入，请在 Windows 客户端操作。' : '当前客户端尚未接入配置服务。')));
    for (const agent of AGENTS) section.append(this.agentCard(agent));
    section.append(this.workBuddyCard());
    return section;
  }

  private workBuddyCard(): HTMLElement {
    const card = el('article', 'integration-card'); card.dataset.integrationAgent = 'workbuddy';
    const header = el('div', 'integration-card-header');
    header.append(mascot('workbuddy', 'idle', 24), el('strong', '', 'WorkBuddy'), el('span', 'header-spacer'), badge(t('观察模式')));
    card.append(header, el('p', 'settings-note', t('观察会话、工具结果和等待确认；审批与回答仍在 WorkBuddy 中完成。')),
      el('span', 'integration-verification', t('实际客户端未验收')));
    if (this.api?.exportWorkBuddy && !this.preview) {
      const exportButton = button(t(this.exporting ? '正在导出…' : '导出 WorkBuddy 插件…'), 'settings-action', () => { void this.exportWorkBuddy(); });
      exportButton.disabled = this.exporting; card.append(exportButton);
    } else card.append(el('p', 'settings-note', t('请在 Windows 客户端导出插件。')));
    if (this.exportedPath) card.append(el('p', 'integration-result', t('插件已导出，尚未安装。请在 WorkBuddy 添加本地市场，选择下方目录，再安装并启用插件。')),
      el('code', 'integration-path', this.exportedPath));
    if (this.exportError) { const error = el('p', 'integration-error', this.exportError); error.setAttribute('role', 'alert'); card.append(error); }
    return card;
  }

  private async exportWorkBuddy(): Promise<void> {
    if (!this.api?.exportWorkBuddy || this.preview || this.exporting || this.disposed) return;
    this.exporting = true; this.exportError = undefined; this.rerender();
    try {
      const result = await this.api.exportWorkBuddy();
      if (!this.disposed) this.exportedPath = result.exportedPath;
    } catch (error) { if (!this.disposed) this.exportError = errorMessage(error); }
    finally { this.exporting = false; if (!this.disposed) this.rerender(); }
  }

  private agentCard(agent: IntegrationAgent): HTMLElement {
    const state = this.states.get(agent);
    const status = state?.status;
    const card = el('article', 'integration-card'); card.dataset.integrationAgent = agent;
    const header = el('div', 'integration-card-header');
    header.append(mascot(agent, status?.installed ? 'idle' : 'observationUnavailable', 24), el('strong', '', agentName(agent)), el('span', 'header-spacer'));
    const statusLabel = !this.api || this.preview ? t('当前平台不可用') : state?.loading ? t('正在检查…') : state?.error ? t('检查失败') :
      !status ? t('等待检查') : !status.platformSupported ? t('当前平台不可用') : status.configurationKnown === false || status.installed === null ? t('运行时未就绪，配置状态未知') : !status.runtimeReady ? t('缺少运行时') : status.installed ? t('已配置') : (status.managedHandlers ?? 0) > 0 ? t('需更新') : t('未配置');
    header.append(badge(statusLabel, status?.installed && status.runtimeReady ? 'var(--green)' : 'var(--muted)'));
    card.append(header);
    if (status?.configPath) card.append(el('code', 'integration-path', status.configPath));
    if (status?.reason) card.append(el('p', 'settings-note', status.reason));
    card.append(el('span', 'integration-verification', t('实际客户端未验收')));
    if (status?.warnings.length) card.append(this.warnings(status.warnings));
    if (state?.error) { const error = el('p', 'integration-error', state.error); error.setAttribute('role', 'alert'); card.append(error); }
    if (state?.result) {
      const result = state.result;
      card.append(el('p', 'integration-result', t(result.applied ? '配置变更已写入；请在原客户端确认信任并验证事件。' : '配置已经符合计划，无需写入。')));
      if ('backupId' in result && result.backupId) card.append(el('code', 'integration-path', `${t('备份文件')}：${result.backupId}`));
    }
    if (this.api && !this.preview) {
      const actions = el('div', 'integration-actions');
      const install = button(t(status?.installed ? '查看更新计划' : status && (status.managedHandlers ?? 0) > 0 ? '更新接入…' : '启用接入…'), 'settings-action', () => { void this.plan(agent, 'install'); });
      install.disabled = !!state?.loading || !!state?.error || !status?.platformSupported || !status.runtimeReady;
      const uninstall = button(t('移除接入…'), 'settings-action danger', () => { void this.plan(agent, 'uninstall'); });
      // 运行时丢失时仍可移除旧 hook；只有确实存在本工具托管项才提供移除。
      uninstall.disabled = !!state?.loading || !!state?.error || !status?.platformSupported || !((status.managedHandlers ?? 0) > 0);
      actions.append(install, uninstall); card.append(actions);
    }
    return card;
  }

  private warnings(values: string[]): HTMLDetailsElement {
    const disclosure = el('details', 'integration-warnings');
    disclosure.append(el('summary', '', t('注意事项（{count}）', { count: values.length })));
    const list = el('ul');
    for (const value of values) list.append(el('li', '', value));
    disclosure.append(list); return disclosure;
  }

  private async refresh(): Promise<void> {
    if (!this.api || this.preview || this.disposed) return;
    await Promise.allSettled(AGENTS.map(agent => this.refreshAgent(agent)));
  }

  private async refreshAgent(agent: IntegrationAgent): Promise<void> {
    if (!this.api || this.disposed) return;
    const epoch = (this.statusEpochs.get(agent) ?? 0) + 1;
    this.statusEpochs.set(agent, epoch);
    const previous = this.states.get(agent);
    this.states.set(agent, { ...previous, loading: true, error: undefined }); this.changed();
    try {
      const status = await this.api.status(agent);
      if (this.statusEpochs.get(agent) !== epoch || this.disposed) return;
      if (status.agent !== agent || typeof status.platformSupported !== 'boolean' || typeof status.runtimeReady !== 'boolean' || (typeof status.installed !== 'boolean' && !(status.installed === null && status.configurationKnown === false)) || !Array.isArray(status.warnings)) throw new Error(t('接入服务返回了无效状态，未执行写入。'));
      this.states.set(agent, { loading: false, status, result: previous?.result });
    } catch (error) { if (this.statusEpochs.get(agent) !== epoch || this.disposed) return; this.states.set(agent, { ...previous, loading: false, error: errorMessage(error) }); }
    this.changed();
  }

  private async plan(agent: IntegrationAgent, operation: IntegrationOperation): Promise<void> {
    if (!this.api || this.preview || this.review?.applying) return;
    const generation = ++this.generation;
    this.review = { agent, operation, loading: true, applying: false }; this.changed();
    try {
      const plan = await this.api.plan(agent, operation);
      if (generation !== this.generation || this.disposed) return;
      if (plan.agent !== agent || plan.operation !== operation || !/^[a-f0-9]{64}$/.test(plan.revision) || !plan.configPath ||
        !Number.isInteger(plan.addedHandlers) || plan.addedHandlers < 0 || !Number.isInteger(plan.removedHandlers) || plan.removedHandlers < 0 ||
        !plan.backup || typeof plan.backup.required !== 'boolean' || !Array.isArray(plan.warnings)) throw new Error(t('接入计划无效，请重新检查。'));
      this.review = { agent, operation, plan, loading: false, applying: false };
    } catch (error) {
      if (generation !== this.generation || this.disposed) return;
      this.review = { agent, operation, loading: false, applying: false, error: errorMessage(error) };
    }
    this.changed();
  }

  private reviewView(review: Review): HTMLElement {
    const section = el('section', 'integration-review'); section.setAttribute('aria-label', t('接入变更预览'));
    const back = button(t('返回接入列表'), 'text-button', () => { if (!this.review?.applying) { this.generation++; this.review = undefined; this.changed(); } });
    back.disabled = review.applying; section.append(back);
    section.append(el('h2', '', t(review.operation === 'install' ? '确认启用或更新 {agent}' : '确认移除 {agent}', { agent: agentName(review.agent) })));
    section.append(el('p', 'settings-note', t('以下计划尚未写入。确认后仅修改列出的配置文件。')));
    if (review.loading) section.append(el('p', 'settings-note', t('正在生成配置计划…')));
    if (review.plan) {
      const plan = review.plan;
      const summary = el('dl', 'integration-plan-summary');
      this.summaryLine(summary, t('配置文件'), plan.configPath, true);
      this.summaryLine(summary, t('增加 hook'), String(plan.addedHandlers));
      this.summaryLine(summary, t('移除 hook'), String(plan.removedHandlers));
      this.summaryLine(summary, t('备份'), t(plan.backup.required ? '写入前在原目录创建带时间戳的独立备份。' : '原配置不存在或没有变更，不需要原文件备份。'));
      if (plan.backup.required) this.summaryLine(summary, t('备份位置'), `${plan.backup.directory}/${plan.backup.filenamePrefix}*.bak`, true);
      section.append(summary);
      if (plan.warnings.length) { const warnings = this.warnings(plan.warnings); warnings.open = true; section.append(warnings); }
      section.append(el('p', 'integration-verification', t('实际客户端未验收')));
      if (!plan.changed) section.append(el('p', 'settings-note', t('配置已经符合计划，无需写入。')));
    }
    if (review.error) {
      const error = el('div', 'integration-error', review.error); error.setAttribute('role', 'alert'); section.append(error);
      section.append(el('p', 'settings-note', t('应用失败后必须重新检查计划；不会重用旧确认覆盖新配置。')));
    }
    const actions = el('div', 'integration-actions');
    const recheck = button(t('重新检查计划'), 'settings-action', () => { void this.plan(review.agent, review.operation); });
    recheck.disabled = review.applying || review.loading;
    const confirm = button(t(review.applying ? '正在应用…' : '确认应用变更'), 'decision-button allow', () => { void this.apply(); });
    confirm.disabled = review.loading || review.applying || !!review.error || !review.plan?.changed || (review.operation === 'install' && !review.plan.runtimeReady);
    actions.append(recheck, confirm); section.append(actions); return section;
  }

  private summaryLine(list: HTMLElement, label: string, value: string, code = false): void {
    list.append(el('dt', '', label), el('dd', code ? 'integration-path' : '', value));
  }

  private async apply(): Promise<void> {
    const review = this.review;
    if (!this.api || this.preview || !review?.plan || review.error || review.applying || !review.plan.changed) return;
    review.applying = true; this.changed();
    try {
      const result = await this.api.apply(review.agent, review.operation, review.plan.revision);
      if (result.agent !== review.agent || result.operation !== review.operation || typeof result.applied !== 'boolean') throw new Error(t('接入服务未返回有效结果，请刷新状态确认。'));
      this.states.set(review.agent, { ...this.states.get(review.agent), loading: false, result });
      this.review = undefined; this.changed();
      await this.refreshAgent(review.agent);
    } catch (error) {
      review.applying = false; review.error = errorMessage(error); this.review = review; this.changed();
    }
  }

  private changed(): void { if (!this.disposed) this.rerender(); }
  destroy(): void { this.disposed = true; this.generation++; }
}
