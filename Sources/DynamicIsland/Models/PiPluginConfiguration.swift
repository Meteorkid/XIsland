import Foundation

/// 对应 earendil-works/pi 当前 ExtensionAPI，所有 handler 均只观察。
/// agent_end 可能仍有自动续跑，只有 agent_settled 才报告空闲。
enum PiPluginConfiguration {
    enum ConfigurationError: Error {
        case invalidBridgePath
    }

    static func pluginURL(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".pi/agent/extensions/xisland.ts")
    }

    static func isOwnedSource(_ source: String) -> Bool {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.hasPrefix("// XIsland Pi observer. Native ExtensionAPI; no permission decisions.\n")
            || normalized == legacySource.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func source(bridgePath: String) throws -> String {
        guard bridgePath.hasPrefix("/"), !bridgePath.contains("\0") else {
            throw ConfigurationError.invalidBridgePath
        }
        let encodedPath = String(decoding: try JSONEncoder().encode(bridgePath), as: UTF8.self)
        return #"""
        // XIsland Pi observer. Native ExtensionAPI; no permission decisions.
        import { spawn } from "node:child_process";

        const BRIDGE = \#(encodedPath);

        export default function (pi) {
          const children = new Set();
          const diagnose = code => process.stderr.write(`[XIsland] Pi observation unavailable: ${code}\n`);

          async function report(nativeEvent, hook, hookEvent, ctx, data) {
            let sessionID;
            try {
              sessionID = ctx?.sessionManager?.getSessionId();
            } catch {
              diagnose("session-id-unavailable");
              return;
            }
            if (typeof sessionID !== "string" || !sessionID.trim()) {
              diagnose("missing-session-id");
              return;
            }
            // 已取消轮次的终态仍需交付，其他正在进行的上报服从宿主取消。
            const terminalEvent = ["session_shutdown", "agent_end", "agent_settled"].includes(nativeEvent);
            const signal = terminalEvent ? undefined : ctx.signal;
            if (signal?.aborted) return;
            let input;
            try {
              input = JSON.stringify({
                ...data,
                session_id: sessionID,
                cwd: ctx.cwd,
                model: typeof ctx.model?.id === "string" ? ctx.model.id : undefined,
                native_event: nativeEvent,
                hook_event_name: hookEvent,
                terminal: process.env.TERM_PROGRAM || "Terminal",
              });
            } catch {
              diagnose("invalid-payload");
              return;
            }
            if (Buffer.byteLength(input, "utf8") > 16 * 1024 * 1024) {
              diagnose("payload-too-large");
              return;
            }

            await new Promise((resolve) => {
              let child;
              let timer;
              let finished = false;
              function finish(code) {
                if (finished) return;
                finished = true;
                clearTimeout(timer);
                if (child) children.delete(child);
                if (code && !signal?.aborted) diagnose(code);
                resolve();
              }
              try {
                child = spawn(BRIDGE, ["--agent", "pi", "--hook", hook, "--session", sessionID], {
                  shell: false,
                  signal,
                  killSignal: "SIGKILL",
                  stdio: ["pipe", "ignore", "ignore"],
                });
                children.add(child);
                child.once("error", () => finish("spawn-error"));
                child.once("close", (code) => finish(code === 0 ? null : "bridge-exit"));
                child.stdin.once("error", () => {
                  child.kill("SIGKILL");
                  finish("stdin-error");
                });
                timer = setTimeout(() => {
                  child.kill("SIGKILL");
                  finish("bridge-timeout");
                }, 1500);
                child.stdin.end(input);
              } catch {
                if (child) child.kill("SIGKILL");
                finish("spawn-error");
              }
            });
          }

          pi.on("session_start", async (event, ctx) => {
            await report("session_start", "session_start", "SessionStart", ctx, {
              source: event.reason,
              previous_session_file: event.previousSessionFile,
            });
          });

          pi.on("before_agent_start", async (event, ctx) => {
            await report("before_agent_start", "UserPromptSubmit", "UserPromptSubmit", ctx, { prompt: event.prompt });
          });

          pi.on("agent_start", async (_event, ctx) => {
            await report("agent_start", "notification", "AgentStart", ctx, { native_status: "running" });
          });

          pi.on("tool_execution_start", async (event, ctx) => {
            if (typeof event.toolCallId !== "string" || !event.toolCallId || typeof event.toolName !== "string") {
              diagnose("invalid-tool-event");
              return;
            }
            await report("tool_execution_start", "toolstart", "PreToolUse", ctx, {
              tool_use_id: event.toolCallId,
              tool_name: event.toolName,
              tool_input: event.args,
            });
          });

          pi.on("tool_execution_end", async (event, ctx) => {
            if (typeof event.toolCallId !== "string" || !event.toolCallId || typeof event.toolName !== "string") {
              diagnose("invalid-tool-event");
              return;
            }
            await report("tool_execution_end", "toolcomplete", "PostToolUse", ctx, {
              tool_use_id: event.toolCallId,
              tool_name: event.toolName,
              tool_response: event.result,
              native_status: event.isError === true ? "error" : event.isError === false ? "done" : undefined,
            });
          });

          pi.on("agent_end", async (_event, ctx) => {
            await report("agent_end", "notification", "AgentEnd", ctx, {});
          });

          pi.on("agent_settled", async (_event, ctx) => {
            if (!ctx.isIdle()) return;
            await report("agent_settled", "notification", "Stop", ctx, { native_status: "done" });
          });

          pi.on("session_shutdown", async (event, ctx) => {
            for (const child of children) child.kill("SIGKILL");
            await report("session_shutdown", "session_end", "SessionEnd", ctx, {
              reason: event.reason,
              target_session_file: event.targetSessionFile,
            });
          });
        }
        """#
    }

    // 仅迁移本应用旧版完整模板，保留用户的同名扩展。
    private static let legacySource = #"""
    import { spawn } from "child_process";
    import { homedir } from "os";
    const BRIDGE = homedir() + "/.xisland/bin/di-bridge";
    function send(hookType: string, sessionId: string, data: Record<string, any>) {
      return new Promise<void>((resolve) => {
        try {
          const child = spawn(BRIDGE, ["--agent","pi","--hook",hookType,"--session",sessionId], {
            stdio: ["pipe","pipe","pipe"]
          });
          child.stdin.write(JSON.stringify(data)); child.stdin.end();
          child.on("close", () => resolve());
          child.on("error", () => resolve());
          setTimeout(() => { child.kill(); resolve(); }, 5000);
        } catch { resolve(); }
      });
    }
    export default {
      session_start: async (ctx: { sessionId: string; cwd?: string }) => {
        await send("session_start", ctx.sessionId, { cwd: ctx.cwd || "", terminal: process.env.TERM_PROGRAM || "Terminal" });
      },
      session_end: async (ctx: { sessionId: string }) => {
        await send("session_end", ctx.sessionId, {});
      },
      agent_start: async (ctx: { sessionId: string; task?: string }) => {
        await send("session_start", ctx.sessionId, { prompt: ctx.task || "" });
      },
      agent_end: async (ctx: { sessionId: string }) => {
        await send("session_end", ctx.sessionId, {});
      },
      tool_call: async (ctx: { sessionId: string; tool: string; input?: any }) => {
        await send("PreToolUse", ctx.sessionId, { tool_name: ctx.tool, tool_input: ctx.input });
      },
      tool_result: async (ctx: { sessionId: string; tool: string; result?: any }) => {
        await send("PostToolUse", ctx.sessionId, { tool_name: ctx.tool, result: ctx.result });
      },
    };
    """#

}
