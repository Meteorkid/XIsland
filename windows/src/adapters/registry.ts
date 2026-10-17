import { CLAUDE_HOOK_EVENTS, claudeHookResponse, normalizeClaudeHook } from './claude';
import { CODEX_HOOK_EVENTS, codexHookResponse, normalizeCodexHook } from './codex';
import { CURSOR_HOOK_EVENTS, cursorHookResponse, normalizeCursorHook } from './cursor';
import { GEMINI_HOOK_EVENTS, geminiHookResponse, normalizeGeminiHook } from './gemini';
import { WINDSURF_HOOK_EVENTS, normalizeWindsurfHook, windsurfHookResponse } from './windsurf';
import { TRAE_HOOK_EVENTS, normalizeTraeHook, traeHookResponse } from './trae';
import { WORKBUDDY_HOOK_EVENTS, normalizeWorkBuddyHook, workBuddyHookResponse } from './workbuddy';
import { QWEN_HOOK_EVENTS, normalizeQwenHook, qwenHookResponse } from './qwen';
import { CODEBUDDY_HOOK_EVENTS, normalizeCodeBuddyHook, codeBuddyHookResponse } from './codebuddy';
import { DROID_HOOK_EVENTS, normalizeDroidHook, droidHookResponse } from './droid';
import { OPENCODE_HOOK_EVENTS, normalizeOpenCodeHook, openCodeHookResponse } from './opencode';
import { KIMI_CODE_HOOK_EVENTS, normalizeKimiCodeHook, kimiCodeHookResponse } from './kimi-code';
import { KIRO_HOOK_EVENTS, normalizeKiroHook, kiroHookResponse } from './kiro';
import type { DIMessage, DIResponse } from '../core/protocol';

export const CONFIGURABLE_AGENTS = ['claude_code', 'codex', 'cursor', 'gemini_cli', 'windsurf', 'trae_cn', 'qwen', 'code_buddy', 'droid'] as const;
export type ConfigurableAgent = typeof CONFIGURABLE_AGENTS[number];
export const MANAGED_AGENTS = [...CONFIGURABLE_AGENTS, 'opencode', 'kimi_code'] as const;
export type ManagedAgent = typeof MANAGED_AGENTS[number];
export const SUPPORTED_AGENTS = [...MANAGED_AGENTS, 'workbuddy', 'kiro'] as const;
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
  qwen: { events: QWEN_HOOK_EVENTS, normalize: normalizeQwenHook, respond: qwenHookResponse },
  code_buddy: { events: CODEBUDDY_HOOK_EVENTS, normalize: normalizeCodeBuddyHook, respond: codeBuddyHookResponse, timeoutMs: 2000 },
  droid: { events: DROID_HOOK_EVENTS, normalize: normalizeDroidHook, respond: droidHookResponse, timeoutMs: 2000 },
  opencode: { events: OPENCODE_HOOK_EVENTS, normalize: normalizeOpenCodeHook, respond: openCodeHookResponse },
  kimi_code: { events: KIMI_CODE_HOOK_EVENTS, normalize: normalizeKimiCodeHook, respond: kimiCodeHookResponse, timeoutMs: 2000 },
  kiro: { events: KIRO_HOOK_EVENTS, normalize: normalizeKiroHook, respond: kiroHookResponse, timeoutMs: 2000 },
};
export function adapterFor(agent: string): HookAdapter {
  if (!(SUPPORTED_AGENTS as readonly string[]).includes(agent)) throw new Error('unsupported_agent');
  return adapters[agent as SupportedAgent];
}
