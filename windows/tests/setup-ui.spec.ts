import { expect, test, type Page } from '@playwright/test';
import path from 'node:path';

test.use({ locale: 'zh-CN' });

async function setup(page: Page) {
  await page.goto('/');
  await page.evaluate(async () => {
    localStorage.clear();
    const corePath = '/src/core/index.ts', uiPath = '/src/ui/index.ts', setupPath = '/src/integrations/setup-coordinator.ts';
    const { SessionStore } = await import(corePath), { mountIsland } = await import(uiPath);
    const { IntegrationSetupCoordinator } = await import(setupPath);
    const listeners = new Set<(value: any) => void>(), statuses: Record<string, any> = {};
    const calls: any[] = [];
    for (const agent of ['claude_code', 'codex', 'cursor', 'gemini_cli', 'windsurf', 'trae_cn', 'qwen', 'code_buddy', 'droid', 'opencode', 'kimi_code']) {
      statuses[agent] = { agent, platformSupported: true, runtimeReady: true, installed: agent !== 'qwen', managedHandlers: agent === 'qwen' ? 0 : 2,
        configPath: `C:/Users/Fixture/${agent}/settings.json`, revision: 'a'.repeat(64), warnings: [],
        client: { state: ['qwen', 'codex', 'droid'].includes(agent) ? 'detected' : 'not_found', detail: '隔离软件检测样例' } };
    }
    statuses.codex.trust = { state: 'required', configuredCount: 2, trustedCount: 0 };
    statuses.droid.activity = { event: 'SessionStart', receivedAt: Date.now() };
    const api: any = {
      status: async (agent: string) => structuredClone(statuses[agent]),
      plan: async (agent: string, operation: string) => ({ agent, operation, revision: statuses[agent].revision, configPath: statuses[agent].configPath,
        runtimeReady: true, changed: true, addedHandlers: operation === 'install' ? 2 : 0, removedHandlers: operation === 'uninstall' ? 2 : 0,
        backup: { required: true, exclusive: true, directory: 'C:/Users/Fixture', filenamePrefix: 'xisland-backup' }, warnings: [], sources: [] }),
      apply: async (agent: string, operation: string) => {
        calls.push({ agent, operation }); statuses[agent].installed = operation === 'install';
        statuses[agent].managedHandlers = operation === 'install' ? 2 : 0;
        statuses[agent].revision = (operation === 'install' ? 'b' : 'c').repeat(64);
        return { agent, operation, applied: true, runtimeReady: true };
      },
      workBuddyStatus: async () => ({ agent: 'workbuddy', runtimeReady: true, needsPreparation: false,
        client: { state: 'detected', detail: '隔离 WorkBuddy 样例' }, exportedPath: 'C:/Users/Fixture/XIsland-Plugins/workbuddy-fixture' }),
      exportWorkBuddy: async () => ({ exportedPath: 'C:/Users/Fixture/XIsland-Plugins/workbuddy-fixture' }),
      prepareWorkBuddy: async () => ({ exportedPath: 'C:/Users/Fixture/XIsland-Plugins/workbuddy-fixture' }),
      openWorkBuddyFolder: async (value: string) => { calls.push({ folder: value }); },
      kiroStatus: async () => ({ agent: 'kiro', runtimeReady: true, needsPreparation: false,
        client: { state: 'detected', detail: '隔离 Kiro 样例' }, exportedPath: 'C:/Users/Fixture/XIsland-Plugins/kiro-fixture' }),
      prepareKiro: async () => ({ exportedPath: 'C:/Users/Fixture/XIsland-Plugins/kiro-fixture' }),
    };
    let state: unknown = null;
    const coordinator = new IntegrationSetupCoordinator(api, { load: async () => state, save: async (value: unknown) => { state = value; } },
      { changed: (snapshot: unknown) => listeners.forEach(listener => listener(snapshot)) });
    api.setup = { snapshot: async () => coordinator.snapshot(), subscribe: async (handler: (value: unknown) => void) => { listeners.add(handler); return () => listeners.delete(handler); },
      refresh: (prepare: boolean) => coordinator.refresh(prepare), setEnabled: (agent: string, enabled: boolean) => coordinator.setEnabled(agent, enabled),
      presented: () => coordinator.presented() };
    const store = new SessionStore();
    const host = document.querySelector<HTMLElement>('#app')!; host.replaceChildren();
    const ui = mountIsland(host, store, { preview: false, preferencesWindow: true, initialSettingsPane: 'agents', integrations: api,
      resize: async () => {}, focus: async () => {}, respond: async () => {}, jump: async () => {}, exportHistory: async () => {}, closeSettings: async () => {} });
    (window as any).setupHarness = { api, calls, statuses, coordinator, ui };
    await coordinator.start();
  });
}

test('接入窗口区分待授权、等待活动和已接入，支持开关与文件取用', async ({ page }) => {
  await setup(page);
  const qwen = page.locator('[data-integration-agent="qwen"]'), codex = page.locator('[data-integration-agent="codex"]');
  await expect(qwen).toHaveAttribute('data-setup-phase', 'waitingForActivity');
  await expect(codex).toHaveAttribute('data-setup-phase', 'needsAuthorization');
  await expect(codex.getByText(/打开 \/hooks/)).toBeVisible();
  await expect(page.locator('[data-integration-agent="droid"]')).toHaveAttribute('data-setup-phase', 'connected');
  expect(await page.evaluate(() => (window as any).setupHarness.calls)).toEqual([{ agent: 'qwen', operation: 'install' }]);
  const workbuddy = page.locator('[data-integration-agent="workbuddy"]');
  await expect(workbuddy.getByText('文件已准备，待原客户端启用', { exact: true })).toBeVisible();
  await workbuddy.getByRole('button', { name: '打开接入文件夹' }).click();
  expect(await page.evaluate(() => (window as any).setupHarness.calls.at(-1).folder)).toContain('workbuddy-fixture');
  const kiro = page.locator('[data-integration-agent="kiro"]');
  await expect(kiro.getByText('文件已准备，待原客户端启用', { exact: true })).toBeVisible();
  await kiro.getByRole('button', { name: '打开接入文件夹' }).click();
  expect(await page.evaluate(() => (window as any).setupHarness.calls.at(-1).folder)).toContain('kiro-fixture');
  await qwen.getByRole('checkbox', { name: '自动接入 Qwen Code', exact: true }).uncheck();
  await expect(qwen).toHaveAttribute('data-setup-phase', 'disabled');
  await qwen.getByRole('checkbox').check();
  await expect(qwen).toHaveAttribute('data-setup-phase', 'waitingForActivity');
  await page.evaluate(async () => { const h = (window as any).setupHarness; h.statuses.qwen.activity = { event: 'SessionStart', receivedAt: Date.now() }; await h.coordinator.refresh(false); });
  await expect(qwen).toHaveAttribute('data-setup-phase', 'connected');
  await codex.scrollIntoViewIfNeeded();
  await page.locator('.island-shell').screenshot({ path: path.resolve('../docs/windows/evidence/ui-setup-phases-mock.png'), animations: 'disabled' });
});

test('手动移除接入会先关闭自动准备，后续检查不重新写回', async ({ page }) => {
  await setup(page);
  const qwen = page.locator('[data-integration-agent="qwen"]');
  await expect(qwen).toHaveAttribute('data-setup-phase', 'waitingForActivity');
  await qwen.getByRole('button', { name: '移除接入…' }).click();
  await page.getByRole('button', { name: '确认应用变更', exact: true }).click();
  await expect(qwen).toHaveAttribute('data-setup-phase', 'disabled');
  await page.evaluate(async () => { await (window as any).setupHarness.coordinator.refresh(true); });
  expect(await page.evaluate(() => (window as any).setupHarness.calls.filter((call: any) => call.agent === 'qwen')))
    .toEqual([{ agent: 'qwen', operation: 'install' }, { agent: 'qwen', operation: 'uninstall' }]);
});

test('准备Kiro期间旧状态返回后会补查，不丢失已经准备的目录', async ({ page }) => {
  await setup(page);
  const kiro = page.locator('[data-integration-agent="kiro"]');
  await expect(kiro.getByText('文件已准备，待原客户端启用', { exact: true })).toBeVisible();
  await page.evaluate(() => {
    const h = (window as any).setupHarness;
    const stale = { agent: 'kiro', runtimeReady: true, needsPreparation: true, client: { state: 'detected', detail: 'fixture' } };
    let first = true, current: any = stale;
    h.api.kiroStatus = async () => {
      if (first) { first = false; h.checkStarted = true; return new Promise(resolve => { h.resolveKiroCheck = () => resolve(stale); }); }
      return current;
    };
    h.api.prepareKiro = async () => {
      current = { ...stale, needsPreparation: false, exportedPath: 'C:/Users/Fixture/XIsland-Plugins/kiro-new' };
      return { exportedPath: current.exportedPath };
    };
  });
  await page.getByRole('button', { name: '刷新接入状态', exact: true }).click();
  await expect.poll(() => page.evaluate(() => (window as any).setupHarness.checkStarted)).toBe(true);
  await kiro.getByRole('button', { name: '准备 Kiro 接入文件', exact: true }).click();
  await page.evaluate(() => (window as any).setupHarness.resolveKiroCheck());
  await expect(kiro.locator('.integration-path')).toHaveText('C:/Users/Fixture/XIsland-Plugins/kiro-new');
  await expect(kiro.getByText('文件已准备，待原客户端启用', { exact: true })).toBeVisible();
});
