import Foundation

/// Amp 当前 PluginAPI 的本地观察插件，不接管工具许可。
/// 官方 tool.call 必须返回决定，未证实 allow 与其他策略如何合并，因此不订阅该事件。
/// 来源：https://ampcode.com/docs/plugin-api 和 https://ampcode.com/docs/customize/plugins
enum AmpPluginConfiguration {

    enum ConfigurationError: Error { case invalidBridgePath }

    static func pluginURL(homeDirectory: String, environment: [String: String]) -> URL {
        let xdg = environment["XDG_CONFIG_HOME"]
        let configRoot = xdg.flatMap { $0.hasPrefix("/") && !$0.utf8.contains(0) ? $0 : nil }
            ?? "\(homeDirectory)/.config"
        return URL(fileURLWithPath: configRoot).appendingPathComponent("amp/plugins/xisland.ts")
    }

    static func isOwnedSource(_ source: String) -> Bool {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.hasPrefix("// XIsland Amp observer. No tool.call approval or synthetic session.end.\n")
            || normalized == legacySource.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func source(bridgePath: String) throws -> String {
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0) else { throw ConfigurationError.invalidBridgePath }
        let encodedPath = String(decoding: try JSONEncoder().encode(bridgePath), as: UTF8.self)
        return #"""
        // XIsland Amp observer. No tool.call approval or synthetic session.end.
        import { spawn } from "node:child_process";

        const BRIDGE = \#(encodedPath);

        export default function (amp) {
          const children = new Set();

          function diagnose(ctx, code) {
            (ctx?.logger ?? amp.logger).log(`[XIsland] Amp observation unavailable: ${code}`);
          }

          async function report(nativeEvent, hook, hookEvent, event, ctx, data) {
            const eventThread = event?.thread?.id;
            const contextThread = ctx?.thread?.id;
            const threadID = eventThread ?? contextThread;
            if (typeof threadID !== "string" || !threadID.trim()) {
              diagnose(ctx, "missing-thread-id");
              return;
            }
            if (eventThread && contextThread && eventThread !== contextThread) {
              diagnose(ctx, "thread-id-mismatch");
              return;
            }
            const executor = ctx?.system?.executor?.kind ?? amp.system?.executor?.kind;
            if (executor && executor !== "local") {
              diagnose(ctx, "remote-executor");
              return;
            }

            let input;
            try {
              input = JSON.stringify({
                ...data,
                session_id: threadID,
                native_event: nativeEvent,
                hook_event_name: hookEvent,
                terminal: process.env.TERM_PROGRAM || "Terminal",
              });
            } catch {
              diagnose(ctx, "invalid-payload");
              return;
            }
            if (Buffer.byteLength(input, "utf8") > 16 * 1024 * 1024) {
              diagnose(ctx, "payload-too-large");
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
                if (code) diagnose(ctx, code);
                resolve();
              }
              try {
                child = spawn(BRIDGE, ["--agent", "amp", "--hook", hook, "--session", threadID], {
                  shell: false,
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

          amp.on("session.start", async (event, ctx) => {
            await report("session.start", "session_start", "SessionStart", event, ctx, {});
          });

          amp.on("agent.start", async (event, ctx) => {
            await report("agent.start", "UserPromptSubmit", "UserPromptSubmit", event, ctx, {
              prompt: event.message,
              message_id: event.id,
            });
          });

          amp.on("tool.result", async (event, ctx) => {
            if (typeof event.toolUseID !== "string" || !event.toolUseID || typeof event.tool !== "string") {
              diagnose(ctx, "invalid-tool-result");
              return;
            }
            await report("tool.result", "toolcomplete", "PostToolUse", event, ctx, {
              tool_use_id: event.toolUseID,
              tool_name: event.tool,
              tool_input: event.input,
              tool_response: event.output,
              native_status: event.status,
              error: event.error,
            });
          });

          amp.on("agent.end", async (event, ctx) => {
            await report("agent.end", "notification", "Stop", event, ctx, {
              message_id: event.id,
              native_status: event.status,
            });
          });

          amp.onDispose(() => {
            for (const child of children) child.kill("SIGKILL");
          });
        }
        """#
    }

    // 只认领旧版完整模板，避免覆盖用户编写的同名插件。
    private static let legacySource = #"""
    import { execSync } from "child_process";
    import { homedir } from "os";
    const BRIDGE = homedir() + "/.xisland/bin/di-bridge";
    function send(hookType: string, sessionId: string, data: Record<string, any>) {
      try {
        const stdin = JSON.stringify({ ...data, session_id: sessionId });
        execSync(`${BRIDGE} --agent amp --hook ${hookType} --session ${sessionId}`, {
          input: stdin, timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
        });
      } catch {}
    }
    export default {
      onSessionStart: (ctx: { sessionId: string }) => {
        send("session_start", ctx.sessionId, { terminal: process.env.TERM_PROGRAM || "Terminal" });
      },
      onSessionEnd: (ctx: { sessionId: string }) => {
        send("session_end", ctx.sessionId, {});
      },
      onAgentStart: (ctx: { sessionId: string; task: string }) => {
        send("session_start", ctx.sessionId, { prompt: ctx.task });
      },
      onAgentEnd: (ctx: { sessionId: string }) => {
        send("session_end", ctx.sessionId, {});
      },
      onToolCall: (ctx: { sessionId: string; tool: string; input: any }) => {
        send("PreToolUse", ctx.sessionId, { tool_name: ctx.tool, tool_input: ctx.input });
      },
      onToolResult: (ctx: { sessionId: string; tool: string; result: any }) => {
        send("PostToolUse", ctx.sessionId, { tool_name: ctx.tool, result: ctx.result });
      },
    };
    """#

}
