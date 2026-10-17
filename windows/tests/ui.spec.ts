import { expect, test, type Page } from '@playwright/test';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

const evidence = path.resolve('../docs/windows/evidence');
test.use({ locale: 'zh-CN' });
test.beforeAll(async () => { await mkdir(evidence, { recursive: true }); });
test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    if (!sessionStorage.getItem('xisland-test-initialized')) {
      localStorage.clear(); sessionStorage.setItem('xisland-test-initialized', '1');
    }
  });
});

async function capture(page: Page, name: string) {
  await page.locator('.island-shell').screenshot({ path: path.join(evidence, name), animations: 'disabled' });
}

test('收起与展开沿用尺寸，搜索和主题通过真实点击生效', async ({ page }) => {
  await page.goto('/?fixture=sessions');
  const collapsed = await page.locator('.island-shell').boundingBox();
  expect(collapsed?.width).toBeCloseTo(261.34, 1);
  expect(collapsed?.height).toBeCloseTo(60.77, 1);
  await capture(page, 'ui-collapsed-dark.png');
  await page.getByRole('button', { name: '展开 XIsland', exact: true }).click();
  await expect(page.locator('.island-shell')).toHaveCSS('width', '380px');
  await expect(page.getByText('Implement diagnostics', { exact: true })).toBeVisible();
  await capture(page, 'ui-expanded-dark.png');
  await page.getByRole('button', { name: '搜索与筛选', exact: true }).click();
  await page.getByRole('searchbox').fill('update');
  await expect(page.locator('.session-card')).toHaveCount(1);
  await expect(page.getByText('Review update flow', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: '设置', exact: true }).click();
  await expect(page.locator('.island-shell')).toHaveCSS('width', '760px');
  await page.getByRole('button', { name: '显示', exact: true }).click();
  await page.getByRole('button', { name: '浅色', exact: true }).click();
  await expect(page.locator('#app')).toHaveAttribute('data-theme', 'light');
  await capture(page, 'ui-settings-light.png');
  await page.getByRole('button', { name: '返回灵动岛', exact: true }).click();
  await expect(page.locator('.island-shell')).toHaveCSS('width', '380px');
});

test('权限请求可见且允许后才移除待办', async ({ page }) => {
  await page.goto('/?fixture=permission&expanded=1');
  const allow = page.getByRole('button', { name: '允许', exact: true });
  await expect(allow).toBeInViewport();
  await expect(page.getByText('List the workspace files', { exact: true })).toBeVisible();
  await capture(page, 'ui-permission-dark.png');
  await allow.click();
  await expect(page.locator('.interaction-permission')).toHaveCount(0);
  await expect(page.getByRole('status')).toHaveText('已发送到 Agent');
});

test('自由问答支持中文输入，提交清除当前请求', async ({ page }) => {
  await page.goto('/?fixture=custom&expanded=1');
  const field = page.getByRole('textbox', { name: '自定义回答', exact: true });
  await field.fill('先完成 Windows 版本，再测试双屏缩放。');
  await expect(field).toHaveValue('先完成 Windows 版本，再测试双屏缩放。');
  await capture(page, 'ui-question-chinese.png');
  await page.getByRole('button', { name: '发送回答', exact: true }).click();
  await expect(page.locator('.interaction-question')).toHaveCount(0);
});

test('计划反馈与详情可操作，批准后移除对应请求', async ({ page }) => {
  await page.goto('/?fixture=plan&expanded=1');
  await page.getByRole('button', { name: '查看完整计划', exact: true }).click();
  await page.getByRole('textbox', { name: '计划反馈', exact: true }).fill('保留现有 macOS 客户端，先验证 Windows 审批回传。');
  await expect(page.getByRole('button', { name: '批准计划', exact: true })).toBeInViewport();
  await capture(page, 'ui-plan-feedback.png');
  await page.getByRole('button', { name: '批准计划', exact: true }).click();
  await expect(page.locator('.interaction-plan')).toHaveCount(0);
});

async function mountHarness(page: Page, options: { preferencesWindow?: boolean; externalSettings?: boolean; integrations?: boolean; unknownRuntime?: boolean; connectionEvidence?: boolean } = {}) {
  await page.goto('/');
  await page.evaluate(async options => {
    const corePath = '/src/core/index.ts', uiPath = '/src/ui/index.ts';
    const { SessionStore } = await import(corePath);
    const { mountIsland } = await import(uiPath);
    const store = new SessionStore();
    const target = document.createElement('div'); target.id = 'app';
    document.getElementById('app')?.remove(); document.body.append(target);
    const calls: unknown[] = [];
    const harness = { store, calls, rejectResponse: false, responseDelay: 0, rejectSettings: false, integrationCalls: [] as Array<{action:string;agent:string;operation?:string;revision?:string}>, integrationConflict:false, integrationRevision:'a'.repeat(64), ui: undefined as unknown };
    (window as unknown as { __islandTest: typeof harness }).__islandTest = harness;
    store.loadFixture({ sessions: [{ id: 'ime-session', agentType: 'claude_code', status: 'waitingAnswer', workingDirectory: '/tmp/ime', pendingQuestion: { text: '选择实现范围', options: ['窗口', '桥接', '历史'], allowsMultipleAnswers: true, allowsCustomAnswer: true } }] });
    const installed = new Set<string>();
    const removed = new Set<string>();
    const configPath = (agent:string) => `C:/Users/Demo/.${({claude_code:'claude',gemini_cli:'gemini',trae_cn:'trae-cn',windsurf:'codeium/windsurf'} as Record<string,string>)[agent] ?? agent}/${['codex','cursor','trae_cn','windsurf'].includes(agent)?'hooks':'settings'}.json`;
    const plan = (agent:string,operation:string) => ({agent,operation,configPath:configPath(agent),changed:true,addedHandlers:operation==='install'?7:0,removedHandlers:operation==='uninstall'?7:0,backup:{required:true,directory:'C:/Users/Demo/.claude',filenamePrefix:'settings.json.xisland-backup-',exclusive:true},warnings:['Mock warning: existing user hooks are preserved.'],sources:[],revision:harness.integrationRevision,runtimeReady:true});
    harness.ui = mountIsland(target, store, {
      preview: !options.integrations,
      preferencesWindow: options.preferencesWindow,
      openSettings: options.externalSettings ? async (pane:string) => { calls.push({kind:'openSettings',pane}); } : undefined,
      closeSettings: async () => { calls.push({kind:'closeSettings'}); },
      notify: options.preferencesWindow ? (kind:string) => { calls.push({kind:'notify',event:kind}); } : undefined,
      settingsChanged: async (settings:unknown) => { if(harness.rejectSettings) throw new Error('Settings write rejected');calls.push({kind:'settings',settings}); },
      integrations: options.integrations ? {
        exportWorkBuddy: async () => {
          harness.integrationCalls.push({action:'export',agent:'workbuddy'});
          return {agent:'workbuddy',exportedPath:'C:/Users/Demo/XIsland-Plugins/workbuddy-test',eventCount:11,observationOnly:true,clientVerified:false,runtimeReady:true};
        },
        status: async (agent:string) => {
          harness.integrationCalls.push({action:'status',agent});
          if(options.unknownRuntime)return {agent,platformSupported:true,runtimeReady:false,configurationKnown:false,installed:null,managedHandlers:null,reason:'node_not_found',warnings:['Node runtime is unavailable.']};
          if(options.connectionEvidence&&(agent==='qwen'||agent==='codex'))return {agent,platformSupported:true,runtimeReady:true,installed:true,managedHandlers:12,
            configPath:configPath(agent),revision:harness.integrationRevision,warnings:[],client:{state:'detected',detail:'隔离客户端发现样例'},
            trust:agent==='codex'?{state:'required',configuredCount:12,trustedCount:0,reason:'请在原客户端授权'}:undefined,
            activity:{event:'SessionStart',receivedAt:Date.now()}};
          return {agent,platformSupported:agent!=='gemini_cli',runtimeReady:agent!=='cursor'&&agent!=='gemini_cli',installed:installed.has(agent),managedHandlers:installed.has(agent)?7:removed.has(agent)?0:agent==='codex'||agent==='cursor'?3:0,configPath:configPath(agent),revision:harness.integrationRevision,warnings:[]};
        },
        plan: async (agent:string,operation:string) => {harness.integrationCalls.push({action:'plan',agent,operation});return plan(agent,operation);},
        apply: async (agent:string,operation:string,revision:string) => {
          harness.integrationCalls.push({action:'apply',agent,operation,revision});
          if(harness.integrationConflict)throw new Error('revision_conflict: configuration changed outside XIsland');
          if(operation==='install'){installed.add(agent);removed.delete(agent);}else{installed.delete(agent);removed.add(agent);}
          return {...plan(agent,operation),applied:true,backupId:'settings.json.xisland-backup-test.bak'};
        },
      } : undefined,
      resize: async () => {}, focus: async () => {}, jump: async () => {}, exportHistory: async () => {},
      respond: async (requestId: string, response: unknown) => {
        calls.push({ requestId, response });
        await new Promise(resolve => setTimeout(resolve, harness.responseDelay));
        if (harness.rejectResponse) throw new Error('模拟连接已断开');
      },
    });
  }, options);
}

test('IME 组合输入期间消息更新不替换文本框，结束后保留中文草稿', async ({ page }) => {
  await mountHarness(page);
  const field = page.getByRole('textbox', { name: '自定义回答', exact: true });
  await field.focus();
  await page.evaluate(() => {
    const input = document.querySelector<HTMLTextAreaElement>('.answer-input')!;
    (window as unknown as { __composingInput: HTMLTextAreaElement }).__composingInput = input;
    input.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: '' }));
    input.value = '正在输入中文';
    input.dispatchEvent(new InputEvent('input', { bubbles: true, data: '正在输入中文', isComposing: true }));
    const harness = (window as unknown as { __islandTest: { store: { select(id: string): void } } }).__islandTest;
    harness.store.select('ime-session');
  });
  expect(await page.evaluate(() => document.querySelector('.answer-input') === (window as unknown as { __composingInput: HTMLElement }).__composingInput)).toBe(true);
  await expect(field).toHaveValue('正在输入中文');
  await field.dispatchEvent('compositionend', { data: '正在输入中文' });
  await expect(field).toHaveValue('正在输入中文');
  await expect(field).toBeFocused();
});

test('多选与失败回传保持请求；重复点击不会重复发送', async ({ page }) => {
  await mountHarness(page);
  await page.getByText('窗口', { exact: true }).click();
  await page.getByText('桥接', { exact: true }).click();
  await page.evaluate(() => {
    const harness = (window as unknown as { __islandTest: { rejectResponse: boolean; responseDelay: number } }).__islandTest;
    harness.rejectResponse = true; harness.responseDelay = 200;
  });
  await page.getByRole('button', { name: '发送回答', exact: true }).click();
  await expect(page.getByRole('button', { name: '发送回答', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: '发送回答', exact: true }).dispatchEvent('click');
  await expect(page.getByRole('alert')).toHaveText('模拟连接已断开');
  await expect(page.locator('.interaction-question')).toHaveCount(1);
  expect(await page.evaluate(() => (window as unknown as { __islandTest: { calls: unknown[] } }).__islandTest.calls.length)).toBe(1);
  await capture(page, 'ui-multiple-response-failed.png');
});

test('IME 期间请求断开，旧输入卡片不能发送已经失效的请求', async ({ page }) => {
  await mountHarness(page);
  const field = page.getByRole('textbox', { name: '自定义回答', exact: true });
  await field.fill('只提交仍然有效的请求');
  await field.dispatchEvent('compositionstart', { data: '输入中' });
  await page.evaluate(() => {
    const harness = (window as unknown as { __islandTest: { store: { snapshot(): { sessions: Array<{ pendingInteractions: Array<{ transportRequestId: string }> }> }; endTransport(id: string, error: string): void } } }).__islandTest;
    const id = harness.store.snapshot().sessions[0].pendingInteractions[0].transportRequestId;
    harness.store.endTransport(id, '输入期间连接已断开');
  });
  await page.getByRole('button', { name: '发送回答', exact: true }).click();
  expect(await page.evaluate(() => (window as unknown as { __islandTest: { calls: unknown[] } }).__islandTest.calls.length)).toBe(0);
  await field.dispatchEvent('compositionend', { data: '只提交仍然有效的请求' });
  await expect(page.getByRole('alert')).toHaveText('输入期间连接已断开');
  await expect(field).toHaveValue('只提交仍然有效的请求');
});

test('成功响应等待平台确认，未确认前待办保持发送中', async ({ page }) => {
  await mountHarness(page);
  await page.getByRole('textbox', { name: '自定义回答', exact: true }).fill('确认桥接实际接收后再完成');
  await page.evaluate(() => {
    (window as unknown as { __islandTest: { responseDelay: number } }).__islandTest.responseDelay = 500;
  });
  await page.getByRole('button', { name: '发送回答', exact: true }).click();
  await expect(page.locator('.interaction-question')).toHaveCount(1);
  await expect(page.getByText('正在发送…', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: '发送回答', exact: true })).toBeDisabled();
  await expect(page.locator('.interaction-question')).toHaveCount(0);
});

test('五种语言立即切换并持久化，不翻译 Agent 原文', async ({ page }) => {
  await page.goto('/?fixture=sessions&settings=1');
  for (const [language, title, pane] of [
    ['en','X Island Settings','General'],['ja','X Island 設定','一般'],['ko','X Island 설정','일반'],['fr','Réglages X Island','Général'],['zh','X Island 设置','通用'],
  ]) {
    await page.locator('.setting-row select').first().selectOption(language);
    await expect(page.locator('.settings-heading strong')).toHaveText(title);
    await expect(page.getByRole('button',{name:pane,exact:true})).toBeVisible();
  }
  await page.locator('.setting-row select').first().selectOption('en');
  await page.reload();
  await expect(page.locator('.settings-heading strong')).toHaveText('X Island Settings');
  await capture(page,'ui-settings-english.png');
  await page.getByRole('button',{name:'Back to island',exact:true}).click();
  await expect(page.getByText('Implement diagnostics',{exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'Settings',exact:true})).toBeVisible();
  await capture(page,'ui-expanded-english.png');
});

test('系统语言匹配日语，显式语言覆盖后可回到系统', async ({ page }) => {
  await page.addInitScript(() => { Object.defineProperty(navigator,'languages',{get:()=>['ja-JP','en-US']}); });
  await page.goto('/?settings=1');
  await expect(page.locator('.settings-heading strong')).toHaveText('X Island 設定');
  await page.locator('.setting-row select').first().selectOption('fr');
  await expect(page.locator('.settings-heading strong')).toHaveText('Réglages X Island');
  await capture(page,'ui-settings-french.png');
  await page.locator('.setting-row select').first().selectOption('system');
  await expect(page.locator('.settings-heading strong')).toHaveText('X Island 設定');
  await capture(page,'ui-settings-japanese.png');
});

test('独立设置调用不放大主岛，副窗口关闭与广播更新不回写', async ({ page }) => {
  await mountHarness(page,{externalSettings:true});
  const size=await page.locator('.island-shell').boundingBox();
  await page.getByRole('button',{name:'设置',exact:true}).click();
  await expect(page.locator('.settings-window')).toHaveCount(0);
  expect((await page.locator('.island-shell').boundingBox())?.width).toBe(size?.width);
  expect(await page.evaluate(()=>(window as unknown as {__islandTest:{calls:unknown[]}}).__islandTest.calls)).toEqual([{kind:'openSettings',pane:'general'}]);
  await mountHarness(page,{preferencesWindow:true});
  await expect(page.locator('.island-shell')).toHaveCSS('width','760px');
  await page.evaluate(async()=>{
    const settingsPath='/src/ui/settings.ts';const {DEFAULT_SETTINGS}=await import(settingsPath);
    (window as unknown as {__islandTest:{ui:{applySettings(settings:unknown):void}}}).__islandTest.ui.applySettings({...DEFAULT_SETTINGS,language:'ko'});
  });
  await expect(page.locator('.settings-heading strong')).toHaveText('X Island 설정');
  expect(await page.evaluate(()=>(window as unknown as {__islandTest:{calls:unknown[]}}).__islandTest.calls.length)).toBe(0);
  await capture(page,'ui-settings-korean.png');
  await page.getByRole('button',{name:'설정 닫기',exact:true}).click();
  await expect(page.locator('.island-shell')).toHaveCSS('width','760px');
  expect(await page.evaluate(()=>(window as unknown as {__islandTest:{calls:unknown[]}}).__islandTest.calls)).toEqual([{kind:'closeSettings'}]);
});

test('设置平台写入失败时不显示为已保存', async ({ page }) => {
  await mountHarness(page,{preferencesWindow:true});
  await page.evaluate(()=>(window as unknown as {__islandTest:{rejectSettings:boolean}}).__islandTest.rejectSettings=true);
  await page.locator('.setting-row select').first().selectOption('fr');
  await expect(page.getByRole('status')).toHaveText('Settings write rejected');
  await expect(page.locator('.settings-heading strong')).toHaveText('X Island 设置');
  await expect(page.locator('.setting-row select').first()).toHaveValue('system');
});

test('强度设置与果冻磁吸实际生效，减少动效关闭持续运动', async ({ page }) => {
  await page.emulateMedia({reducedMotion:'no-preference'});
  await page.goto('/?fixture=sessions&settings=1');
  await page.getByRole('button',{name:'显示',exact:true}).click();
  await page.getByRole('combobox',{name:'动画强度',exact:true}).selectOption('high');
  await page.getByRole('combobox',{name:'果冻强度',exact:true}).selectOption('strong');
  await page.locator('.settings-content').evaluate(node=>node.scrollTo({top:node.scrollHeight}));
  await capture(page,'ui-motion-settings.png');
  await page.getByRole('button',{name:'返回灵动岛',exact:true}).click();
  await page.getByRole('button',{name:'收起',exact:true}).click();
  await expect(page.locator('.island-shell')).toHaveCSS('height','60.7656px');
  await page.mouse.move(500,100);await page.mouse.move(510,20);
  await expect.poll(()=>page.locator('.island-shell').evaluate(node=>node.getAnimations().some(animation=>animation.effect instanceof KeyframeEffect && animation.effect.getKeyframes().some(frame=>String(frame.transform).includes('scale'))))).toBe(true);
  await expect.poll(()=>page.locator('.collapsed-body').evaluate(node=>getComputedStyle(node).transform)).not.toBe('none');
  await page.getByRole('button',{name:'展开 XIsland',exact:true}).click();
  await page.getByRole('button',{name:'设置',exact:true}).click();
  await page.getByRole('button',{name:'显示',exact:true}).click();
  await page.getByRole('checkbox',{name:'减少动态效果',exact:true}).check();
  await page.getByRole('button',{name:'返回灵动岛',exact:true}).click();
  await page.getByRole('button',{name:'收起',exact:true}).click();
  await expect(page.locator('.island-shell')).toHaveCSS('height','60.7656px');
  await page.mouse.move(500,100);await page.mouse.move(510,20);
  expect(await page.locator('.island-shell').evaluate(node=>node.getAnimations().some(animation=>animation.effect instanceof KeyframeEffect && animation.effect.getKeyframes().some(frame=>String(frame.transform).includes('scale'))))).toBe(false);
});

test('独立设置副本不响应审批快捷键，也不在新待办时播放通知', async ({ page }) => {
  await mountHarness(page,{preferencesWindow:true});
  await page.locator('.island-shell').focus();
  await page.keyboard.press('Control+y');
  await page.keyboard.press('Control+1');
  expect(await page.evaluate(()=>(window as unknown as {__islandTest:{calls:unknown[]}}).__islandTest.calls.length)).toBe(0);
  await expect(page.locator('.settings-window')).toHaveCount(1);
});

test('声音页提供11事件开关和音量，独立设置试听只请求主窗口', async ({ page }) => {
  await page.goto('/?settings=1');
  await page.getByRole('button', { name: '声音', exact: true }).click();
  await expect(page.getByRole('button', { name: /^试听 / })).toHaveCount(11);
  await expect(page.getByRole('checkbox', { name: '任务开始', exact: true })).not.toBeChecked();
  await page.getByRole('checkbox', { name: '任务开始', exact: true }).check();
  await page.getByRole('slider', { name: '音量', exact: true }).fill('0.2');
  await page.getByRole('slider', { name: '音量', exact: true }).dispatchEvent('change');
  await page.reload();
  await page.getByRole('button', { name: '声音', exact: true }).click();
  await expect(page.getByRole('checkbox', { name: '任务开始', exact: true })).toBeChecked();
  await expect(page.getByRole('slider', { name: '音量', exact: true })).toHaveValue('0.2');
  await capture(page, 'ui-sound-events.png');
  await page.evaluate(async () => {
    const coreUrl = '/src/core/index.ts', uiUrl = '/src/ui/index.ts';
    const { SessionStore } = await import(coreUrl) as typeof import('../src/core/index');
    const { mountIsland } = await import(uiUrl) as typeof import('../src/ui/index');
    const target = document.createElement('div'); document.body.replaceChildren(target);
    let created = 0; const requested: string[] = [];
    Object.defineProperty(window, 'AudioContext', { configurable: true, value: class { constructor() { created++; throw new Error('Preferences must not initialize audio'); } } });
    mountIsland(target, new SessionStore({ readOnly: true }), {
      preview: false, preferencesWindow: true, initialSettingsPane: 'sound', nativeAutoplayAudio: true,
      resize: async () => {}, focus: async () => {}, respond: async () => {}, jump: async () => {}, exportHistory: async () => {},
      previewSound: async (event: string) => { requested.push(event); },
    });
    (window as unknown as { __soundTest: { requested: string[]; created: () => number } }).__soundTest = { requested, created: () => created };
  });
  await page.getByRole('button', { name: '试听 已允许', exact: true }).click();
  expect(await page.evaluate(() => (window as unknown as { __soundTest: { requested: string[] } }).__soundTest.requested)).toEqual(['approved']);
  expect(await page.evaluate(() => (window as unknown as { __soundTest: { created: () => number } }).__soundTest.created())).toBe(0);
});

test('顶部拖动只在超过阈值后调用原生层，拖动不触发普通展开点击', async ({ page }) => {
  await page.goto('/');
  await page.evaluate(async () => {
    const dragUrl = '/src/platform/native-drag.ts';
    const { installNativeDrag } = await import(dragUrl) as typeof import('../src/platform/native-drag');
    const root = document.createElement('div'); root.id = 'drag-test';
    root.innerHTML = '<button class="collapsed-button" style="width:260px;height:60px">Drag</button>';
    document.body.replaceChildren(root);
    const phases: string[] = []; let clicks = 0;
    root.querySelector('button')!.addEventListener('click', () => { clicks++; });
    installNativeDrag(root, async (phase: string) => { phases.push(phase); }, (error: unknown) => { throw error; });
    (window as unknown as { __dragTest: { phases: string[]; clicks: () => number } }).__dragTest = { phases, clicks: () => clicks };
  });
  await page.getByRole('button', { name: 'Drag' }).click();
  expect(await page.evaluate(() => (window as unknown as { __dragTest: { phases: string[] } }).__dragTest.phases)).toEqual([]);
  await page.mouse.move(100, 30); await page.mouse.down(); await page.mouse.move(145, 30, { steps: 5 }); await page.mouse.up();
  await expect.poll(() => page.evaluate(() => (window as unknown as { __dragTest: { phases: string[] } }).__dragTest.phases.at(-1))).toBe('end');
  expect(await page.evaluate(() => (window as unknown as { __dragTest: { phases: string[] } }).__dragTest.phases[0])).toBe('begin');
  expect(await page.evaluate(() => (window as unknown as { __dragTest: { clicks: () => number } }).__dragTest.clicks())).toBe(1);
});

test('关闭动画立即切换并持久化，界面状态仍继续更新', async ({ page }) => {
  await page.emulateMedia({reducedMotion:'no-preference'});
  await page.goto('/?fixture=sessions&settings=1');
  await page.getByRole('button',{name:'显示',exact:true}).click();
  await page.getByRole('checkbox',{name:'关闭所有动画',exact:true}).check();
  await page.getByRole('button',{name:'返回灵动岛',exact:true}).click();
  await page.getByRole('button',{name:'收起',exact:true}).click();
  await expect(page.locator('.island-shell')).toHaveCSS('height','60.7656px');
  expect(await page.locator('.island-shell').evaluate(node=>node.getAnimations().length)).toBe(0);
  await page.getByRole('button',{name:'展开 XIsland',exact:true}).click();
  await expect(page.getByText('Implement diagnostics',{exact:true})).toBeVisible();
  await page.reload();
  await page.getByRole('button',{name:'显示',exact:true}).click();
  await expect(page.getByRole('checkbox',{name:'关闭所有动画',exact:true})).toBeChecked();
});

test('Agents接入先预览路径与备份，再确认应用并刷新真实状态', async ({ page }) => {
  await mountHarness(page,{preferencesWindow:true,integrations:true});
  await page.getByRole('button',{name:'Agents',exact:true}).click();
  const claude=page.locator('[data-integration-agent="claude_code"]');
  await expect(claude.getByText('未配置',{exact:true})).toBeVisible();
  await expect(page.locator('[data-integration-agent="codex"]').getByText('需更新',{exact:true})).toBeVisible();
  await expect(page.locator('[data-integration-agent="cursor"]').getByText('缺少运行时',{exact:true})).toBeVisible();
  await expect(page.locator('[data-integration-agent="gemini_cli"]').getByText('当前平台不可用',{exact:true})).toBeVisible();
  await expect(page.locator('[data-integration-agent="cursor"]').getByRole('button',{name:'更新接入…',exact:true})).toBeDisabled();
  await claude.getByRole('button',{name:'启用接入…',exact:true}).click();
  await expect(page.getByRole('heading',{name:'确认启用或更新 Claude',exact:true})).toBeVisible();
  await expect(page.getByText('C:/Users/Demo/.claude/settings.json',{exact:true})).toBeVisible();
  await expect(page.getByText('写入前在原目录创建带时间戳的独立备份。',{exact:true})).toBeVisible();
  await expect(page.getByText('Mock warning: existing user hooks are preserved.',{exact:true})).toBeVisible();
  expect(await page.evaluate(()=>(window as unknown as {__islandTest:{integrationCalls:Array<{action:string}>}}).__islandTest.integrationCalls.filter(call=>call.action==='apply').length)).toBe(0);
  await capture(page,'ui-integration-review-mock.png');
  await page.getByRole('button',{name:'确认应用变更',exact:true}).click();
  await expect(claude.getByText('已配置',{exact:true})).toBeVisible();
  await expect(claude.getByText('实际客户端未验收',{exact:true})).toBeVisible();
  await expect(claude.getByText('配置变更已写入；请在原客户端确认信任并验证事件。',{exact:true})).toBeVisible();
  const applied=await page.evaluate(()=>(window as unknown as {__islandTest:{integrationCalls:Array<{action:string;operation?:string;revision?:string}>}}).__islandTest.integrationCalls.filter(call=>call.action==='apply'));
  expect(applied).toHaveLength(1);expect(applied[0].revision).toBe('a'.repeat(64));
  await claude.getByRole('button',{name:'移除接入…',exact:true}).click();
  await expect(page.getByRole('heading',{name:'确认移除 Claude',exact:true})).toBeVisible();
  await page.getByRole('button',{name:'确认应用变更',exact:true}).click();
  await expect(claude.getByText('未配置',{exact:true})).toBeVisible();
});

test('配置冲突保留错误并禁用旧确认，重新预览才能再次提交', async ({ page }) => {
  await mountHarness(page,{preferencesWindow:true,integrations:true});
  await page.getByRole('button',{name:'Agents',exact:true}).click();
  const claude=page.locator('[data-integration-agent="claude_code"]');
  await claude.getByRole('button',{name:'启用接入…',exact:true}).click();
  await page.evaluate(()=>(window as unknown as {__islandTest:{integrationConflict:boolean}}).__islandTest.integrationConflict=true);
  await page.getByRole('button',{name:'确认应用变更',exact:true}).click();
  await expect(page.getByRole('alert')).toContainText('revision_conflict');
  await expect(page.getByRole('button',{name:'确认应用变更',exact:true})).toBeDisabled();
  await capture(page,'ui-integration-conflict-mock.png');
  await page.evaluate(()=>{const harness=(window as unknown as {__islandTest:{integrationConflict:boolean;integrationRevision:string}}).__islandTest;harness.integrationConflict=false;harness.integrationRevision='b'.repeat(64);});
  await page.getByRole('button',{name:'重新检查计划',exact:true}).click();
  await expect(page.getByRole('button',{name:'确认应用变更',exact:true})).toBeEnabled();
  await page.getByRole('button',{name:'确认应用变更',exact:true}).click();
  await expect(claude.getByText('已配置',{exact:true})).toBeVisible();
  expect(await page.evaluate(()=>(window as unknown as {__islandTest:{integrationCalls:Array<{action:string;revision:string}>}}).__islandTest.integrationCalls.filter(call=>call.action==='apply').map(call=>call.revision))).toEqual(['a'.repeat(64),'b'.repeat(64)]);
});

test('普通浏览器预览不会假装能够安装接入', async ({ page }) => {
  await page.goto('/?settings=1');
  await page.getByRole('button',{name:'Agents',exact:true}).click();
  await expect(page.getByText('浏览器预览不安装或移除接入，请在 Windows 客户端操作。',{exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'启用接入…',exact:true})).toHaveCount(0);
  await expect(page.getByText('实际客户端未验收',{exact:true})).toHaveCount(15);
  await expect(page.getByRole('button',{name:'导出 WorkBuddy 插件…',exact:true})).toHaveCount(0);
});

test('WorkBuddy导出不假装安装，TraeWork与TRAE国内版只有一个配置入口', async ({ page }) => {
  await mountHarness(page,{preferencesWindow:true,integrations:true});
  await page.getByRole('button',{name:'Agents',exact:true}).click();
  const workbuddy=page.locator('[data-integration-agent="workbuddy"]');
  await expect(workbuddy.getByText('观察模式',{exact:true})).toBeVisible();
  await workbuddy.getByRole('button',{name:'导出 WorkBuddy 插件…',exact:true}).click();
  await expect(workbuddy.getByText('C:/Users/Demo/XIsland-Plugins/workbuddy-test',{exact:true})).toBeVisible();
  await expect(workbuddy.getByText('实际客户端未验收',{exact:true})).toBeVisible();
  await expect(workbuddy.getByText('已配置',{exact:true})).toHaveCount(0);
  await expect(page.locator('[data-integration-agent="trae_cn"]')).toHaveCount(1);
  await expect(page.getByText('TRAE CN / TraeWork CN',{exact:true})).toBeVisible();
  await expect(page.getByText('C:/Users/Demo/.trae-cn/hooks.json',{exact:true})).toBeVisible();
  const calls=await page.evaluate(()=>(window as unknown as {__islandTest:{integrationCalls:Array<{action:string;agent:string}>}}).__islandTest.integrationCalls.filter(call=>call.agent==='workbuddy'));
  expect(calls).toEqual([{action:'export',agent:'workbuddy'}]);
  await capture(page,'ui-workbuddy-export-mock.png');
});

test('识别后的TraeWork和Trae IDE在共享配置下分别显示来源', async ({ page }) => {
  await mountHarness(page,{preferencesWindow:true,integrations:true});
  await page.evaluate(() => {
    const store=(window as unknown as {__islandTest:{store:{apply(value:unknown):unknown}}}).__islandTest.store;
    for (const agent of ['trae_ide_cn','traework_cn']) store.apply({type:'session_start',agentType:agent,sessionId:`${agent}-same`,
      timestamp:new Date().toISOString(),prompt:'来源识别样例'});
  });
  await page.getByRole('button',{name:'Agents',exact:true}).click();
  await expect(page.locator('.agent-setting-row').getByText('Trae CN',{exact:true})).toBeVisible();
  await expect(page.locator('.agent-setting-row').getByText('TraeWork CN',{exact:true})).toBeVisible();
  await expect(page.locator('[data-integration-agent="trae_cn"]')).toHaveCount(1);
  await page.locator('.agent-setting-row').getByText('TraeWork CN',{exact:true}).scrollIntoViewIfNeeded();
  await capture(page,'ui-traework-origin-mock.png');
});

test('运行时不可用时配置状态保持未知，不误报为未配置', async ({ page }) => {
  await mountHarness(page,{preferencesWindow:true,integrations:true,unknownRuntime:true});
  await page.getByRole('button',{name:'Agents',exact:true}).click();
  await expect(page.getByText('运行时未就绪，配置状态未知',{exact:true})).toHaveCount(13);
  await expect(page.getByText('未配置',{exact:true})).toHaveCount(0);
  for(const agent of ['claude_code','codex','cursor','gemini_cli','windsurf','trae_cn'])await expect(page.locator(`[data-integration-agent="${agent}"]`).getByRole('button',{name:'启用接入…',exact:true})).toBeDisabled();
});

test('新增接入均有配置入口，授权未完成时不显示旧活动证据', async ({page})=>{
  await mountHarness(page,{preferencesWindow:true,integrations:true,connectionEvidence:true});
  await page.getByRole('button',{name:'Agents',exact:true}).click();
  for(const agent of ['qwen','code_buddy','droid','opencode','kimi_code'])await expect(page.locator(`[data-integration-agent="${agent}"]`)).toHaveCount(1);
  const qwen=page.locator('[data-integration-agent="qwen"]'),codex=page.locator('[data-integration-agent="codex"]');
  await expect(qwen.getByText('检测到客户端',{exact:true})).toBeVisible();
  await expect(qwen.getByText(/当前配置最近收到事件/)).toHaveCount(1);
  await expect(codex.getByText('需要在 Codex 中授权',{exact:true})).toBeVisible();
  await expect(codex.getByText(/当前配置最近收到事件/)).toHaveCount(0);
  await page.locator('[data-integration-agent="opencode"]').getByRole('button',{name:'启用接入…',exact:true}).click();
  await expect(page.getByRole('heading',{name:'确认启用或更新 OpenCode',exact:true})).toBeVisible();
  await page.getByRole('button',{name:'确认应用变更',exact:true}).click();
  await expect(page.locator('[data-integration-agent="opencode"]').getByText('已配置',{exact:true})).toBeVisible();
  await qwen.scrollIntoViewIfNeeded();await capture(page,'ui-agent-discovery-mock.png');
});

test('后台任务失败和未确认在活动及详情中不显示成功勾', async ({page})=>{
  await mountHarness(page);
  await page.evaluate(async()=>{
    const store=(window as unknown as {__islandTest:{store:{loadFixture(value:unknown):void;apply(value:unknown):{accepted:boolean;reason?:string};snapshot():{sessions:Array<{backgroundTasks:unknown[]}>}}}}).__islandTest.store;
    const adapterPath='/src/adapters/kimi-code.ts';const {normalizeKimiCodeHook}=await import(adapterPath);
    const fixture=await(await fetch('/src/fixtures/companion/kimi-code-hooks.json')).json();
    const send=(event:string,patch:Record<string,unknown>={})=>{const result=store.apply(normalizeKimiCodeHook({...fixture.cases.find((row:{event:string})=>row.event===event).input,...patch}));if(!result.accepted)throw new Error(`${event}: ${result.reason}`);};
    store.loadFixture({sessions:[]});send('SessionStart');send('TurnStarted');
    send('TaskStarted',{task_id:'failed-task',description:'失败任务'});send('TaskStarted',{task_id:'unknown-task',description:'未确认任务'});
    send('Notification',{source_id:'failed-task',notification_type:'task.failed'});
    send('Notification',{source_id:'unknown-task',notification_type:'task.lost'});
    if(store.snapshot().sessions[0]?.backgroundTasks.length!==2)throw new Error('Task projection: '+JSON.stringify(store.snapshot()));
  });
  await page.getByRole('button',{name:'展开活动记录',exact:true}).click();
  await expect(page.locator('.activity-row .tool-outcome')).toHaveText(['✕','?']);
  await capture(page,'ui-kimi-task-outcomes-mock.png');
});

test('独立设置按小屏可用区域适配，工具栏可横滚且关闭按钮始终可用', async ({ page }) => {
  await page.setViewportSize({width:640,height:480});
  await mountHarness(page,{preferencesWindow:true});
  await expect(page.locator('.island-shell')).toHaveCSS('width','640px');
  await expect(page.locator('.island-shell')).toHaveCSS('height','480px');
  await expect(page.getByRole('button',{name:'关闭设置',exact:true})).toBeInViewport();
  await capture(page,'ui-preferences-640x480.png');
  await page.setViewportSize({width:420,height:360});
  await expect(page.locator('.island-shell')).toHaveCSS('width','420px');
  await expect(page.locator('.island-shell')).toHaveCSS('height','360px');
  const toolbar=page.locator('.settings-tabs');
  expect(await toolbar.evaluate(node=>node.scrollWidth>node.clientWidth)).toBe(true);
  await page.getByRole('button',{name:'关于',exact:true}).click();
  await expect(page.getByRole('button',{name:'关于',exact:true})).toBeInViewport();
  await expect(page.getByRole('button',{name:'关闭设置',exact:true})).toBeInViewport();
  expect(await page.locator('.settings-content').evaluate(node=>node.scrollHeight>node.clientHeight)).toBe(true);
  await capture(page,'ui-preferences-420x360.png');
  await page.getByRole('button',{name:'关闭设置',exact:true}).click();
  expect(await page.evaluate(()=>(window as unknown as {__islandTest:{calls:unknown[]}}).__islandTest.calls)).toEqual([{kind:'closeSettings'}]);
});

type ParityHarness = {
  store: import('../src/core/session-store').SessionStore;
  ui: ReturnType<typeof import('../src/ui/index').mountIsland>;
  notifications: string[];
  advance(ms: number): void;
  send(patch?: Partial<import('../src/core/protocol').DIMessage>): void;
};

async function mountParityHarness(page: Page, preferencesWindow = false) {
  await page.goto('/');
  await page.evaluate(async preferencesWindow => {
    const corePath = '/src/core/session-store.ts', uiPath = '/src/ui/index.ts';
    const { SessionStore } = await import(corePath), { mountIsland } = await import(uiPath);
    let now = Date.parse('2026-10-17T10:00:00Z'), mono = 0;
    const store = new SessionStore({ now: () => now, monotonicNow: () => mono });
    const notifications: string[] = [];
    const target = document.createElement('div'); target.id = 'app'; document.body.replaceChildren(target);
    const ui = mountIsland(target, store, { preview: false, preferencesWindow,
      resize: async () => {}, focus: async () => {}, respond: async () => {}, jump: async () => {}, exportHistory: async () => {},
      notify: (kind: string) => notifications.push(kind) });
    (window as unknown as { __parityTest: ParityHarness }).__parityTest = { store, ui, notifications,
      advance(ms) { now += ms; mono += ms; },
      send(patch = {}) {
        const result = store.apply({ type: 'status_update', sessionId: 'claude_code-parity', agentType: 'claude_code',
          timestamp: new Date(now).toISOString(), status: '相同的最终内容', statusIsAssistantReply: true, observedState: 'idle',
          nativeMessageId: 'reply-1', ...patch });
        if (!result.accepted) throw new Error(result.reason);
      } };
  }, preferencesWindow);
}

test('Mac 行为对齐：累计统计合并观察片段，历史按结束日期显示', async ({ page }, testInfo) => {
  await mountParityHarness(page, true);
  await page.evaluate(() => {
    const { store, ui } = (window as unknown as { __parityTest: ParityHarness }).__parityTest;
    store.loadFixture({ sessions: [{ id: 'earlier', agentType: 'roo_code', status: 'completed', prompt: '较早完成' },
      { id: 'later', agentType: 'roo_code', status: 'observationUnavailable', prompt: '较晚中断' }] });
    const sessions = store.snapshot().sessions, epoch = Date.parse('2026-10-17T10:00:00Z');
    for (const [index, session] of sessions.entries()) {
      session.startedAt = epoch + index * 30_000; session.lastActivityAt = epoch + (1 - index) * 50_000;
      session.sourceNamespace = 'a'.repeat(24); session.sourceInstanceId = `instance-${index}`; session.nativeTaskId = 'same-task';
      session.usage = { inputTokens: index ? 120 : 100, outputTokens: index ? 30 : 0, totalTokens: 0, costUSD: index ? 1.5 : 1, model: '' };
      if (index) { delete session.completedAt; session.observationEndedAt = epoch + 90_000; }
      else session.completedAt = epoch + 60_000;
    }
    store.restore(JSON.stringify({ version: 1, sessions })); ui.showSettings('statistics');
  });
  const stat = (label: string) => page.locator('.stat-card').filter({ has: page.getByText(label, { exact: true }) }).locator('strong');
  await expect(stat('会话')).toHaveText('1'); await expect(stat('输入 token')).toHaveText('120');
  await expect(stat('输出 token')).toHaveText('30'); await expect(stat('总 token')).toHaveText('150');
  await expect(stat('已上报费用')).toHaveText('$1.5000'); await expect(stat('总时长')).toHaveText('1m');
  await page.locator('.island-shell').screenshot({ path: testInfo.outputPath('mac-parity-statistics.png') });
  await page.getByRole('button', { name: '历史', exact: true }).click();
  await expect(page.locator('.history-row strong')).toHaveText(['较晚中断', '较早完成']);
  await expect(page.locator('.history-date').first()).toContainText('观测中断于');
  await expect(page.locator('.history-date').first()).toHaveAttribute('datetime', '2026-10-17T10:01:30.000Z');
  await expect(page.locator('.history-date').last()).toContainText('已完成于');
  await page.locator('.island-shell').screenshot({ path: testInfo.outputPath('mac-parity-history.png') });
});

test('Mac 行为对齐：模型名称在卡片与详情显示，长名称截断且保留完整提示', async ({ page }, testInfo) => {
  await mountParityHarness(page);
  const model = `model-${'long-name-'.repeat(15)}<script>text only</script>`;
  await page.evaluate(model => {
    const { store, ui, send } = (window as unknown as { __parityTest: ParityHarness }).__parityTest;
    store.loadFixture({ sessions: [{ id: 'claude_code-parity', agentType: 'claude_code', status: 'active', prompt: '包含模型' },
      { id: 'codex-empty', agentType: 'codex', status: 'active', prompt: '没有模型' }] });
    send({ model, status: undefined, statusIsAssistantReply: false, observedState: undefined }); ui.expand();
  }, model);
  const card = page.locator('[data-session-id="claude_code-parity"]');
  await expect(card.locator('.session-model')).toHaveText(model); await expect(card.locator('.session-model')).toHaveAttribute('title', model);
  await expect(page.locator('[data-session-id="codex-empty"] .session-model')).toHaveCount(0);
  expect(await card.locator('.session-model').evaluate(node => node.scrollWidth > node.clientWidth)).toBe(true);
  await expect(card.locator('.session-model')).toHaveCSS('text-overflow', 'ellipsis');
  await card.getByRole('button', { name: '查看活动与对话', exact: true }).click();
  await expect(page.locator('.detail-heading .session-model')).toHaveText(model);
  await expect(page.locator('.detail-heading .session-model')).toHaveAttribute('title', model);
  expect(await page.locator('.detail-heading').evaluate(node => node.scrollWidth <= node.clientWidth)).toBe(true);
  await page.locator('.island-shell').screenshot({ path: testInfo.outputPath('mac-parity-model.png') });
});

test('Mac 行为对齐：最终回复完成音来自核心事件，静音与设置窗口仍抑制通知', async ({ page }) => {
  await mountParityHarness(page);
  const notifications = () => page.evaluate(() => (window as unknown as { __parityTest: ParityHarness }).__parityTest.notifications);
  await page.evaluate(() => {
    const { send } = (window as unknown as { __parityTest: ParityHarness }).__parityTest;
    send({ nativeMessagePartial: true }); send({ nativeMessageReplay: true });
  });
  expect(await notifications()).toEqual([]);
  await page.evaluate(() => (window as unknown as { __parityTest: ParityHarness }).__parityTest.send());
  expect(await notifications()).toEqual(['session_end']);
  await page.evaluate(() => {
    const { send, advance } = (window as unknown as { __parityTest: ParityHarness }).__parityTest;
    advance(1799); send({ nativeMessageId: 'reply-2' }); advance(1); send({ nativeMessageId: 'reply-3' });
    advance(1800); send({ nativeMessageId: 'reply-1' });
  });
  expect(await notifications()).toEqual(['session_end', 'session_end']);
  await page.evaluate(async () => {
    const settingsPath = '/src/ui/settings.ts', { DEFAULT_SETTINGS } = await import(settingsPath);
    const { send, ui, advance } = (window as unknown as { __parityTest: ParityHarness }).__parityTest;
    ui.applySettings({ ...DEFAULT_SETTINGS, soundEnabled: false }); advance(1800); send({ nativeMessageId: 'muted-reply' });
    ui.applySettings({ ...DEFAULT_SETTINGS, eventSounds: { ...DEFAULT_SETTINGS.eventSounds, session_end: false } });
    advance(1800); send({ nativeMessageId: 'disabled-event' });
    const start = new Date(Date.now() - 300_000), end = new Date(Date.now() + 300_000);
    ui.applySettings({ ...DEFAULT_SETTINGS, quietHours: true, quietStart: start.toTimeString().slice(0, 5), quietEnd: end.toTimeString().slice(0, 5) });
    advance(1800); send({ nativeMessageId: 'quiet-reply' });
  });
  expect(await notifications()).toEqual(['session_end', 'session_end']);
  await mountParityHarness(page, true);
  await page.evaluate(() => (window as unknown as { __parityTest: ParityHarness }).__parityTest.send());
  expect(await notifications()).toEqual([]);
});
