import { isAbsolute, join, win32 } from 'node:path';

export const PI_PLUGIN_MARKER = '// XIsland Windows Pi observer v1. Native ExtensionAPI; no permission decisions.';

function absolutePath(value: string): boolean {
  return !!value && !/[\0\r\n]/.test(value) && (isAbsolute(value) || win32.isAbsolute(value));
}

/** 官方 agent-dir/extensions；安装器额外限制自定义目录必须在用户目录内。 */
export function piPluginPath(homeDirectory: string, environment: Record<string, string | undefined> = {}): string {
  if (!absolutePath(homeDirectory)) throw new Error('invalid_pi_home');
  const windows = /^[a-z]:[\\/]/i.test(homeDirectory) || homeDirectory.startsWith('\\\\');
  const paths = windows ? win32 : { join };
  const custom = environment.PI_CODING_AGENT_DIR;
  if (custom && !absolutePath(custom)) throw new Error('invalid_pi_agent_directory');
  return paths.join(custom || paths.join(homeDirectory, '.pi', 'agent'), 'extensions', 'xisland.ts');
}

export function isOwnedPiPlugin(source: string): boolean {
  const normalized = source.replace(/\r\n/g, '\n');
  if (!normalized.startsWith(PI_PLUGIN_MARKER + '\n')) return false;
  const runtime = /^const NODE = (.+);\nconst HOOK = (.+);$/m.exec(normalized);
  if (!runtime) return false;
  try {
    const node: unknown = JSON.parse(runtime[1]!), hook: unknown = JSON.parse(runtime[2]!);
    return typeof node === 'string' && typeof hook === 'string' && normalized === piPluginSource(node, hook);
  } catch { return false; }
}

/** 按 Pi 1.3.0 的 ExtensionAPI 校对，仅注册通知事件，不返回任何控制结果。 */
export function piPluginSource(nodeExecutable: string, hookScript: string): string {
  if (!absolutePath(nodeExecutable) || !absolutePath(hookScript)) throw new Error('invalid_pi_runtime_path');
  return `${PI_PLUGIN_MARKER}
import { spawn } from "node:child_process";
const NODE = ${JSON.stringify(nodeExecutable)};
const HOOK = ${JSON.stringify(hookScript)};

export default function (pi) {
  const children = new Set(), reports = new Map();
  let closed = false;
  const valid = value => typeof value === "string" && value.trim().length > 0 && !value.includes(String.fromCharCode(0));
  const diagnose = code => process.stderr.write(\`[XIsland] Pi observation unavailable: \${code}\\n\`);

  function report(event, ctx, data = {}) {
    if (closed && event !== "session_shutdown") return Promise.resolve();
    let sid;
    try { sid = ctx?.sessionManager?.getSessionId(); }
    catch { diagnose("session-id-unavailable"); return Promise.resolve(); }
    if (!valid(sid)) { diagnose("missing-session-id"); return Promise.resolve(); }
    const terminal = ["agent_end", "agent_settled", "session_shutdown"].includes(event);
    const signal = terminal ? undefined : ctx.signal;
    if (signal?.aborted) return Promise.resolve();
    let input;
    try {
      input = JSON.stringify({ ...data, native_event: event, session_id: sid, cwd: ctx.cwd,
        model: typeof ctx.model?.id === "string" ? ctx.model.id : undefined,
        terminal: process.env.TERM_PROGRAM });
    } catch { diagnose("invalid-payload"); return Promise.resolve(); }
    if (Buffer.byteLength(input) > 16 * 1024 * 1024) { diagnose("payload-too-large"); return Promise.resolve(); }
    // 同一会话按注册事件到达顺序发送，避免并行工具的子进程乱序覆盖终态。
    const work = (reports.get(sid) ?? Promise.resolve()).catch(() => {}).then(() => {
      if (signal?.aborted || closed && event !== "session_shutdown") return;
      return run(event, input, signal);
    });
    reports.set(sid, work);
    void work.finally(() => { if (reports.get(sid) === work) reports.delete(sid); });
    return work;
  }
  function run(event, input, signal) {
    return new Promise(resolve => {
      let child, timer, settled = false;
      const finish = code => {
        if (settled) return;
        settled = true; clearTimeout(timer);
        if (child) children.delete(child);
        if (code && !signal?.aborted) diagnose(code);
        resolve();
      };
      try {
        child = spawn(NODE, [HOOK, "--agent", "pi", "--hook", event], {
          shell: false, windowsHide: true, signal, killSignal: "SIGKILL", stdio: ["pipe", "ignore", "ignore"],
        });
        children.add(child);
        child.once("error", () => finish("spawn-error"));
        child.once("close", code => finish(code === 0 ? null : "bridge-exit"));
        child.stdin.once("error", () => { child.kill("SIGKILL"); finish("stdin-error"); });
        timer = setTimeout(() => { child.kill("SIGKILL"); finish("bridge-timeout"); }, 1500);
        child.stdin.end(input);
      } catch { if (child) child.kill("SIGKILL"); finish("spawn-error"); }
    });
  }

  pi.on("session_start", async (event, ctx) => {
    await report("session_start", ctx, { source: event.reason, previous_session_file: event.previousSessionFile });
  });
  pi.on("before_agent_start", async (event, ctx) => {
    await report("before_agent_start", ctx, { prompt: event.messageType === "custom" ? undefined : event.prompt });
  });
  pi.on("agent_start", async (_event, ctx) => { await report("agent_start", ctx); });
  pi.on("tool_execution_start", async (event, ctx) => {
    if (!valid(event.toolCallId) || !valid(event.toolName)) { diagnose("invalid-tool-event"); return; }
    await report("tool_execution_start", ctx, { tool_use_id: event.toolCallId, tool_name: event.toolName, tool_input: event.args });
  });
  pi.on("tool_execution_end", async (event, ctx) => {
    if (!valid(event.toolCallId) || !valid(event.toolName)) { diagnose("invalid-tool-event"); return; }
    await report("tool_execution_end", ctx, { tool_use_id: event.toolCallId, tool_name: event.toolName,
      tool_response: event.result, native_status: event.isError === true ? "error" : event.isError === false ? "done" : undefined });
  });
  pi.on("agent_end", async (_event, ctx) => { await report("agent_end", ctx); });
  pi.on("agent_settled", async (_event, ctx) => {
    if (ctx.isIdle()) await report("agent_settled", ctx);
  });
  pi.on("session_shutdown", async (event, ctx) => {
    if (closed) return;
    closed = true;
    for (const child of children) child.kill("SIGKILL");
    await report("session_shutdown", ctx, { reason: event.reason, target_session_file: event.targetSessionFile });
  });
}
`;
}
