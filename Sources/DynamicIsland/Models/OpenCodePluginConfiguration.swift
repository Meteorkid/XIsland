import Foundation
import CryptoKit

enum OpenCodePluginConfiguration {
    enum ConfigurationError: Error { case invalidBridgePath }

    static func pluginURL(homeDirectory: String, environment: [String: String]) -> URL {
        let custom = environment["XDG_CONFIG_HOME"]
        let root = custom.flatMap { $0.hasPrefix("/") && !$0.utf8.contains(0) ? $0 : nil } ?? "\(homeDirectory)/.config"
        return URL(fileURLWithPath: root).appendingPathComponent("opencode/plugins/xisland.js")
    }

    static func isOwnedSource(_ source: String) -> Bool {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // 标记不能证明用户未修改文件；使用原桥接路径重建完整模板，允许安装位置迁移。
        let prefix = "const BRIDGE = "
        if let line = normalized.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }),
           line.hasSuffix(";"),
           let bridgePath = try? JSONDecoder().decode(String.self, from: Data(line.dropFirst(prefix.count).dropLast().utf8)),
           let expected = try? Self.source(bridgePath: bridgePath), normalized == expected {
            return true
        }
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return digest == "9612becd28c18847142c29f14a03e4ae16beafdde482fc33502984479f9ec9a4"
    }

    static func removingLegacyReferences(from configuration: [String: Any], pluginURLs: [URL]) -> [String: Any] {
        guard let entries = configuration["plugin"] as? [Any] else { return configuration }
        let references = Set(pluginURLs.flatMap { [$0.absoluteString, "file://" + $0.path] })
        var result = configuration
        result["plugin"] = entries.filter { entry in
            let reference = entry as? String ?? (entry as? [Any])?.first as? String
            return reference.map { !references.contains($0) } ?? true
        }
        return result
    }

    static func source(bridgePath: String) throws -> String {
        guard bridgePath.hasPrefix("/"), !bridgePath.utf8.contains(0) else { throw ConfigurationError.invalidBridgePath }
        let path = String(decoding: try JSONEncoder().encode(bridgePath), as: UTF8.self)
        return #"""
        // XIsland OpenCode native bridge v2.
        import { spawn } from "node:child_process";
        import { TextDecoder } from "node:util";
        const BRIDGE = \#(path);

        export default async function ({ client, directory }) {
          const pending = new Map(), lanes = new Map(), reports = new Map(), resolved = new Set(), closed = new Set();
          const children = new Set(), cwd = new Map(), roles = new Map(), texts = new Map(), states = new Map();
          let disposed = false;
          const valid = value => typeof value === "string" && value.trim().length > 0;
          const key = (kind, sid, id) => JSON.stringify([kind, sid, id]);
          const diagnose = code => process.stderr.write(`[XIsland] OpenCode bridge: ${code}\n`);

          function bridge(event, sid, data = {}, signal, interactive = false) {
            if (disposed || !valid(sid) || signal?.aborted || (closed.has(sid) && event !== "session.deleted")) return Promise.resolve(null);
            const work = (reports.get(sid) ?? Promise.resolve()).catch(() => null)
              .then(() => disposed ? null : runBridge(event, sid, data, signal, interactive));
            // 只等待观察消息发送完毕；审批等待本身不能挡住原端resolved事件。
            if (!interactive) {
              reports.set(sid, work);
              void work.finally(() => { if (reports.get(sid) === work) reports.delete(sid); });
            }
            return work;
          }
          function runBridge(event, sid, data, signal, interactive) {
            if (signal?.aborted) return Promise.resolve(null);
            let input;
            try {
              input = JSON.stringify({ ...data, session_id: sid, native_event: event,
                cwd: cwd.get(sid) ?? directory, terminal: process.env.TERM_PROGRAM });
            } catch { diagnose("invalid-payload"); return Promise.resolve(null); }
            if (Buffer.byteLength(input) > 16 * 1024 * 1024) { diagnose("payload-too-large"); return Promise.resolve(null); }
            return new Promise(resolve => {
              let child, timer, output = [], outputBytes = 0, settled = false;
              const finish = value => {
                if (settled) return;
                settled = true; clearTimeout(timer); output = []; outputBytes = 0;
                if (child) children.delete(child);
                resolve(value);
              };
              try {
                child = spawn(BRIDGE, ["--agent", "opencode", "--adapter", "opencode_plugin", "--hook", event], {
                  shell: false, signal, killSignal: "SIGKILL", stdio: ["pipe", "pipe", "ignore"],
                });
                children.add(child);
                child.once("error", () => finish(null));
                child.stdin.once("error", () => { child.kill("SIGKILL"); finish(null); });
                child.stdout.on("data", chunk => {
                  if (settled) return;
                  if (outputBytes + chunk.length > 1024 * 1024) { child.kill("SIGKILL"); finish(null); return; }
                  outputBytes += chunk.length;
                  output.push(chunk);
                });
                child.once("close", code => {
                  if (settled) return;
                  if (code !== 0 || signal?.aborted) return finish(null);
                  try {
                    const decoded = interactive ? new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(output, outputBytes)) : "{}";
                    finish(JSON.parse(decoded));
                  } catch { finish(null); }
                });
                timer = setTimeout(() => { child.kill("SIGKILL"); finish(null); }, interactive ? 295000 : 1500);
                child.stdin.end(input);
              } catch { if (child) child.kill("SIGKILL"); finish(null); }
            });
          }

          const current = task => !disposed && pending.get(task.key) === task && !task.controller.signal.aborted;
          const hasPending = sid => [...pending.values()].some(task => task.sid === sid);
          function remember(id) {
            resolved.add(id);
            if (resolved.size > 1000) resolved.delete(resolved.values().next().value);
          }
          async function clear(kind, sid, id) {
            if (!valid(sid) || !valid(id)) return;
            const identity = key(kind, sid, id), task = pending.get(identity);
            remember(identity);
            if (task) { pending.delete(identity); task.controller.abort(); }
            await bridge("interaction.resolved", sid, { native_request_id: id, native_request_kind: kind });
            if (!hasPending(sid)) await bridge(states.get(sid) === "idle" ? "session.idle" : "session.busy", sid);
          }
          async function nativeReply(task, body) {
            // SDK和插件事件流按注入directory隔离；会话显示目录不能改变回复路由。
            let result;
            const signal = task.controller.signal;
            const timeout = setTimeout(() => task.controller.abort(), 5000);
            try {
              if (task.kind === "permission" && typeof client?.permission?.reply === "function") {
                result = await client.permission.reply({ requestID: task.id, directory: directory, ...body }, { signal, throwOnError: true });
              } else if (task.kind === "permission" && typeof client?.postSessionIdPermissionsPermissionId === "function") {
                result = await client.postSessionIdPermissionsPermissionId({ path: { id: task.sid, permissionID: task.id },
                  query: { directory: directory }, body: { response: body.reply }, signal, throwOnError: true });
              } else if (task.kind === "question" && typeof client?.question?.reply === "function") {
                result = await client.question.reply({ requestID: task.id, directory: directory, ...body }, { signal, throwOnError: true });
              } else {
                // 当前插件注入v1 SDK。沿用该客户端的已配置transport，保留实例路由、认证与进程内fetch。
                if (typeof client?._client?.post !== "function") throw new Error("unsupported-sdk");
                result = await client._client.post({ url: `/${task.kind}/{requestID}/reply`, path: { requestID: task.id },
                  query: { directory: directory }, body, signal, throwOnError: true,
                  headers: { "Content-Type": "application/json" } });
              }
              if (result !== true && result?.data !== true) throw new Error("unconfirmed-reply");
            } finally { clearTimeout(timeout); }
          }
          async function unavailable(task) {
            if (pending.get(task.key) !== task || disposed) return;
            await bridge("interaction.resolved", task.sid, { native_request_id: task.id, native_request_kind: task.kind });
            await bridge("interaction.unavailable", task.sid, { native_request_id: task.id, native_request_kind: task.kind });
          }
          function enqueue(kind, request) {
            const sid = request.sessionID, id = request.id;
            if (!valid(sid) || !valid(id) || closed.has(sid)) return;
            const identity = key(kind, sid, id);
            if (pending.has(identity) || resolved.has(identity)) return;
            const task = { key: identity, kind, sid, id, request, controller: new AbortController() };
            pending.set(identity, task);
            const work = (lanes.get(sid) ?? Promise.resolve()).catch(() => {}).then(async () => {
              if (!current(task)) return;
              try {
                const supported = typeof client?._client?.post === "function"
                  || (kind === "permission" ? typeof client?.permission?.reply === "function" || typeof client?.postSessionIdPermissionsPermissionId === "function"
                    : typeof client?.question?.reply === "function");
                if (!supported) { await unavailable(task); return; }
                if (kind === "permission") {
                  if (!valid(request.permission) || !Array.isArray(request.patterns)) { await unavailable(task); return; }
                  task.presented = true;
                  const choice = await bridge("permission.asked", sid, { native_request_id: id, native_request_kind: kind,
                    permission: request.permission, patterns: request.patterns, metadata: request.metadata }, task.controller.signal, true);
                  if (!current(task)) return;
                  if (!choice || !["allow", "deny"].includes(choice.decision)) { await unavailable(task); return; }
                  await nativeReply(task, { reply: choice.decision === "allow" ? "once" : "reject" });
                } else {
                  const questions = request.questions;
                  if (!Array.isArray(questions) || !questions.length || questions.some(q => (q.multiple !== undefined && typeof q.multiple !== "boolean") || !valid(q.question)
                    || (q.custom !== undefined && typeof q.custom !== "boolean")
                    || !Array.isArray(q.options) || (!q.options.length && q.custom === false) || q.options.some(o => !valid(o.label))
                    || new Set(q.options.map(o => o.label)).size !== q.options.length)) { await unavailable(task); return; }
                  const answers = [];
                  for (let index = 0; index < questions.length; index++) {
                    const question = questions[index], options = question.options.map(o => o.label);
                    task.presented = true;
                    const choice = await bridge("question.asked", sid, { native_request_id: id, native_request_kind: kind,
                      question: questions.length > 1 ? `[${index + 1}/${questions.length}] ${question.question}` : question.question,
                      options, allow_custom_answer: question.custom !== false, allow_multiple_answers: question.multiple === true }, task.controller.signal, true);
                    if (!current(task)) return;
                    if (!choice) { await unavailable(task); return; }
                    if (question.multiple === true) {
                      const selected = choice.answers;
                      if (choice.answer !== undefined || !Array.isArray(selected) || !selected.length || selected.length > 128
                        || new Set(selected).size !== selected.length || selected.some(value => !valid(value) || value.includes(String.fromCharCode(0)))
                        || selected.reduce((size, value) => size + Buffer.byteLength(value, "utf8"), 0) > 8192
                        || selected.filter(value => !options.includes(value)).length > (question.custom !== false ? 1 : 0)) {
                        await unavailable(task); return;
                      }
                      answers.push(selected);
                    } else {
                      if (choice.answers !== undefined || !(options.includes(choice.answer) || (question.custom !== false && valid(choice.answer)
                        && Buffer.byteLength(choice.answer, "utf8") <= 8192 && !choice.answer.includes(String.fromCharCode(0))))) { await unavailable(task); return; }
                      answers.push([choice.answer]);
                    }
                  }
                  await nativeReply(task, { answers });
                }
                if (pending.get(identity) === task) { pending.delete(identity); remember(identity); }
              } catch { await unavailable(task); }
              finally {
                if (pending.get(identity) === task) pending.delete(identity);
              }
            });
            lanes.set(sid, work);
            void work.finally(() => { if (lanes.get(sid) === work) lanes.delete(sid); }).catch(() => diagnose("request-failed"));
          }

          async function dispose() {
            if (disposed) return;
            disposed = true;
            const visible = [...pending.values()].filter(task => task.presented);
            for (const task of pending.values()) task.controller.abort();
            for (const child of children) child.kill("SIGKILL");
            // 插件关闭也需要清理岛上的当前请求；不对原软件作批准或拒绝。
            await Promise.all(visible.map(task => runBridge("interaction.resolved", task.sid,
              { native_request_id: task.id, native_request_kind: task.kind }, undefined, false)));
            pending.clear(); cwd.clear(); roles.clear(); texts.clear(); states.clear(); resolved.clear(); closed.clear(); reports.clear();
          }
          const observe = handler => async (...args) => {
            try { await handler(...args); } catch { diagnose("unsupported-event"); }
          };
          return {
            dispose,
            "chat.message": observe(async (input, output) => {
              closed.delete(input.sessionID);
              const prompt = (output.parts ?? []).filter(p => p.type === "text" && !p.synthetic && !p.ignored).map(p => p.text).join("\n");
              await bridge("prompt.submitted", input.sessionID, { prompt, model: input.model?.modelID });
            }),
            "tool.execute.before": observe(async (input, output) => {
              await bridge("tool.started", input.sessionID, { tool_name: input.tool, tool_use_id: input.callID, tool_input: output.args });
            }),
            "tool.execute.after": observe(async (input, output) => {
              await bridge("tool.completed", input.sessionID, { tool_name: input.tool, tool_use_id: input.callID,
                tool_input: input.args, tool_response: output.output });
            }),
            event: observe(async ({ event }) => {
              if (disposed) return;
              const type = event?.type, p = event?.properties ?? {};
              if (type === "permission.asked") { enqueue("permission", p); return; }
              if (type === "question.asked") { enqueue("question", p); return; }
              if (type === "permission.replied") { await clear("permission", p.sessionID, p.requestID ?? p.permissionID); return; }
              if (type === "question.replied" || type === "question.rejected") { await clear("question", p.sessionID, p.requestID); return; }
              if (type === "session.created" || type === "session.updated") {
                if (!valid(p.info?.id)) return;
                if (type === "session.created") closed.delete(p.info.id);
                if (valid(p.info.directory)) cwd.set(p.info.id, p.info.directory);
                if (!p.info.time?.archived) { if (type === "session.created") await bridge("session.created", p.info.id); return; }
              }
              if (type === "session.deleted" || (type === "session.updated" && p.info?.time?.archived)) {
                const sid = p.info?.id;
                if (!valid(sid)) return;
                closed.add(sid);
                if (closed.size > 1000) closed.delete(closed.values().next().value);
                for (const task of [...pending.values()]) if (task.sid === sid) { pending.delete(task.key); task.controller.abort(); }
                cwd.delete(sid); texts.delete(sid); states.delete(sid);
                await bridge("session.deleted", sid); return;
              }
              if (type === "session.status" || type === "session.idle") {
                const status = type === "session.idle" ? "idle" : p.status?.type;
                if (!["idle", "busy", "retry"].includes(status)) return;
                states.set(p.sessionID, status);
                if (hasPending(p.sessionID)) return;
                await bridge(status === "idle" ? "session.idle" : "session.busy", p.sessionID); return;
              }
              if (type === "session.error") { await bridge("session.error", p.sessionID, { error: p.error?.data?.message ?? "OpenCode session error" }); return; }
              if (type === "session.compacted") { await bridge("session.compacted", p.sessionID); return; }
              if (type === "message.updated" && valid(p.info?.id)) {
                roles.set(p.info.id, p.info.role);
                if (roles.size > 1000) roles.delete(roles.keys().next().value);
                return;
              }
              if (type === "message.part.updated" && p.part?.type === "text" && roles.get(p.part.messageID) === "assistant"
                && !p.part.ignored && !p.part.synthetic && typeof p.part.text === "string" && p.part.time?.end) {
                const previous = texts.get(p.part.sessionID);
                if (previous?.messageID === p.part.messageID && previous?.partID === p.part.id && previous?.text === p.part.text) return;
                texts.set(p.part.sessionID, { messageID: p.part.messageID, partID: p.part.id, text: p.part.text });
                await bridge("assistant.message", p.part.sessionID, { message: p.part.text }); return;
              }
              if (type === "message.part.updated" && p.part?.type === "tool" && p.part.state?.status === "error") {
                await bridge("tool.failed", p.part.sessionID, { tool_name: p.part.tool, tool_use_id: p.part.callID,
                  tool_input: p.part.state.input, tool_response: p.part.state.error });
              }
            }),
          };
        }
        """#
    }
}
