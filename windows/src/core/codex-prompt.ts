import { isRecord } from './protocol';

const replyOpen = '<send_user_message_question_reply>';
const replyClose = '</send_user_message_question_reply>';

/** 只展开 Codex 保留包装；嵌套与不完整的保留标签统一收敛，避免入站和展示时重复解析改变答案。 */
export function normalizeCodexPrompt(value: string): string {
  let prompt = value;
  for (let depth = 0; depth < 8; depth++) {
    const trimmed = prompt.trim();
    if (!trimmed.startsWith(replyOpen)) return prompt;
    const end = trimmed.lastIndexOf(replyClose);
    if (end < replyOpen.length) return '';
    let replies: unknown;
    try { replies = JSON.parse(trimmed.slice(replyOpen.length, end)); }
    catch { return ''; }
    if (!Array.isArray(replies) || !replies.every(reply => isRecord(reply) && typeof reply.answer === 'string')) return '';
    const answers = replies.map(reply => (reply.answer as string).trim()).filter(Boolean);
    const trailing = trimmed.slice(end + replyClose.length).trim();
    if (trailing) answers.push(trailing);
    prompt = answers.join('\n');
  }
  return prompt.trim().startsWith(replyOpen) ? '' : prompt;
}
