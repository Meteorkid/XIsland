import { win32 } from 'node:path';
import { KIMI_CODE_HOOK_EVENTS } from '../adapters/kimi-code';

export type KimiCodeHookEvent = typeof KIMI_CODE_HOOK_EVENTS[number];
export const KIMI_CODE_HOOK_TIMEOUT_SECONDS = 10;
const BEGIN = '# BEGIN XIsland:Windows:KimiCode:hooks v1';
const END = '# END XIsland:Windows:KimiCode:hooks v1';
type Commands = (event: KimiCodeHookEvent) => string;
export interface KimiCodeConfigurationPlan {
  nextText: string;
  changed: boolean;
  addedHandlers: number;
  removedHandlers: number;
}

function fail(reason: string): never { throw new Error(`无法安全修改 Kimi Code TOML：${reason}`); }
function absoluteWindowsPath(value: string): string {
  if (!/^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)/.test(value)
    || /[\u0000-\u001f"<>|?*]/.test(value) || value.slice(2).includes(':')) return fail('需要 Windows 绝对路径');
  return win32.normalize(value);
}

/** KIMI_CODE_HOME 是目录；Python .kimi/config.toml 不能作为 Node 安装目标。 */
export function kimiCodeConfigPath(homeDirectory: string, kimiCodeHome?: string): string {
  const home = absoluteWindowsPath(homeDirectory);
  const directory = kimiCodeHome === undefined ? win32.join(home, '.kimi-code') : absoluteWindowsPath(kimiCodeHome);
  const config = win32.join(directory, 'config.toml');
  if (config.toLowerCase() === win32.join(home, '.kimi', 'config.toml').toLowerCase()) return fail('与 Python Kimi 配置重叠');
  return config;
}

/** 命令由 Windows 编码启动器生成；不把 macOS shell quoting 写入 Windows 配置。 */
export function kimiCodeHookFragment(commandForEvent: Commands): string {
  let text = `\n${BEGIN}\n`;
  for (const event of KIMI_CODE_HOOK_EVENTS) {
    const command = commandForEvent(event);
    if (!command.trim() || /[\p{Cc}\p{Cf}]/u.test(command)) return fail('命令含控制字符');
    text += `[[hooks]]\nevent = ${JSON.stringify(event)}\ncommand = ${JSON.stringify(command)}\ntimeout = ${KIMI_CODE_HOOK_TIMEOUT_SECONDS}\n\n`;
  }
  return text + END + '\n';
}

interface Statement { start: number; end: number; code: string }

/** 只确认可追加的顶层边界；复杂或含糊结构拒绝处理，不解析后重写用户 TOML。 */
function statements(text: string): Statement[] {
  if (text.includes('\0') || /\r(?!\n)/.test(text)) return fail('控制字符');
  let quote = '', multiline = false;
  const stack: string[] = [], rows: Statement[] = [];
  for (let start = 0; start < text.length;) {
    const next = text.indexOf('\n', start), end = next < 0 ? text.length : next + 1;
    const raw = text.slice(start, next < 0 ? end : next).trim();
    const isStatement = !quote && stack.length === 0;
    let code = '';
    for (let index = 0; index < raw.length; index++) {
      const char = raw[index]!;
      if (quote) {
        if (quote === '"' && char === '\\') { code += char + (raw[++index] ?? ''); continue; }
        if (char === quote) {
          if (multiline) {
            let run = 1; while (raw[index + run] === quote) run++;
            if (run >= 3) {
              if (run > 5) return fail('多行字符串边界');
              code += quote.repeat(run); index += run - 1; quote = ''; multiline = false; continue;
            }
          } else quote = '';
        }
        code += char; continue;
      }
      if (char === '#') { if (!index && isStatement) code = raw; break; }
      if (char === '"' || char === "'") {
        quote = char; multiline = raw.slice(index, index + 3) === char.repeat(3);
        if (multiline) { code += char.repeat(3); index += 2; continue; }
      } else if (char === '[' || char === '{') stack.push(char);
      else if (char === ']' || char === '}') {
        if (stack.pop() !== (char === ']' ? '[' : '{')) return fail('不平衡括号');
      }
      code += char;
    }
    if (quote && !multiline) return fail('未结束字符串');
    if (isStatement) rows.push({ start, end, code: code.trim() });
    start = end;
  }
  if (quote || stack.length) return fail('未结束的多行值');
  return rows;
}

function firstKey(value: string): string {
  const match = /^(?:([A-Za-z0-9_-]+)|"([^"\\]*)"|'([^']*)')/.exec(value);
  if (!match) return fail('无法识别或转义的键名');
  return match[1] ?? match[2] ?? match[3]!;
}
function quoted(value: string): string {
  if (/^'[^']*'$/.test(value)) return value.slice(1, -1);
  try { const result: unknown = JSON.parse(value); if (typeof result === 'string') return result; }
  catch { /* 复杂 TOML 字符串留给用户手动处理，不推测其值。 */ }
  return fail('复杂 hook 字符串');
}
function validateBoundaries(rows: Statement[]): void {
  let root = true, hookFields: Map<string, string> | undefined;
  const finishHook = () => {
    if (!hookFields) return;
    const event = hookFields.get('event'), command = hookFields.get('command');
    if (event === undefined || command === undefined || !(KIMI_CODE_HOOK_EVENTS as readonly string[]).includes(quoted(event))) return fail('不支持或缺失的 hook 事件');
    if (!quoted(command).trim()) return fail('空 hook 命令');
    const matcher = hookFields.get('matcher'); if (matcher !== undefined) quoted(matcher);
    const timeout = hookFields.get('timeout');
    if (timeout !== undefined && (!/^\d+$/.test(timeout) || Number(timeout) < 1 || Number(timeout) > 600)) return fail('hook timeout');
  };
  for (const row of rows) {
    if (!row.code || row.code.startsWith('#')) continue;
    if (row.code.startsWith('[')) {
      finishHook(); hookFields = undefined; root = false;
      const array = row.code.startsWith('[['), width = array ? 2 : 1;
      if (!row.code.endsWith(array ? ']]' : ']')) return fail('复杂表头');
      const key = row.code.slice(width, -width).trim();
      if (firstKey(key) === 'hooks') {
        if (!array || !['hooks', '"hooks"', "'hooks'"].includes(key)) return fail('hooks 子表');
        hookFields = new Map();
      }
    } else {
      const key = firstKey(row.code);
      if (root && key === 'hooks') return fail('内联 hooks');
      if (hookFields) {
        const match = /^(?:([A-Za-z0-9_-]+)|"([^"\\]*)"|'([^']*)')\s*=\s*(.*)$/.exec(row.code);
        if (!match || !['event', 'command', 'matcher', 'timeout'].includes(key) || hookFields.has(key)) return fail('hook 字段');
        hookFields.set(key, match[4]!);
      }
    }
  }
  finishHook();
}

/**
 * 纯计划：逐字保存未知字段/注释，仅处理末尾规范区块；调用方负责备份和原文比对写入。
 * ownsCommand 必须完整重建验证旧命令，不能只看标记，才能安全升级旧安装路径。
 */
export function createKimiCodeConfigurationPlan(input: {
  configuration?: string;
  operation: 'install' | 'uninstall';
  commandForEvent: Commands;
  ownsCommand?: (command: string, event: KimiCodeHookEvent) => boolean;
}): KimiCodeConfigurationPlan {
  if (!['install', 'uninstall'].includes(input.operation)) return fail('操作');
  const original = input.configuration ?? '';
  const rows = statements(original), markers = rows.filter(row => /^# (?:BEGIN|END) XIsland:Windows:KimiCode:/.test(row.code));
  let base = original, removedHandlers = 0;
  if (markers.length) {
    if (markers.length !== 2 || markers[0]!.code !== BEGIN || markers[1]!.code !== END
      || markers[0]!.start === 0 || original[markers[0]!.start - 1] !== '\n') return fail('托管标记不完整');
    const start = markers[0]!.start - 1, owned = original.slice(start);
    const commands = new Map<KimiCodeHookEvent, string>();
    for (const event of KIMI_CODE_HOOK_EVENTS) {
      const expectedPrefix = `[[hooks]]\nevent = ${JSON.stringify(event)}\ncommand = `;
      const offset = owned.indexOf(expectedPrefix);
      if (offset < 0) return fail('托管事件缺失或已修改');
      const from = offset + expectedPrefix.length, to = owned.indexOf('\n', from);
      const command = quoted(owned.slice(from, to));
      if (command !== input.commandForEvent(event) && !input.ownsCommand?.(command, event)) return fail('托管命令已修改');
      commands.set(event, command);
    }
    if (owned !== kimiCodeHookFragment(event => commands.get(event)!)) return fail('托管区块已修改或不是末尾区块');
    base = original.slice(0, start); removedHandlers = KIMI_CODE_HOOK_EVENTS.length;
  }
  validateBoundaries(statements(base));
  const nextText = input.operation === 'install' ? base + kimiCodeHookFragment(input.commandForEvent) : base;
  const changed = nextText !== original;
  return { nextText, changed, addedHandlers: changed && input.operation === 'install' ? KIMI_CODE_HOOK_EVENTS.length : 0,
    removedHandlers: changed ? removedHandlers : 0 };
}
