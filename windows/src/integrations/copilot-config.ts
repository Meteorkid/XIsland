import { isAbsolute, join, win32 } from 'node:path';
import { COPILOT_CLI_HOOK_EVENTS } from '../adapters/copilot-cli';
import { isRecord } from '../core/protocol';
import { ownsWindowsHookCommand, windowsHookCommand } from './plan';

export const COPILOT_HOOKS_SOURCE = 'https://docs.github.com/en/copilot/reference/hooks-reference';
type Configuration = Record<string, unknown>;
const validPath = (value: string): boolean => !!value && !/[\0\r\n]/.test(value) && (isAbsolute(value) || win32.isAbsolute(value));

export function copilotConfigPath(homeDirectory: string, environment: Record<string, string | undefined> = {}): string {
  if (!validPath(homeDirectory)) throw new Error('invalid_copilot_home');
  const windows = /^[a-z]:[\\/]/i.test(homeDirectory) || homeDirectory.startsWith('\\\\');
  const paths = windows ? win32 : { join };
  const custom = environment.COPILOT_HOME || undefined;
  if (custom !== undefined && !validPath(custom)) throw new Error('invalid_config_home');
  return paths.join(custom ?? paths.join(homeDirectory, '.copilot'), 'hooks', 'xisland.json');
}

function validateHandler(value: unknown): void {
  if (!isRecord(value)) throw new Error('invalid_copilot_handler');
  if (value.hooks !== undefined) {
    if (!Array.isArray(value.hooks) || value.matcher !== undefined && typeof value.matcher !== 'string') throw new Error('invalid_copilot_handler');
    value.hooks.forEach(validateHandler); return;
  }
  const type = value.type ?? 'command';
  if (typeof type !== 'string') throw new Error('invalid_copilot_handler');
  const fields = type === 'http' ? ['url'] : type === 'prompt' ? ['prompt'] : ['exec', 'powershell', 'bash', 'command'];
  if (!fields.some(field => typeof value[field] === 'string' && (value[field] as string).length > 0)) throw new Error('invalid_copilot_handler');
  if (value.args !== undefined && (!Array.isArray(value.args) || !value.args.every(arg => typeof arg === 'string'))) throw new Error('invalid_copilot_args');
  for (const field of ['timeoutSec', 'timeout']) {
    if (value[field] !== undefined && (typeof value[field] !== 'number' || !Number.isFinite(value[field]) || value[field] <= 0)) throw new Error('invalid_copilot_timeout');
  }
}
export function validateCopilotConfiguration(value: unknown): asserts value is Configuration {
  if (!isRecord(value) || value.version !== undefined && value.version !== 1) throw new Error('invalid_copilot_version');
  if (value.hooks === undefined) return;
  if (!isRecord(value.hooks)) throw new Error('invalid_copilot_hooks');
  for (const entries of Object.values(value.hooks)) {
    if (!Array.isArray(entries)) throw new Error('invalid_copilot_hooks');
    entries.forEach(validateHandler);
  }
}

function ownedHandler(value: unknown, event: string): boolean {
  return isRecord(value) && Object.keys(value).sort().join(',') === 'powershell,timeoutSec,type'
    && value.type === 'command' && value.timeoutSec === 10 && typeof value.powershell === 'string'
    && ownsWindowsHookCommand(value.powershell, 'copilot_cli', event);
}
export function copilotManagedHandlerCount(value: unknown): number {
  validateCopilotConfiguration(value);
  return Object.entries(value.hooks ?? {}).reduce((count, [event, entries]) => count + (entries as unknown[]).filter(entry => ownedHandler(entry, event)).length, 0);
}

/** 只认领完整生成的 Windows handler；不移除用户平台命令、注释字段或权限设置。 */
export function mergeCopilotConfiguration(value: unknown, operation: 'install' | 'uninstall', node: string, hook: string) {
  validateCopilotConfiguration(value);
  const configuration = JSON.parse(JSON.stringify(value)) as Configuration;
  const hooks = (configuration.hooks ?? {}) as Configuration;
  let removedHandlers = 0;
  for (const [event, entries] of Object.entries(hooks)) {
    const retained = (entries as unknown[]).filter(entry => { const owned = ownedHandler(entry, event); if (owned) removedHandlers++; return !owned; });
    if (retained.length || !(entries as unknown[]).length) hooks[event] = retained;
    else delete hooks[event];
  }
  if (operation === 'install') {
    for (const event of COPILOT_CLI_HOOK_EVENTS) {
      hooks[event] = [...(hooks[event] as unknown[] | undefined ?? []), {
        type: 'command', powershell: windowsHookCommand(node, hook, 'copilot_cli', event), timeoutSec: 10,
      }];
    }
    configuration.version = 1;
    configuration.hooks = hooks;
  } else if (value.hooks !== undefined) configuration.hooks = hooks;
  // 只有原文件全部内容均为生成结构时才能删除整个文件。
  const removable = operation === 'uninstall' && removedHandlers > 0 && Object.keys(configuration).sort().join(',') === 'hooks,version'
    && configuration.version === 1 && !Object.keys(hooks).length;
  return { configuration, removable, removedHandlers, addedHandlers: operation === 'install' ? COPILOT_CLI_HOOK_EVENTS.length : 0 };
}
