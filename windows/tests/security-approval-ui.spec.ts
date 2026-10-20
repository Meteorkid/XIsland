import { expect, test, type Page } from '@playwright/test';
import type { SessionStore } from '../src/core/session-store';
import type { DIResponse } from '../src/core/protocol';

type Harness = { store: SessionStore; calls: Array<{ requestId: string; response: DIResponse }> };
const command = "printf 'approval-evidence\\n'";
const input = { description: '只读检查项目，安全可执行', command, extra: { text: '<img src=x onerror=alert(1)>', values: ['保留', 2] } };
test.use({ locale: 'zh-CN' });

async function mountPermission(page: Page, adapter: 'claude' | 'codex' | 'qwen', fields: Record<string, unknown> = {}) {
  await page.goto('/');
  await page.evaluate(async ({ adapter, input, fields }) => {
    localStorage.clear();
    const corePath = '/src/core/session-store.ts', uiPath = '/src/ui/index.ts', adapterPath = `/src/adapters/${adapter}.ts`;
    const { SessionStore } = await import(corePath);
    const { mountIsland } = await import(uiPath);
    const adapters = await import(adapterPath);
    const normalize = adapters[{ claude: 'normalizeClaudeHook', codex: 'normalizeCodexHook', qwen: 'normalizeQwenHook' }[adapter]];
    const store = new SessionStore();
    const message = normalize({ hook_event_name: 'PermissionRequest', session_id: 'approval-ui', tool_name: 'Bash',
      tool_input: input, description: input.description, ...fields });
    const result = store.apply(message, { requestId: 'isolated-native-channel', expiresAt: Date.now() + 60_000 });
    if (!result.accepted) throw new Error(result.reason);
    const target = document.createElement('div'); target.id = 'app';
    document.getElementById('app')?.remove(); document.body.append(target);
    const calls: Harness['calls'] = [];
    (window as unknown as { __approvalTest: Harness }).__approvalTest = { store, calls };
    mountIsland(target, store, {
      preview: true, resize: async () => {}, focus: async () => {}, jump: async () => {}, exportHistory: async () => {},
      respond: async (requestId: string, response: DIResponse) => { calls.push({ requestId, response }); },
    });
  }, { adapter, input, fields });
  const expand = page.getByRole('button', { name: '展开 XIsland', exact: true });
  if (await expand.isVisible()) await expand.click();
}

for (const adapter of ['claude', 'codex', 'qwen'] as const) {
  test(`${adapter} 主摘要显示真实命令，展开完整参数且按文本呈现`, async ({ page }, testInfo) => {
    await mountPermission(page, adapter);
    await expect(page.locator('.request-summary')).toHaveText(command);
    await expect(page.locator('.request-summary')).toBeInViewport();
    await expect(page.getByRole('button', { name: '允许', exact: true })).toBeInViewport();
    await expect(page.locator('.request-input')).toHaveCount(0);
    await page.locator('.island-shell').screenshot({ path: testInfo.outputPath(`${adapter}-approval-summary.png`), animations: 'disabled' });
    await page.getByRole('button', { name: '查看权限详情', exact: true }).click();
    await expect(page.getByText('原始工具参数', { exact: true })).toBeVisible();
    expect(JSON.parse(await page.locator('.request-input').textContent() ?? '')).toEqual(input);
    await expect(page.locator('.request-description')).toHaveText(input.description);
    await expect(page.locator('.request-details img, .request-details script')).toHaveCount(0);
    await page.locator('.island-shell').screenshot({ path: testInfo.outputPath(`${adapter}-approval-details.png`), animations: 'disabled' });
    expect(await page.evaluate(() => (window as unknown as { __approvalTest: Harness }).__approvalTest.calls)).toEqual([]);
    await page.getByRole('button', { name: '拒绝', exact: true }).click();
    await expect(page.locator('.interaction-permission')).toHaveCount(0);
    const calls = await page.evaluate(() => (window as unknown as { __approvalTest: Harness }).__approvalTest.calls);
    expect(calls).toHaveLength(1); expect(calls[0].requestId).toBe('isolated-native-channel');
    expect(calls[0].response).toMatchObject({ type: 'permission_response', approved: false });
  });
}

for (const adapter of ['claude', 'codex'] as const) {
  test(`${adapter} 纯文本工具输入作为可见摘要和完整详情保留`, async ({ page }) => {
    await mountPermission(page, adapter, { tool_input: command });
    await expect(page.locator('.request-summary')).toHaveText(command);
    await page.getByRole('button', { name: '查看权限详情', exact: true }).click();
    await expect(page.locator('.request-input')).toHaveText(command);
  });
  for (const [shape, value] of [
    ['纯文本', input.description],
    ['数组', [input.description, input.extra]],
    ['JSON 数组', JSON.stringify([input.description, input.extra], null, 2)],
    ['对象', { description: input.description, extra: input.extra }],
    ['JSON 对象', JSON.stringify({ description: input.description, extra: input.extra }, null, 2)],
  ] as const) {
    test(`${adapter} 顶层命令不被${shape}参数遮住且完整原生包可见`, async ({ page }, testInfo) => {
      const fields = { tool_input: value, command, extra: input.extra };
      await mountPermission(page, adapter, fields);
      await expect(page.locator('.request-summary')).toHaveText(command);
      await expect(page.locator('.request-summary')).toBeInViewport();
      await page.getByRole('button', { name: '查看权限详情', exact: true }).click();
      expect(JSON.parse(await page.locator('.request-input').textContent() ?? '')).toEqual({
        hook_event_name: 'PermissionRequest', session_id: 'approval-ui', tool_name: 'Bash', description: input.description, ...fields,
      });
      await expect(page.locator('.request-description')).toHaveText(input.description);
      await expect(page.locator('.request-details img, .request-details script')).toHaveCount(0);
      if (shape === '纯文本') await page.locator('.island-shell').screenshot({ path: testInfo.outputPath(`${adapter}-top-level-command.png`), animations: 'disabled' });
      expect(await page.evaluate(() => (window as unknown as { __approvalTest: Harness }).__approvalTest.calls)).toEqual([]);
    });
  }
}

test('第一题明确回答后，第二题仍等待独立决定', async ({ page }) => {
  await mountPermission(page, 'claude');
  await page.getByRole('button', { name: '拒绝', exact: true }).click();
  const sendQuestion = async (text: string, requestId: string) => page.evaluate(async ({ text, requestId }) => {
    const adapterPath = '/src/adapters/claude.ts';
    const { normalizeClaudeHook } = await import(adapterPath);
    const { store } = (window as unknown as { __approvalTest: Harness }).__approvalTest;
    const result = store.apply(normalizeClaudeHook({ hook_event_name: 'PreToolUse', session_id: 'approval-ui', tool_name: 'AskUserQuestion',
      tool_input: { question: text, options: ['显式回答'] } }), { requestId, expiresAt: Date.now() + 60_000 });
    if (!result.accepted) throw new Error(result.reason);
  }, { text, requestId });
  await sendQuestion('第一题', 'first-question');
  await page.getByRole('button', { name: '显式回答', exact: true }).click();
  await expect(page.locator('.interaction-question')).toHaveCount(0);
  await sendQuestion('第二题', 'second-question');
  await expect(page.locator('.question-text')).toHaveText('第二题');
  expect(await page.evaluate(() => (window as unknown as { __approvalTest: Harness }).__approvalTest.calls.map(call => call.requestId)))
    .toEqual(['isolated-native-channel', 'first-question']);
  await page.getByRole('button', { name: '显式回答', exact: true }).click();
  await expect(page.locator('.interaction-question')).toHaveCount(0);
  expect(await page.evaluate(() => (window as unknown as { __approvalTest: Harness }).__approvalTest.calls.at(-1)?.requestId)).toBe('second-question');
});
