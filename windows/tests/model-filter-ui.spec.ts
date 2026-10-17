import { expect, test, type Page } from '@playwright/test';
import type { DIMessage } from '../src/core/protocol';
import type { SessionStore } from '../src/core/session-store';

interface ModelFixture { id: string; agentType: string; model: string; status?: string; parentSessionId?: string }
type ModelHarness = { store: SessionStore; send(patch: Partial<DIMessage>): void };

test.use({ locale: 'zh-CN' });

async function mountModelHarness(page: Page, fixtures: ModelFixture[]) {
  await page.addInitScript(() => localStorage.clear());
  await page.goto('/');
  await page.evaluate(async fixtures => {
    const corePath = '/src/core/session-store.ts', uiPath = '/src/ui/index.ts', settingsPath = '/src/ui/settings.ts';
    const { SessionStore } = await import(corePath), { mountIsland } = await import(uiPath), { DEFAULT_SETTINGS } = await import(settingsPath);
    const store = new SessionStore();
    for (const row of fixtures) {
      const message = { type: 'session_start', sessionId: row.id, agentType: row.agentType, timestamp: new Date().toISOString(),
        prompt: `任务 ${row.id}`, workingDir: 'C:\\project', model: row.model, parentSessionId: row.parentSessionId };
      const result = store.apply(message);
      if (!result.accepted) throw new Error(result.reason);
      if (row.status) store.apply({ ...message, type: 'status_update', observedState: row.status, statusIsAssistantReply: false });
    }
    const target = document.createElement('div'); target.id = 'app'; document.body.replaceChildren(target);
    const ui = mountIsland(target, store, { preview: true, resize: async () => {}, focus: async () => {}, respond: async () => {}, jump: async () => {}, exportHistory: async () => {} });
    ui.applySettings({ ...DEFAULT_SETTINGS, language: 'zh', theme: 'dark', soundEnabled: false, autoHideSeconds: 0, disableAnimations: true });
    ui.expand();
    (window as unknown as { __modelTest: ModelHarness }).__modelTest = { store, send(patch) {
      const result = store.apply({ type: 'status_update', sessionId: fixtures[0]!.id, agentType: fixtures[0]!.agentType,
        timestamp: new Date().toISOString(), statusIsAssistantReply: false, ...patch });
      if (!result.accepted) throw new Error(result.reason);
    } };
  }, fixtures);
  await page.getByRole('button', { name: '搜索与筛选', exact: true }).click();
}

test('GLM 模型跨客户端筛选与模型搜索保留客户端身份，并与状态相交', async ({ page }, testInfo) => {
  await mountModelHarness(page, [
    { id: 'claude_code-main', agentType: 'claude_code', model: 'glm-5.3' },
    { id: 'opencode-main', agentType: 'opencode', model: 'z-ai/GLM-5.3', status: 'idle' },
    { id: 'codex-main', agentType: 'codex', model: 'other-model' },
  ]);
  const agent = page.getByRole('combobox', { name: 'Agent 或模型', exact: true });
  const search = page.getByRole('searchbox');
  await agent.selectOption({ label: 'GLM 模型' });
  await expect(page.locator('.session-card')).toHaveCount(2);
  await expect(page.locator('[data-session-id="claude_code-main"] .session-model')).toHaveText('glm-5.3');
  await expect(page.locator('[data-session-id="opencode-main"] .session-model')).toHaveText('z-ai/GLM-5.3');
  await expect(page.locator('[data-session-id="opencode-main"] .session-model')).toBeInViewport();
  await expect(page.locator('[data-session-id="codex-main"]')).toHaveCount(0);
  await page.locator('.island-shell').screenshot({ path: testInfo.outputPath('glm-cross-client.png') });
  await search.fill('GLM-5.3');
  await expect(page.locator('.session-card')).toHaveCount(2);
  await page.getByRole('combobox', { name: '会话状态', exact: true }).selectOption('active');
  await expect(page.locator('.session-card')).toHaveCount(1);
  await expect(page.locator('[data-session-id="claude_code-main"]')).toBeVisible();
  await page.getByRole('combobox', { name: '会话状态', exact: true }).selectOption('all');
  await agent.selectOption('opencode');
  await expect(page.locator('.session-card')).toHaveCount(1);
  await expect(page.locator('[data-session-id="opencode-main"]')).toBeVisible();
  await search.fill('other-model');
  await expect(page.getByText('没有匹配的会话', { exact: true })).toBeVisible();
  await expect(page.getByText('没有匹配的会话', { exact: true })).toBeInViewport();
  await agent.selectOption('all');
  await expect(page.locator('[data-session-id="codex-main"]')).toBeVisible();
  expect(await page.evaluate(() => (window as unknown as { __modelTest: ModelHarness }).__modelTest.store.snapshot().sessions.map(row => row.agentType).sort()))
    .toEqual(['claude_code', 'codex', 'opencode']);
});

test('最后一个 GLM 模型切换后保留明确筛选和空结果', async ({ page }, testInfo) => {
  await mountModelHarness(page, [{ id: 'opencode-switch', agentType: 'opencode', model: 'glm-5.3' }]);
  const agent = page.getByRole('combobox', { name: 'Agent 或模型', exact: true });
  await agent.selectOption({ label: 'GLM 模型' });
  await expect(page.locator('.session-card')).toHaveCount(1);
  await page.evaluate(() => (window as unknown as { __modelTest: ModelHarness }).__modelTest.send({ model: 'other-model' }));
  await expect(agent).toHaveValue('model:glm');
  await expect(agent.locator('option:checked')).toHaveText('GLM 模型');
  await expect(page.locator('.session-card')).toHaveCount(0);
  await expect(page.getByText('没有匹配的会话', { exact: true })).toBeVisible();
  await expect(page.getByText('没有匹配的会话', { exact: true })).toBeInViewport();
  await page.locator('.island-shell').screenshot({ path: testInfo.outputPath('glm-empty-after-model-switch.png') });
  expect(await page.evaluate(() => (window as unknown as { __modelTest: ModelHarness }).__modelTest.store.snapshot().sessions.map(row => [row.id, row.agentType, row.usage.model])))
    .toEqual([['opencode-switch', 'opencode', 'other-model']]);
  await agent.selectOption('all');
  await expect(page.locator('[data-session-id="opencode-switch"]')).toBeVisible();
  await page.evaluate(() => (window as unknown as { __modelTest: ModelHarness }).__modelTest.send({ model: 'glm-5.3' }));
  await agent.selectOption({ label: 'GLM 模型' });
  await page.evaluate(() => (window as unknown as { __modelTest: ModelHarness }).__modelTest.store.loadFixture({ sessions: [] }));
  await expect(agent).toHaveValue('model:glm');
  await expect(page.getByText('没有匹配的会话', { exact: true })).toBeVisible();
  await expect(page.getByText('没有匹配的会话', { exact: true })).toBeInViewport();
});

test('仅匹配子会话时独立显示，展开仅包含匹配后代', async ({ page }, testInfo) => {
  await mountModelHarness(page, [
    { id: 'parent', agentType: 'claude_code', model: 'other-model' },
    { id: 'child', agentType: 'claude_code', model: 'glm-5.3', parentSessionId: 'parent' },
    { id: 'grandchild', agentType: 'claude_code', model: 'glm-5.3', parentSessionId: 'child' },
    { id: 'hidden', agentType: 'claude_code', model: 'other-model', parentSessionId: 'child' },
  ]);
  await page.getByRole('combobox', { name: 'Agent 或模型', exact: true }).selectOption({ label: 'GLM 模型' });
  await expect(page.locator('[data-session-id="parent"]')).toHaveCount(0);
  const child = page.locator('[data-session-id="child"]');
  await expect(child).toBeVisible();
  await expect(child).not.toHaveClass(/child-card/);
  await child.getByRole('button', { name: '展开 1 个子 Agent', exact: true }).click();
  await expect(page.locator('[data-session-id="grandchild"]')).toBeVisible();
  await expect(page.locator('[data-session-id="hidden"]')).toHaveCount(0);
  await expect(page.locator('.session-card')).toHaveCount(2);
  await page.locator('.island-shell').screenshot({ path: testInfo.outputPath('glm-filtered-children.png') });
  await page.getByRole('searchbox').fill('grandchild');
  await expect(page.locator('.session-card')).toHaveCount(1);
  await expect(page.locator('[data-session-id="grandchild"]')).toBeVisible();
  await expect(page.locator('[data-session-id="grandchild"]')).not.toHaveClass(/child-card/);
});
