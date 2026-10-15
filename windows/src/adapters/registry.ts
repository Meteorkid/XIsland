import { CLAUDE_HOOK_EVENTS, claudeHookResponse, normalizeClaudeHook } from './claude';
import { CODEX_HOOK_EVENTS, codexHookResponse, normalizeCodexHook } from './codex';
import { CURSOR_HOOK_EVENTS, cursorHookResponse, normalizeCursorHook } from './cursor';
import { GEMINI_HOOK_EVENTS, geminiHookResponse, normalizeGeminiHook } from './gemini';
import { WINDSURF_HOOK_EVENTS, normalizeWindsurfHook, windsurfHookResponse } from './windsurf';
import { TRAE_HOOK_EVENTS, normalizeTraeHook, traeHookResponse } from './trae';
import { WORKBUDDY_HOOK_EVENTS, normalizeWorkBuddyHook, workBuddyHookResponse } from './workbuddy';
import type { DIMessage, DIResponse } from '../core/protocol';

export const CONFIGURABLE_AGENTS = ['claude_code', 'codex', 'cursor', 'gemini_cli', 'windsurf', 'trae_cn'] as const;
export type ConfigurableAgent = typeof CONFIGURABLE_AGENTS[number];
export const SUPPORTED_AGENTS = [...CONFIGURABLE_AGENTS, 'workbuddy'] as const;
export type SupportedAgent = typeof SUPPORTED_AGENTS[number];
export interface HookOutput { stdout: string; exitCode: number }
export interface HookAdapter {
  timeoutMs?: number;
  events: readonly string[];
  normalize(payload: unknown): DIMessage;
  respond(payload: unknown, response: DIResponse | null): HookOutput;
}
const adapters: Record<SupportedAgent, HookAdapter> = {
  claude_code: { events: CLAUDE_HOOK_EVENTS, normalize: normalizeClaudeHook, respond: claudeHookResponse },
  codex: { events: CODEX_HOOK_EVENTS, normalize: normalizeCodexHook, respond: codexHookResponse },
  cursor: { events: CURSOR_HOOK_EVENTS, normalize: normalizeCursorHook, respond: cursorHookResponse },
  gemini_cli: { events: GEMINI_HOOK_EVENTS, normalize: normalizeGeminiHook, respond: geminiHookResponse },
  windsurf: { events: WINDSURF_HOOK_EVENTS, normalize: normalizeWindsurfHook, respond: windsurfHookResponse },
  trae_cn: { events: TRAE_HOOK_EVENTS, normalize: normalizeTraeHook, respond: traeHookResponse },
  workbuddy: { events: WORKBUDDY_HOOK_EVENTS, normalize: normalizeWorkBuddyHook, respond: workBuddyHookResponse, timeoutMs: 2000 },
};
export function adapterFor(agent: string): HookAdapter {
  if (!(SUPPORTED_AGENTS as readonly string[]).includes(agent)) throw new Error('unsupported_agent');
  return adapters[agent as SupportedAgent];
}
