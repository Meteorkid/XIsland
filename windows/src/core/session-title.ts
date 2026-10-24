import { normalizeCodexPrompt } from './codex-prompt';
import type { Session } from './types';

export function sessionPromptTitle(session: Pick<Session, 'agentType' | 'prompt'>): string {
  const prompt = session.agentType === 'codex' ? normalizeCodexPrompt(session.prompt) : session.prompt;
  return prompt.split('\n').find(line => line.trim())?.trim() ?? '';
}
