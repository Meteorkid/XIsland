import Foundation

/// Kilo Code 原生插件：CLI 与 VS Code 扩展共用 `~/.config/kilo/plugin`，只观察会话与工具活动。
/// 官方文档：https://kilo.ai/docs/automate/extending/plugins
/// 不订阅 permission.ask、不修改工具参数，权限、回答与取消全部留在 Kilo 内处理。
enum KiloPluginConfiguration {
    enum ConfigurationError: Error { case invalidBridgePath }

    static func pluginURL(homeDirectory: String, environment: [String: String]) -> URL {
        let xdg = environment["XDG_CONFIG_HOME"]
        let configRoot = xdg.flatMap { $0.hasPrefix("/") && !$0.utf8.contains(0) ? $0 : nil }
            ?? "\(homeDirectory)/.config"
        return URL(fileURLWithPath: configRoot).appendingPathComponent("kilo/plugin/xisland.js")
    }

    static func isOwnedSource(_ source: String) -> Bool {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // 标记或桥接路径不能单独证明所有权；用原路径重建完整模板后逐字比较。
        let prefix = "const BRIDGE = "
        if let line = normalized.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }),
           line.hasSuffix(";"),
           let bridgePath = try? JSONDecoder().decode(String.self, from: Data(line.dropFirst(prefix.count).dropLast().utf8)),
           let expected = try? Self.source(bridgePath: bridgePath), normalized == expected {
            return true
        }
        return false
    }

    static func source(bridgePath: String) throws -> String {
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0) else { throw ConfigurationError.invalidBridgePath }
        let encodedPath = String(decoding: try JSONEncoder().encode(bridgePath), as: UTF8.self)
        return #"""
        // XIsland Kilo Code observer v1. Observation only: approvals and answers stay in Kilo.
        import { spawn } from "node:child_process";

        const BRIDGE = \#(encodedPath);
        const AGENT = "kilo_code";
        const ADAPTER = "kilo_plugin";
        const MAX_BYTES = 16 * 1024 * 1024;

        const valid = value => typeof value === "string" && value.trim().length > 0
          && value.length <= 4096 && !/[\u0000-\u001f]/.test(value);

        export default {
          id: "xisland",
          server: async ({ directory }) => {
            const children = new Set(), roles = new Map(), texts = new Map(), closed = new Set();
            let disposed = false;
            const diagnose = code => {
              try { process.stderr.write(`[XIsland] Kilo observer: ${code}\n`); } catch { /* 诊断不能影响宿主。 */ }
            };

            function report(nativeEvent, sessionID, data = {}) {
              if (disposed || !valid(sessionID)) return Promise.resolve();
              let input;
              try {
                input = JSON.stringify({ ...data, session_id: sessionID, native_event: nativeEvent,
                  cwd: data.cwd ?? directory, terminal: process.env.TERM_PROGRAM || "Terminal" });
              } catch { diagnose("invalid-payload"); return Promise.resolve(); }
              if (Buffer.byteLength(input, "utf8") > MAX_BYTES) { diagnose("payload-too-large"); return Promise.resolve(); }
              return new Promise(resolve => {
                let child, timer, settled = false;
                const finish = code => {
                  if (settled) return;
                  settled = true;
                  clearTimeout(timer);
                  if (child) children.delete(child);
                  if (code) diagnose(code);
                  resolve();
                };
                try {
                  child = spawn(BRIDGE, ["--agent", AGENT, "--adapter", ADAPTER, "--hook", nativeEvent], {
                    shell: false, stdio: ["pipe", "ignore", "ignore"],
                  });
                  children.add(child);
                  child.once("error", () => finish("spawn-error"));
                  child.once("close", code => finish(code === 0 ? null : "bridge-exit"));
                  child.stdin.once("error", () => { child.kill("SIGKILL"); finish("stdin-error"); });
                  timer = setTimeout(() => { child.kill("SIGKILL"); finish("bridge-timeout"); }, 1500);
                  child.stdin.end(input);
                } catch {
                  if (child) child.kill("SIGKILL");
                  finish("spawn-error");
                }
              });
            }

            const sidOf = input => input?.sessionID ?? input?.sessionId;
            const eventSid = properties => properties?.sessionID ?? properties?.info?.id;
            const status = (sessionID, state, text) => report("status.update", sessionID, { state, status: text });

            return {
              dispose() {
                if (disposed) return;
                disposed = true;
                for (const child of children) child.kill("SIGKILL");
                children.clear(); roles.clear(); texts.clear(); closed.clear();
              },
              "chat.message": async (input, output) => {
                const sessionID = sidOf(input);
                if (!valid(sessionID)) return;
                closed.delete(sessionID);
                const prompt = (output?.parts ?? [])
                  .filter(part => part?.type === "text" && !part.synthetic && !part.ignored && typeof part.text === "string")
                  .map(part => part.text).join("\n");
                await report("prompt.submitted", sessionID, { prompt, model: input?.model?.modelID });
              },
              "tool.execute.before": async (input, output) => {
                await report("tool.started", sidOf(input), {
                  tool_name: input?.tool, tool_use_id: input?.callID, tool_input: output?.args,
                });
              },
              "tool.execute.after": async (input, output) => {
                await report("tool.completed", sidOf(input), {
                  tool_name: input?.tool, tool_use_id: input?.callID,
                  tool_input: input?.args, tool_response: output?.output,
                });
              },
              event: async ({ event }) => {
                if (disposed || !event) return;
                const type = event.type, properties = event.properties ?? {};
                if (type === "permission.asked") {
                  await status(eventSid(properties), "waitingPermission", "请在 Kilo 处理权限请求");
                  return;
                }
                if (type === "question.asked") {
                  await status(eventSid(properties), "waitingAnswer", "请在 Kilo 回答问题");
                  return;
                }
                if (type === "session.created") {
                  const sessionID = properties.info?.id;
                  if (!valid(sessionID)) return;
                  closed.delete(sessionID);
                  await report("session.created", sessionID, { cwd: properties.info?.directory });
                  return;
                }
                if (type === "session.updated" && properties.info?.time?.archived) {
                  const sessionID = properties.info?.id;
                  if (!valid(sessionID) || closed.has(sessionID)) return;
                  closed.add(sessionID);
                  await report("session.deleted", sessionID);
                  return;
                }
                if (type === "session.deleted") {
                  const sessionID = eventSid(properties);
                  if (!valid(sessionID) || closed.has(sessionID)) return;
                  closed.add(sessionID);
                  await report("session.deleted", sessionID);
                  return;
                }
                if (type === "session.idle") {
                  await report("session.idle", eventSid(properties), { status: "Kilo 会话空闲" });
                  return;
                }
                if (type === "session.status") {
                  const state = properties.status?.type;
                  if (state === "busy" || state === "retry") {
                    await report("session.busy", eventSid(properties), { status: "Kilo 正在运行" });
                  }
                  return;
                }
                if (type === "session.error") {
                  await report("session.error", eventSid(properties),
                    { error: properties.error?.data?.message ?? "Kilo session error" });
                  return;
                }
                if (type === "session.compacted") {
                  await report("session.compacted", eventSid(properties));
                  return;
                }
                if (type === "message.updated" && valid(properties.info?.id)) {
                  roles.set(properties.info.id, properties.info.role);
                  if (roles.size > 1000) roles.delete(roles.keys().next().value);
                  return;
                }
                if (type === "message.part.updated" && properties.part?.type === "text"
                  && roles.get(properties.part.messageID) === "assistant"
                  && !properties.part.ignored && !properties.part.synthetic
                  && typeof properties.part.text === "string" && properties.part.time?.end) {
                  const key = `${properties.part.messageID}\u0000${properties.part.id}`;
                  if (texts.get(key) === properties.part.text) return;
                  texts.set(key, properties.part.text);
                  if (texts.size > 1000) texts.delete(texts.keys().next().value);
                  await report("assistant.message", properties.part.sessionID, { message: properties.part.text });
                  return;
                }
                if (type === "message.part.updated" && properties.part?.type === "tool"
                  && properties.part.state?.status === "error") {
                  await report("tool.failed", properties.part.sessionID, {
                    tool_name: properties.part.tool, tool_use_id: properties.part.callID,
                    tool_input: properties.part.state.input, tool_response: properties.part.state.error,
                  });
                }
              },
            };
          },
        };
        """#
    }
}
