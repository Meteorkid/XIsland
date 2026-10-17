import { t } from './i18n';
export function el<K extends keyof HTMLElementTagNameMap>(tag: K, className = '', text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function button(label: string, className: string, action: () => void, glyph?: string): HTMLButtonElement {
  const node = el('button', className);
  node.type = 'button';
  node.title = label;
  node.setAttribute('aria-label', label);
  if (glyph) node.append(icon(glyph));
  else node.textContent = label;
  node.addEventListener('click', action);
  return node;
}

const paths: Record<string, string> = {
  sound: 'M11 5 6 9H3v6h3l5 4V5m4 3a6 6 0 0 1 0 8m3-11a10 10 0 0 1 0 14',
  mute: 'M11 5 6 9H3v6h3l5 4V5m5 4 5 6m0-6-5 6',
  settings: 'm9 3-.5 3-2 1.2L4 6l-2 4 2.3 2v2L2 16l2 4 2.5-1.2L9 20l.5 2h5l.5-2 2.5-1.2L20 20l2-4-2.3-2v-2L22 10l-2-4-2.5 1.2-2-1.2-.5-3H9m7 9a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
  close: 'm7 7 10 10M17 7 7 17',
  search: 'm16 16 5 5M18 10A8 8 0 1 1 2 10a8 8 0 0 1 16 0',
  filter: 'M3 5h18M6 12h12M9 19h6',
  jump: 'M14 3h7v7m0-7L10 14M10 4H4v16h16v-6',
  chevron: 'm6 9 6 6 6-6',
  clock: 'M12 8v5l3 2m7-3a10 10 0 1 1-20 0 10 10 0 0 1 20 0',
  check: 'm4 12 5 5L20 6',
  warning: 'M12 3 2 21h20L12 3m0 6v5m0 3v1',
  question: 'M9 8a3 3 0 1 1 5 2c-2 1-2 2-2 4m0 3v1m10-6a10 10 0 1 1-20 0 10 10 0 0 1 20 0',
  plan: 'M5 2h10l4 4v16H5V2m10 0v5h4M8 11h8M8 15h8M8 19h5',
  history: 'M3 4v6h6M3 10a9 9 0 1 1 1 8m8-12v6l4 2',
  download: 'M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5',
  chart: 'M4 20V10m8 10V4m8 16v-7',
  flow: 'M12 3v5m-7 5V8h14v5M5 17v4m14-4v4M2 13h6v4H2v-4m14 0h6v4h-6v-4',
  moon: 'M20 15A9 9 0 0 1 9 3a9 9 0 1 0 11 12',
  sun: 'M12 2v2m0 16v2M2 12h2m16 0h2M5 5l2 2m10 10 2 2M5 19l2-2M17 7l2-2m-2 7a5 5 0 1 1-10 0 5 5 0 0 1 10 0',
  screen: 'M2 3h20v14H2V3m10 14v4m-5 0h10',
  terminal: 'm4 7 5 5-5 5m8 0h8',
  trash: 'M3 6h18M8 6V3h8v3M5 6l1 15h12l1-15M10 10v7m4-7v7',
  info: 'M12 10v7m0-10v1m10 4a10 10 0 1 1-20 0 10 10 0 0 1 20 0',
  copy: 'M9 9h12v12H9V9M5 15H3V3h12v2',
};

export function icon(name: string): SVGSVGElement {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.7');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(svg.namespaceURI, 'path');
  path.setAttribute('d', paths[name] ?? paths.info);
  svg.append(path);
  return svg;
}

const names: Record<string, string> = {
  claude_code: 'Claude', 'claude-code': 'Claude', claudeCode: 'Claude', claude: 'Claude', codex: 'Codex',
  cursor: 'Cursor', gemini_cli: 'Gemini', geminiCli: 'Gemini', 'gemini-cli': 'Gemini', opencode: 'OpenCode',
  trae: 'TRAE CN / TraeWork CN', trae_cn: 'TRAE CN / TraeWork CN', trae_ide_cn: 'Trae CN', traework_cn: 'TraeWork CN',
  workbuddy: 'WorkBuddy', copilot: 'Copilot', windsurf: 'Windsurf', deepseek: 'DeepSeek', kimi: 'Kimi',
  kimi_code: 'Kimi Code', qwen: 'Qwen Code', code_buddy: 'CodeBuddy', droid: 'Droid', kiro: 'Kiro CLI',
};

export function agentName(type: string): string { return names[type] ?? type; }
export function agentColor(type: string): string {
  if (['trae', 'trae_cn', 'trae_ide_cn', 'traework_cn'].includes(type)) return '#33b3f2';
  if (type === 'workbuddy') return '#2389e8';
  const name = agentName(type).toLowerCase();
  return ({ claude: '#d97340', codex: '#33cc66', cursor: '#9966e6', gemini: '#4d80f2', trae: '#33b3f2',
    opencode: '#f2b333', copilot: '#66b3e6', windsurf: '#39cbb0', deepseek: '#408bc7', kimi: '#ed6688' } as Record<string,string>)[name] ?? '#8ea8ca';
}

export function statusLabel(status: string): string {
  return ({ active: t('运行中'), idle: t('空闲'), thinking: t('思考中'), waitingPermission: t('等待授权'), waiting_permission: t('等待授权'),
    waitingAnswer: t('等待回答'), waiting_answer: t('等待回答'), waitingPlanReview: t('等待审核'), waiting_plan_review: t('等待审核'),
    completed: t('已完成'), error: t('发生错误'), compacting: t('整理上下文'), observationUnavailable: t('观测中断'),
    completionUnconfirmed: t('结束未确认') } as Record<string,string>)[status] ?? status;
}

export function statusColor(status: string): string {
  if (status.startsWith('waiting')) return 'var(--orange)';
  return ({ active: 'var(--cyan)', thinking: 'var(--purple)', idle: 'var(--green)', error: 'var(--red)', compacting: 'var(--yellow)' } as Record<string,string>)[status] ?? 'var(--muted)';
}

export function mascot(type: string, status: string, size = 24): HTMLElement {
  const node = el('span', `mascot ${['active', 'thinking', 'compacting'].includes(status) ? 'is-running' : ''}`);
  node.style.setProperty('--agent', agentColor(type));
  node.style.setProperty('--status', statusColor(status));
  node.style.width = `${size}px`;
  node.style.height = `${size}px`;
  node.setAttribute('role', 'img');
  node.setAttribute('aria-label', `${agentName(type)}：${statusLabel(status)}`);
  const face = el('span', `mascot-face face-${status === 'idle' || status === 'completed' ? 'smile' : status === 'thinking' ? 'thinking' : status === 'error' ? 'error' : 'awake'}`);
  face.append(el('i', 'eye left'), el('i', 'eye right'), el('i', 'mouth'));
  node.append(face);
  return node;
}

export function badge(text: string, color?: string): HTMLElement {
  const node = el('span', 'badge', text);
  if (color) { node.style.setProperty('--badge-color', color); node.classList.add('colored'); }
  return node;
}

/** 保留纯文本、代码与标题层次，不将 Agent 输出作为 HTML 执行。 */
export function markdown(source: string): HTMLElement {
  const result = el('div', 'markdown');
  let code: HTMLPreElement | undefined;
  for (const line of source.split('\n')) {
    if (line.startsWith('```')) {
      if (code) { result.append(code); code = undefined; }
      else code = el('pre');
      continue;
    }
    if (code) { code.textContent += `${line}\n`; continue; }
    if (/^#{1,3} /.test(line)) result.append(el('strong', 'markdown-heading', line.replace(/^#{1,3} /, '')));
    else result.append(el('p', '', line || '\u00a0'));
  }
  if (code) result.append(code);
  return result;
}
