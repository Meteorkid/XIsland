import sessions from './fixtures/app/session-list.json';
import permission from './fixtures/app/permission-smoke.json';
import question from './fixtures/app/question-smoke.json';
import custom from './fixtures/app/question-custom.json';
import multiple from './fixtures/app/question-focus.json';
import plan from './fixtures/app/plan-smoke.json';

export const fixtures: Record<string, unknown> = { sessions, permission, question, custom, multiple, plan };
