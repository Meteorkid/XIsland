import Foundation
import DIShared

enum HookInstallStatus {
    case active
    case inactive
}

enum ZeroConfigManager {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let autoConfigKeyPrefix = "autoConfigure."

    static func configureAllAgents() {
        syncCommandLineTools()
        for agent in AgentType.allCases where isAutoConfigEnabled(for: agent) {
            configure(agent)
        }
        print("[ZeroConfig] Agent hooks configured")
    }

    static func configure(_ agent: AgentType) {
        switch agent {
        case .claudeCode: configureClaudeCode()
        case .codex: configureCodex()
        case .geminiCli: configureGeminiCli()
        case .cursor: configureCursor()
        case .trae: configureCursor()
        case .openCode: configureOpenCode()
        case .droid: configureDroid()
        case .qoder: configureQoder()
        case .copilot: configureCopilot()
        case .codeBuddy: configureCodeBuddy()
        case .qwen: configureQwen()
        case .kimi: configureKimi()
        case .deepseek: configureDeepSeek()
        case .kiro: configureKiro()
        case .amp: configureAmp()
        case .pi: configurePi()
        case .hermes: configureHermes()
        case .glm: configureGLM()
        }
    }

    static func isAutoConfigEnabled(for agent: AgentType) -> Bool {
        let defaults = UserDefaults.standard
        let key = autoConfigKey(for: agent)
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    static func setAutoConfigEnabled(_ enabled: Bool, for agent: AgentType) {
        UserDefaults.standard.set(enabled, forKey: autoConfigKey(for: agent))
        if enabled {
            configure(agent)
        } else {
            removeConfiguration(for: agent)
        }
    }

    static func hookStatus(for agent: AgentType) -> HookInstallStatus {
        hasConfiguration(for: agent) ? .active : .inactive
    }

    static func repairHooksIfNeeded() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Check Claude Code hooks
        let claudeSettings = "\(home)/.claude/settings.json"
        if isAutoConfigEnabled(for: .claudeCode), FileManager.default.fileExists(atPath: claudeSettings) {
            if let settings = readJSON(claudeSettings),
               let hooks = settings["hooks"] as? [String: Any] {
                let hasDIBridge = hooks.values.contains { hookList in
                    guard let list = hookList as? [[String: Any]] else { return false }
                    return list.contains { entry in
                        let cmds = entry["hooks"] as? [[String: Any]] ?? []
                        return cmds.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
                    }
                }
                if !hasDIBridge {
                    configureClaudeCode()
                    print("[ZeroConfig] Repaired Claude Code hooks")
                }
            }
        }

        // Check Cursor-family hooks (Cursor / Trae / Trae CN)
        if isAutoConfigEnabled(for: .cursor) || isAutoConfigEnabled(for: .trae) {
            for hooksPath in cursorHookPaths {
                guard FileManager.default.fileExists(atPath: hooksPath) else { continue }
                if let config = readJSON(hooksPath),
                   let hooks = config["hooks"] as? [String: Any] {
                    let hasDIBridge = hooks.values.contains { entries in
                        guard let list = entries as? [[String: Any]] else { return false }
                        return list.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
                    }
                    if !hasDIBridge {
                        configureCursor()
                        print("[ZeroConfig] Repaired Cursor-family hooks at \(hooksPath)")
                        break
                    }
                }
            }
        }
    }

    private static var bridgePath: String {
        let stable = "\(home)/.xisland/bin/di-bridge"
        let bundled = Bundle.main.bundlePath + "/Contents/MacOS/di-bridge"
        syncBundledFileIfNeeded(bundled: bundled, stable: stable)
        return stable
    }

    private static func syncCommandLineTools() {
        let binDir = "\(home)/.xisland/bin"
        ensureDir(binDir)
        ensureDir("\(binDir)/lib")

        syncBundledFileIfNeeded(
            bundled: Bundle.main.bundlePath + "/Contents/MacOS/di-bridge",
            stable: "\(binDir)/di-bridge"
        )
        syncBundledFileIfNeeded(
            bundled: Bundle.main.bundlePath + "/Contents/Resources/cli/xisland",
            stable: "\(binDir)/xisland"
        )
        syncBundledFileIfNeeded(
            bundled: Bundle.main.bundlePath + "/Contents/Resources/cli/lib/xisland-cli.sh",
            stable: "\(binDir)/lib/xisland-cli.sh"
        )
    }

    private static func syncBundledFileIfNeeded(bundled: String, stable: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundled) else { return }

        ensureDir((stable as NSString).deletingLastPathComponent)

        let shouldCopy: Bool
        if fm.fileExists(atPath: stable),
           let stableAttr = try? fm.attributesOfItem(atPath: stable),
           let bundledAttr = try? fm.attributesOfItem(atPath: bundled),
           let stableMod = stableAttr[.modificationDate] as? Date,
           let bundledMod = bundledAttr[.modificationDate] as? Date {
            shouldCopy = bundledMod > stableMod
        } else {
            shouldCopy = true
        }

        guard shouldCopy else { return }
        try? fm.removeItem(atPath: stable)
        try? fm.copyItem(atPath: bundled, toPath: stable)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stable)
    }

    // MARK: - Claude Code

    private static func configureClaudeCode() {
        let configDir = "\(home)/.claude"
        let settingsPath = "\(configDir)/settings.json"
        ensureDir(configDir)

        var settings = readJSON(settingsPath) ?? [String: Any]()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookMapping: [(String, String, Int)] = [
            ("PreToolUse", "PreToolUse", 5),
            ("PostToolUse", "PostToolUse", 5),
            ("PreCompact", "compact", 5),
            ("Notification", "Notification", 5),
            ("PermissionRequest", "PermissionRequest", 300),
            ("Stop", "Stop", 5),
            ("SessionStart", "session_start", 5),
            ("SessionEnd", "session_end", 5),
            ("SubagentStart", "subagent_start", 5),
            ("SubagentStop", "subagent_end", 5),
            ("UserPromptSubmit", "session_start", 5),
        ]

        for (hookType, hookArg, timeout) in hookMapping {
            var hookList = hooks[hookType] as? [[String: Any]] ?? []

            hookList.removeAll { entry in
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                return cmds.contains {
                    guard let cmd = $0["command"] as? String else { return false }
                    return cmd.contains("di-bridge")
                }
            }

            let alreadyConfigured = false
            if !alreadyConfigured {
                // PermissionRequest must preserve di-bridge exit code so deny works;
                // other hooks are fire-and-forget so || true is safe.
                let guardedCmd: String
                if hookArg == "PermissionRequest" {
                    guardedCmd = "\(bridgePath) --agent claude_code --hook \(hookArg)"
                } else {
                    guardedCmd = "\(bridgePath) --agent claude_code --hook \(hookArg) || true"
                }
                hookList.append([
                    "matcher": "*",
                    "hooks": [
                        [
                            "type": "command",
                            "command": guardedCmd,
                            "timeout": timeout
                        ] as [String: Any]
                    ]
                ] as [String: Any])
                hooks[hookType] = hookList
            }
        }

        settings["hooks"] = hooks
        writeJSON(settingsPath, settings)
    }

    // MARK: - Codex

    private static func configureCodex() {
        let configDir = "\(home)/.codex"
        ensureDir(configDir)

        let hooksPath = "\(configDir)/hooks.json"
        var config = readJSON(hooksPath) ?? [String: Any]()
        var hooks = config["hooks"] as? [String: Any] ?? [:]

        // Remove stale di-bridge entries with wrong event names
        for staleKey in ["ToolUse", "PatchApply"] {
            if var hookList = hooks[staleKey] as? [[String: Any]] {
                hookList.removeAll { entry in
                    let cmds = entry["hooks"] as? [[String: Any]] ?? []
                    return cmds.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
                }
                if hookList.isEmpty {
                    hooks.removeValue(forKey: staleKey)
                } else {
                    hooks[staleKey] = hookList
                }
            }
        }

        // Codex fires Stop after every agent response (not just session end),
        // so we map it to notification instead of session_end to capture assistant replies.
        let hookMapping: [(String, String, Int)] = [
            ("SessionStart", "session_start", 5),
            ("PreToolUse", "PreToolUse", 5),
            ("PostToolUse", "PostToolUse", 5),
            ("UserPromptSubmit", "session_start", 5),
            ("PermissionRequest", "PermissionRequest", 300),
            ("Stop", "notification", 5),
        ]

        for (hookType, hookArg, timeout) in hookMapping {
            var hookList = hooks[hookType] as? [[String: Any]] ?? []
            hookList.removeAll { entry in
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                return cmds.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
            }
            hookList.append([
                "matcher": "*",
                "hooks": [
                    [
                        "type": "command",
                        "command": "\(bridgePath) --agent codex --hook \(hookArg)",
                        "timeout": timeout
                    ] as [String: Any]
                ]
            ] as [String: Any])
            hooks[hookType] = hookList
        }

        config["hooks"] = hooks
        writeJSON(hooksPath, config)
    }

    // MARK: - Gemini CLI

    private static func configureGeminiCli() {
        let configDir = "\(home)/.gemini"
        let settingsPath = "\(configDir)/settings.json"
        ensureDir(configDir)

        var settings = readJSON(settingsPath) ?? [String: Any]()
        if (settings["xisland_hook"] as? String)?.contains("di-bridge") != true {
            settings["xisland_hook"] = "\(bridgePath) --agent gemini_cli"
            writeJSON(settingsPath, settings)
        }
    }

    // MARK: - Cursor

    private static func configureCursor() {
        for hooksPath in cursorHookPaths {
            ensureDir((hooksPath as NSString).deletingLastPathComponent)
            let config = readJSON(hooksPath) ?? [String: Any]()
            let updatedConfig = sanitizeCursorConfig(config, bridgePath: bridgePath)
            writeJSON(hooksPath, updatedConfig)
        }

        configureTraeIDEClaudeCodeHooks()
    }

    static func sanitizeCursorConfig(_ config: [String: Any], bridgePath: String) -> [String: Any] {
        var config = config
        var hooks = config["hooks"] as? [String: Any] ?? [:]

        if let dynamicIslandCommand = config["dynamic_island"] as? String,
           isLegacyCursorHookCommand(dynamicIslandCommand) {
            config.removeValue(forKey: "dynamic_island")
        }

        let hookMapping: [(String, String)] = [
            ("beforeSubmitPrompt", "--hook session_start"),
            ("afterAgentResponse", "--hook notification"),
            ("afterAgentThought", "--hook notification"),
            ("beforeReadFile", "--hook PreToolUse --tool Read"),
            ("afterFileEdit", "--hook PostToolUse --tool FileEdit"),
            ("beforeShellExecution", "--hook PreToolUse --tool Shell"),
            ("afterShellExecution", "--hook PostToolUse --tool Shell"),
            ("beforeMCPExecution", "--hook PreToolUse --tool MCP"),
            ("afterMCPExecution", "--hook PostToolUse --tool MCP"),
            ("stop", "--hook session_end"),
        ]

        for (event, hookArgs) in hookMapping {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { isLegacyCursorHookCommand($0["command"] as? String) }
            entries.append(["command": "\(bridgePath) --agent cursor \(hookArgs)"])
            hooks[event] = entries
        }

        if let oldEntries = hooks["preToolUse"] as? [[String: Any]] {
            let cleaned = oldEntries.filter {
                !isLegacyCursorHookCommand($0["command"] as? String)
            }
            hooks["preToolUse"] = cleaned
        }

        config["hooks"] = hooks
        if config["version"] == nil { config["version"] = 1 }
        return config
    }

    private static func configureTraeIDEClaudeCodeHooks() {
        for settingsPath in traeIDESettingsPaths where FileManager.default.fileExists(atPath: settingsPath) {
            let config = readJSON(settingsPath) ?? [String: Any]()
            let hooks = config["claudeCode.hooks"] as? [String: Any] ?? [:]
            var updatedConfig = config
            updatedConfig["claudeCode.hooks"] = sanitizeClaudeCodeHooksForIDE(
                hooks,
                bridgePath: bridgePath,
                agent: AgentType.cursor.rawValue
            )
            writeJSON(settingsPath, updatedConfig)
        }
    }

    static func sanitizeClaudeCodeHooksForIDE(_ hooks: [String: Any], bridgePath: String, agent: String) -> [String: Any] {
        var hooks = hooks

        let hookMapping: [(String, String, Int)] = [
            ("PreToolUse", "PreToolUse", 5),
            ("PostToolUse", "PostToolUse", 5),
            ("PreCompact", "compact", 5),
            ("Notification", "Notification", 5),
            ("PermissionRequest", "PermissionRequest", 300),
            ("Stop", "session_end", 5),
            ("SessionStart", "session_start", 5),
            ("SessionEnd", "session_end", 5),
            ("SubagentStart", "subagent_start", 5),
            ("SubagentStop", "subagent_end", 5),
            ("UserPromptSubmit", "session_start", 5)
        ]

        for (hookType, hookArg, timeout) in hookMapping {
            var entries = hooks[hookType] as? [[String: Any]] ?? []
            entries.removeAll { entry in
                let commands = entry["hooks"] as? [[String: Any]] ?? []
                return commands.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
            }

            let command: String
            if hookArg == "PermissionRequest" {
                command = "\(bridgePath) --agent \(agent) --hook \(hookArg)"
            } else {
                command = "\(bridgePath) --agent \(agent) --hook \(hookArg) || true"
            }

            entries.append([
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": timeout
                ]]
            ])

            hooks[hookType] = entries
        }

        return hooks
    }

    private static func isLegacyCursorHookCommand(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("di-bridge") || command.contains("codeisland-state.py")
    }

    // MARK: - OpenCode
    // OpenCode uses a JS plugin system. The plugin uses di-bridge for fire-and-forget events,
    // and async spawn + internalFetch for bidirectional permission/question interaction
    // (reference: vibe-island plugin architecture).
    private static func configureOpenCode() {
        let pluginDir = "\(home)/.config/opencode/plugins"
        let pluginPath = "\(pluginDir)/xisland.js"
        ensureDir(pluginDir)

        let pluginSource = #"""
        import { spawn, execSync } from "child_process";
        import { homedir } from "os";
        const BRIDGE = homedir() + "/.xisland/bin/di-bridge";
        function sendViaBridge(hookType, sessionId, data) {
          try {
            const stdin = JSON.stringify({ ...data, session_id: sessionId });
            execSync(`${BRIDGE} --agent opencode --hook ${hookType} --session ${sessionId}`, {
              input: stdin, timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
            });
          } catch {}
        }
        function sendInteractive(hookType, sessionId, data) {
          return new Promise((resolve) => {
            try {
              const child = spawn(BRIDGE, ["--agent","opencode","--hook",hookType,"--session",sessionId],
                { stdio: ["pipe","pipe","pipe"] });
              child.stdin.write(JSON.stringify(data)); child.stdin.end();
              let stdout = "";
              child.stdout.on("data", (d) => { stdout += d.toString(); });
              child.on("close", (code) => resolve({ exitCode: code, output: stdout.trim() }));
              child.on("error", () => resolve(null));
              setTimeout(() => { child.kill(); resolve(null); }, 300000);
            } catch { resolve(null); }
          });
        }
        // One active question bridge per session; kill the old one when a newer event
        // arrives so only the latest rid ever gets replied to.
        const activeQ = new Map();
        // After the user answers, cache the answer briefly so that follow-up duplicate
        // events (same question, same options) from OpenCode get auto-replied without
        // showing the question panel again.
        const answeredQ = new Map(); // sid -> { answer, opts, ts }
        const answeringQ = new Set(); // sids with an active askSequentially loop
        export default async ({ client, serverUrl }) => {
          const serverPort = serverUrl ? parseInt(serverUrl.port) || 4096 : 4096;
          const internalFetch = client?._client?.getConfig?.()?.fetch || null;
          const msgRoles = new Map(), sessions = new Map(), sessionCwd = new Map();
          function getSession(sid) {
            if (!sessions.has(sid)) sessions.set(sid, { lastUserText: "", lastAssistantText: "" });
            return sessions.get(sid);
          }
          function handleEvent(ev) {
            const t = ev.type, p = ev.properties || {};
            if (t === "session.created" && p.info) {
              sessionCwd.set(p.info.id, p.info.directory || "");
              sendViaBridge("session_start", `opencode-${p.info.id}`, { cwd: p.info.directory || "", terminal: process.env.TERM_PROGRAM || "Terminal" });
              return;
            }
            if (t === "session.deleted" && p.info) { sessions.delete(p.info.id); sessionCwd.delete(p.info.id); sendViaBridge("session_end", `opencode-${p.info.id}`, {}); return; }
            if (t === "session.updated" && p.info) {
              if (p.info.directory) sessionCwd.set(p.info.id, p.info.directory);
              if (p.info.time?.archived) { sessions.delete(p.info.id); sessionCwd.delete(p.info.id); sendViaBridge("session_end", `opencode-${p.info.id}`, {}); }
              return;
            }
            if (t === "permission.asked" && p.id && p.sessionID) {
              const rid = p.id, sid = `opencode-${p.sessionID}`;
              const permRaw = (p.permission||"unknown");
              const perm = permRaw.toLowerCase();
              const tn = permRaw.charAt(0).toUpperCase()+permRaw.slice(1);
              const pts = p.patterns||[];
              let desc = tn;
              if (p.permission==="bash"&&pts.length) desc = "Run: "+pts.join(" && ");
              else if ((p.permission==="edit"||p.permission==="write")&&pts.length) desc = tn+": "+pts[0];
              else if (pts.length) desc = tn+": "+pts.join(", ");
              const questionLike = perm.includes("ask") || perm.includes("question") || perm.includes("input");
              if (questionLike) {
                const opts = pts.filter(Boolean).map(String);
                if (internalFetch) {
                  sendInteractive("question", sid, { question: desc || "Question", options: opts });
                } else {
                  sendViaBridge("question", sid, { question: desc || "Question", options: opts });
                }
                return;
              }
              if ((perm === "unknown" || perm === "") && !pts.length) {
                return;
              }
              if (internalFetch) {
                sendInteractive("PermissionRequest", sid, { tool_name:tn, description:desc, file_path:pts[0]||"" })
                  .then(async (r)=>{ if(!r)return; try{ await internalFetch(new Request(`http://localhost:${serverPort}/permission/${rid}/reply`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({reply:r.exitCode===0?"once":"reject"})}));}catch{} });
              } else { sendViaBridge("PermissionRequest", sid, { tool_name:tn, description:desc, file_path:pts[0]||"" }); }
              return;
            }
            if (t === "permission.replied" && p.sessionID) { sendViaBridge("PostToolUse",`opencode-${p.sessionID}`,{tool_name:"Permission"}); return; }
            if (t === "question.asked" && p.id && p.sessionID) {
              const rid = p.id, sid = `opencode-${p.sessionID}`;
              const qs = p.questions||[];
              const allQt = qs.map(q=>q.question||q.header||"").filter(Boolean).join("\n");
              if (!allQt.trim() || (allQt.trim() === "Question" && !qs.some(q=>(q.options||[]).length))) return;
              if (!internalFetch) {
                const opts = qs.flatMap(q=>(q.options||[]).map(o=>o.label||o.description||"")).filter(Boolean);
                sendViaBridge("question", sid, { question:allQt, options:opts });
                return;
              }
              // If we're already walking through a multi-question batch for this
              // session, ignore the re-fired event from OpenCode.
              if (answeringQ.has(sid)) {
                return;
              }
              // Dedup: if we just answered the exact same batch, auto-reply.
              const prev = answeredQ.get(sid);
              const allOpts = qs.flatMap(q=>(q.options||[]).map(o=>o.label||o.description||"")).filter(Boolean);
              if (prev && Date.now()-prev.ts < 2000 && prev.rid === rid) return;
              // Kill any previous bridge for this session.
              const prevBridge = activeQ.get(sid);
              if (prevBridge) { try { prevBridge.kill("SIGTERM"); } catch {} activeQ.delete(sid); }
              // Walk through questions one at a time via X Island.
              async function askSequentially() {
                answeringQ.add(sid);
                try {
                  const answers = [];
                  for (let i = 0; i < qs.length; i++) {
                    const q = qs[i];
                    const qText = (q.header ? q.header + ": " : "") + (q.question || "");
                    const qOpts = (q.options||[]).map(o=>o.label||o.description||"").filter(Boolean);
                    if (!qText.trim() && !qOpts.length) { answers.push([""]); continue; }
                    const label = qs.length > 1 ? `[${i+1}/${qs.length}] ${qText}` : qText;
                    const answer = await new Promise((resolve) => {
                      const child = spawn(BRIDGE, ["--agent","opencode","--hook","question","--session",sid], { stdio:["pipe","pipe","pipe"] });
                      activeQ.set(sid, child);
                      child.stdin.write(JSON.stringify({ question: label, options: qOpts })); child.stdin.end();
                      let out = "";
                      child.stdout.on("data", d => { out += d.toString(); });
                      child.on("close", () => { if (activeQ.get(sid)===child) activeQ.delete(sid); resolve(out.trim()); });
                      child.on("error", () => { if (activeQ.get(sid)===child) activeQ.delete(sid); resolve(""); });
                      setTimeout(() => { try { child.kill(); } catch {} }, 300000);
                    });
                    if (!answer) return;
                    answers.push([answer]);
                  }
                  answeredQ.set(sid, { rid, opts: allOpts, ts: Date.now() });
                  try { await internalFetch(new Request(`http://localhost:${serverPort}/question/${rid}/reply`, { method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify({answers}) })); } catch {}
                } finally { answeringQ.delete(sid); }
              }
              askSequentially().catch(()=>{ answeringQ.delete(sid); });
              return;
            }
            if ((t==="question.replied"||t==="question.rejected") && p.sessionID) { sendViaBridge("notification",`opencode-${p.sessionID}`,{status:t==="question.replied"?"Question answered":"Question dismissed"}); return; }
            if (t === "message.updated" && p.info?.id && p.info?.sessionID) { msgRoles.set(p.info.id, { role: p.info.role, sessionID: p.info.sessionID }); if (msgRoles.size > 200) msgRoles.delete(msgRoles.keys().next().value); return; }
            if (t === "message.part.updated" && p.part?.type === "text" && p.part?.messageID) {
              const meta = msgRoles.get(p.part.messageID); if (!meta) return;
              const s = getSession(meta.sessionID), text = p.part.text || "";
              if (meta.role === "user" && text) { s.lastUserText = text; sendViaBridge("session_start", `opencode-${meta.sessionID}`, { prompt: text, cwd: sessionCwd.get(meta.sessionID) || "", terminal: process.env.TERM_PROGRAM || "Terminal" }); }
              else if (meta.role === "assistant" && text) { s.lastAssistantText = text; sendViaBridge("notification", `opencode-${meta.sessionID}`, { status: text }); }
              return;
            }
            if (t === "message.part.updated" && p.part?.type === "tool" && p.part?.sessionID) {
              const st = p.part.state?.status, toolName = (p.part.tool || "unknown").charAt(0).toUpperCase() + (p.part.tool || "unknown").slice(1);
              if (st === "running" || st === "pending") sendViaBridge("PreToolUse", `opencode-${p.part.sessionID}`, { tool_name: toolName, tool_input: p.part.state?.input || {} });
              else if (st === "completed" || st === "error") sendViaBridge("PostToolUse", `opencode-${p.part.sessionID}`, { tool_name: toolName });
              return;
            }
            if (t === "session.status" && p.sessionID && p.status?.type === "idle") {
              const s = getSession(p.sessionID);
              sendViaBridge("notification", `opencode-${p.sessionID}`, { status: "idle", message: s.lastAssistantText || "idle" });
            }
          }
          return { "event": async ({ event }) => { try { handleEvent(event); } catch {} } };
        };
        """#

        try? pluginSource.write(toFile: pluginPath, atomically: true, encoding: String.Encoding.utf8)

        let configPath = "\(home)/.config/opencode/config.json"
        let pluginURL = "file://\(pluginPath)"
        var config = readJSON(configPath) ?? ["$schema": "https://opencode.ai/config.json"]
        var plugins = config["plugin"] as? [String] ?? []
        if !plugins.contains(pluginURL) {
            plugins.removeAll { ($0 as? String)?.contains("xisland") == true || ($0 as? String)?.contains("open-island") == true || ($0 as? String)?.contains("dynamic-island") == true || ($0 as? String)?.contains("vibe-island") == true }
            plugins.append(pluginURL)
            config["plugin"] = plugins
            writeJSON(configPath, config)
        }
    }

    // MARK: - Droid

    private static func configureDroid() {
        let configDir = "\(home)/.droid"
        let configPath = "\(configDir)/config.json"
        ensureDir(configDir)

        var config = readJSON(configPath) ?? [String: Any]()
        if (config["xisland_hook"] as? String)?.contains("di-bridge") != true {
            config["xisland_hook"] = "\(bridgePath) --agent droid"
            writeJSON(configPath, config)
        }
    }

    // MARK: - Qoder

    private static func configureQoder() {
        let configDir = "\(home)/.qoder"
        let configPath = "\(configDir)/config.json"
        ensureDir(configDir)

        var config = readJSON(configPath) ?? [String: Any]()
        if (config["xisland_hook"] as? String)?.contains("di-bridge") != true {
            config["xisland_hook"] = "\(bridgePath) --agent qoder"
            writeJSON(configPath, config)
        }
    }

    // MARK: - Copilot

    private static func configureCopilot() {
        let configDir = "\(home)/.copilot"
        let configPath = "\(configDir)/config.json"
        ensureDir(configDir)

        var config = readJSON(configPath) ?? [String: Any]()
        if (config["xisland_hook"] as? String)?.contains("di-bridge") != true {
            config["xisland_hook"] = "\(bridgePath) --agent copilot"
            writeJSON(configPath, config)
        }
    }

    // MARK: - CodeBuddy

    private static func configureCodeBuddy() {
        let configDir = "\(home)/.codebuddy"
        let configPath = "\(configDir)/config.json"
        ensureDir(configDir)

        var config = readJSON(configPath) ?? [String: Any]()
        if (config["xisland_hook"] as? String)?.contains("di-bridge") != true {
            config["xisland_hook"] = "\(bridgePath) --agent code_buddy"
            writeJSON(configPath, config)
        }
    }

    // MARK: - Qwen Code

    private static func configureQwen() {
        let configDir = "\(home)/.qwen"
        let settingsPath = "\(configDir)/settings.json"
        ensureDir(configDir)

        var settings = readJSON(settingsPath) ?? [String: Any]()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookMapping: [(String, String, Int)] = [
            ("PreToolUse", "PreToolUse", 5),
            ("PostToolUse", "PostToolUse", 5),
            ("UserPromptSubmit", "session_start", 5),
            ("SessionStart", "session_start", 5),
            ("SessionEnd", "session_end", 5),
            ("Stop", "notification", 5),
            ("SubagentStart", "subagent_start", 5),
            ("SubagentStop", "subagent_end", 5),
            ("PreCompact", "compact", 5),
            ("Notification", "Notification", 5),
            ("PermissionRequest", "PermissionRequest", 300),
        ]

        for (hookType, hookArg, timeout) in hookMapping {
            var hookList = hooks[hookType] as? [[String: Any]] ?? []

            hookList.removeAll { entry in
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                return cmds.contains {
                    guard let cmd = $0["command"] as? String else { return false }
                    return cmd.contains("di-bridge")
                }
            }

            let guardedCmd: String
            if hookArg == "PermissionRequest" {
                guardedCmd = "\(bridgePath) --agent qwen --hook \(hookArg)"
            } else {
                guardedCmd = "\(bridgePath) --agent qwen --hook \(hookArg) || true"
            }
            hookList.append([
                "matcher": "*",
                "hooks": [
                    [
                        "type": "command",
                        "command": guardedCmd,
                        "timeout": timeout
                    ] as [String: Any]
                ]
            ] as [String: Any])
            hooks[hookType] = hookList
        }

        settings["hooks"] = hooks
        writeJSON(settingsPath, settings)
    }

    // MARK: - Kimi Code

    private static func configureKimi() {
        let configDir = "\(home)/.kimi"
        let configPath = "\(configDir)/config.toml"
        ensureDir(configDir)

        let hookMapping: [(String, String, Int)] = [
            ("PreToolUse", "PreToolUse", 5),
            ("PostToolUse", "PostToolUse", 5),
            ("UserPromptSubmit", "session_start", 5),
            ("SessionStart", "session_start", 5),
            ("SessionEnd", "session_end", 5),
            ("Stop", "notification", 5),
            ("SubagentStart", "subagent_start", 5),
            ("SubagentStop", "subagent_end", 5),
            ("PreCompact", "compact", 5),
            ("Notification", "Notification", 5),
            ("PermissionRequest", "PermissionRequest", 300),
        ]

        var toml = ""
        if let existing = try? String(contentsOfFile: configPath, encoding: .utf8) {
            toml = existing
        }

        // Remove existing xisland hooks block
        if let range = toml.range(of: "# X Island hooks") {
            let rest = toml[range.lowerBound...]
            if let nextSection = rest.range(of: "\n[", options: .literal, range: rest.index(after: range.lowerBound)..<rest.endIndex) {
                toml.removeSubrange(range.lowerBound..<nextSection.lowerBound)
            } else {
                toml.removeSubrange(range.lowerBound...)
            }
        }

        toml += "\n# X Island hooks\n"
        for (hookType, hookArg, timeout) in hookMapping {
            let guardedCmd: String
            if hookArg == "PermissionRequest" {
                guardedCmd = "\(bridgePath) --agent kimi --hook \(hookArg)"
            } else {
                guardedCmd = "\(bridgePath) --agent kimi --hook \(hookArg) || true"
            }
            toml += """
            [[hooks]]
            event = "\(hookType)"
            command = "\(guardedCmd)"
            matcher = "*"
            timeout = \(timeout)

            """
        }

        try? toml.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - DeepSeek-TUI

    private static func configureDeepSeek() {
        let configDir = "\(home)/.deepseek"
        let configPath = "\(configDir)/config.toml"
        ensureDir(configDir)

        let hookMapping: [(String, String)] = [
            ("session_start", "session_start"),
            ("session_end", "session_end"),
            ("message_submit", "session_start"),
            ("tool_call_before", "PreToolUse"),
            ("tool_call_after", "PostToolUse"),
            ("mode_change", "notification"),
            ("on_error", "notification"),
        ]

        var toml = ""
        if let existing = try? String(contentsOfFile: configPath, encoding: .utf8) {
            toml = existing
        }

        // Remove existing xisland hooks block
        if let range = toml.range(of: "# X Island hooks") {
            let rest = toml[range.lowerBound...]
            if let nextSection = rest.range(of: "\n[", options: .literal, range: rest.index(after: range.lowerBound)..<rest.endIndex) {
                toml.removeSubrange(range.lowerBound..<nextSection.lowerBound)
            } else {
                toml.removeSubrange(range.lowerBound...)
            }
        }

        // Ensure global hooks enabled
        if !toml.contains("[hooks]") {
            toml += "\n[hooks]\nenabled = true\n"
        }

        toml += "\n# X Island hooks\n"
        for (event, hookArg) in hookMapping {
            toml += """
            [[hooks.hooks]]
            name = "xisland_\(event)"
            event = "\(event)"
            command = "\(bridgePath) --agent deepseek --hook \(hookArg) || true"
            condition = "*"

            """
        }

        try? toml.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Kiro

    private static func configureKiro() {
        // Kiro is a VS Code-based AI IDE, not a CLI tool.
        // It uses Shell Command actions via the .kiro/ directory configured through the UI.
        // Full IDE integration is complex and requires manual user setup.
        // This method is a placeholder documenting the limitation.
        print("[ZeroConfig] Kiro does not support automatic hook injection. Please configure Shell Command actions manually in the Kiro IDE.")
    }

    // MARK: - Amp

    private static func configureAmp() {
        let pluginDir = "\(home)/.config/amp/plugins"
        let pluginPath = "\(pluginDir)/xisland.ts"
        ensureDir(pluginDir)

        let pluginSource = #"""
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

        try? pluginSource.write(toFile: pluginPath, atomically: true, encoding: String.Encoding.utf8)

        // Amp loads plugins from .amp/plugins/*.ts automatically if present.
        // No additional config registration needed for basic file-based plugins.
    }

    // MARK: - Pi Agent

    private static func configurePi() {
        let extDir = "\(home)/.pi/agent/extensions"
        let extPath = "\(extDir)/xisland.ts"
        ensureDir(extDir)

        let extSource = #"""
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

        try? extSource.write(toFile: extPath, atomically: true, encoding: String.Encoding.utf8)

        // Pi Agent loads extensions from ~/.pi/agent/extensions/*.ts automatically.
    }

    // MARK: - Hermes

    private static func configureHermes() {
        // Hermes does not have a formal hook system.
        // It only supports MCP / Quick Commands / Skills as indirect integration points.
        // We create a simple wrapper script that users can invoke via Quick Commands.
        let wrapperDir = "\(home)/.xisland/bin"
        let wrapperPath = "\(wrapperDir)/hermes-bridge"
        ensureDir(wrapperDir)

        let wrapper = #"""
        #!/bin/bash
        # Hermes X Island bridge wrapper
        # Usage: hermes-bridge <hook> [session_id]
        # Add this to Hermes Quick Commands to forward events to X Island.
        HOOK="${1:-notification}"
        SESSION="${2:-hermes-$(pwd)}"
        echo '{}' | /Users/$USER/.xisland/bin/di-bridge --agent hermes --hook "$HOOK" --session "$SESSION"
        """#

        try? wrapper.write(toFile: wrapperPath, atomically: true, encoding: String.Encoding.utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)

        print("[ZeroConfig] Hermes wrapper installed at \(wrapperPath). Add it to Hermes Quick Commands for manual integration.")
    }

    private static func configureGLM() {
        // GLM (Zhipu AI) uses TOML config at ~/.zhipu/config.toml
        let dir = "\(home)/.zhipu"
        let configPath = "\(dir)/config.toml"
        ensureDir(dir)

        let block = """
        # X Island hooks — managed by X Island
        [[hooks]]
        name = "xisland_session_start"
        command = "~/.xisland/bin/di-bridge --agent glm --hook session_start --session glm-$(pwd | md5)"
        events = ["SessionStart"]

        [[hooks]]
        name = "xisland_session_end"
        command = "~/.xisland/bin/di-bridge --agent glm --hook session_end --session glm-$(pwd | md5)"
        events = ["SessionEnd"]

        [[hooks]]
        name = "xisland_tool_start"
        command = "~/.xisland/bin/di-bridge --agent glm --hook tool_start --session glm-$(pwd | md5)"
        events = ["PreToolUse"]

        [[hooks]]
        name = "xisland_tool_complete"
        command = "~/.xisland/bin/di-bridge --agent glm --hook tool_complete --session glm-$(pwd | md5)"
        events = ["PostToolUse"]

        [[hooks]]
        name = "xisland_permission"
        command = "~/.xisland/bin/di-bridge --agent glm --hook permission_request --session glm-$(pwd | md5)"
        events = ["PermissionRequest"]

        [[hooks]]
        name = "xisland_question"
        command = "~/.xisland/bin/di-bridge --agent glm --hook question --session glm-$(pwd | md5)"
        events = ["AskUserQuestion"]
        """

        if let existing = try? String(contentsOfFile: configPath, encoding: .utf8),
           existing.contains("# X Island hooks") {
            // Already configured, skip
            print("[ZeroConfig] GLM hooks already present")
            return
        }

        let content = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let newContent = content + "\n" + block + "\n"
        try? newContent.write(toFile: configPath, atomically: true, encoding: .utf8)
        print("[ZeroConfig] GLM hooks configured at \(configPath)")
    }

    // MARK: - Helpers

    private static func ensureDir(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func writeJSON(_ path: String, _ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static func autoConfigKey(for agent: AgentType) -> String {
        autoConfigKeyPrefix + agent.rawValue
    }

    private static var cursorHookPaths: [String] {
        [
            "\(home)/.cursor/hooks.json",
            "\(home)/.trae/hooks.json",
            "\(home)/.trae-cn/hooks.json"
        ]
    }

    private static var traeIDESettingsPaths: [String] {
        [
            "\(home)/Library/Application Support/Trae/User/settings.json",
            "\(home)/Library/Application Support/Trae CN/User/settings.json"
        ]
    }

    private static func hasConfiguration(for agent: AgentType) -> Bool {
        switch agent {
        case .claudeCode:
            let path = "\(home)/.claude/settings.json"
            guard let settings = readJSON(path),
                  let hooks = settings["hooks"] as? [String: Any] else { return false }
            return hooksContainBridge(hooks)
        case .codex:
            let path = "\(home)/.codex/hooks.json"
            guard let config = readJSON(path),
                  let hooks = config["hooks"] as? [String: Any] else { return false }
            return hooksContainBridge(hooks)
        case .cursor:
            for path in cursorHookPaths {
                guard let config = readJSON(path),
                      let hooks = config["hooks"] as? [String: Any] else { continue }
                if hooksContainBridge(hooks) { return true }
            }
            return false
        case .trae:
            return hasConfiguration(for: .cursor)
        case .openCode:
            let path = "\(home)/.config/opencode/plugins/xisland.js"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return text.contains("di-bridge")
        case .geminiCli:
            let path = "\(home)/.gemini/settings.json"
            return configContainsBridge(path: path, key: "xisland_hook")
        case .droid:
            let path = "\(home)/.droid/config.json"
            return configContainsBridge(path: path, key: "xisland_hook")
        case .qoder:
            let path = "\(home)/.qoder/config.json"
            return configContainsBridge(path: path, key: "xisland_hook")
        case .copilot:
            let path = "\(home)/.copilot/config.json"
            return configContainsBridge(path: path, key: "xisland_hook")
        case .codeBuddy:
            let path = "\(home)/.codebuddy/config.json"
            return configContainsBridge(path: path, key: "xisland_hook")
        case .qwen:
            let path = "\(home)/.qwen/settings.json"
            guard let settings = readJSON(path),
                  let hooks = settings["hooks"] as? [String: Any] else { return false }
            return hooksContainBridge(hooks)
        case .kimi:
            let path = "\(home)/.kimi/config.toml"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return text.contains("di-bridge")
        case .deepseek:
            let path = "\(home)/.deepseek/config.toml"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return text.contains("di-bridge")
        case .kiro:
            // Kiro has no auto-configurable hooks
            return false
        case .amp:
            let path = "\(home)/.config/amp/plugins/xisland.ts"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return text.contains("di-bridge")
        case .pi:
            let path = "\(home)/.pi/agent/extensions/xisland.ts"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return text.contains("di-bridge")
        case .hermes:
            let path = "\(home)/.xisland/bin/hermes-bridge"
            return FileManager.default.fileExists(atPath: path)
        case .glm:
            let path = "\(home)/.zhipu/config.toml"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return text.contains("di-bridge")
        }
    }

    private static func removeConfiguration(for agent: AgentType) {
        switch agent {
        case .claudeCode:
            removeBridgeHooks(at: "\(home)/.claude/settings.json")
        case .codex:
            removeBridgeHooks(at: "\(home)/.codex/hooks.json")
        case .cursor:
            for path in cursorHookPaths {
                removeCursorBridgeHooks(at: path)
            }
        case .trae:
            removeConfiguration(for: .cursor)
        case .openCode:
            try? FileManager.default.removeItem(atPath: "\(home)/.config/opencode/plugins/xisland.js")
        case .geminiCli:
            removeBridgeConfigValue(at: "\(home)/.gemini/settings.json", key: "xisland_hook")
        case .droid:
            removeBridgeConfigValue(at: "\(home)/.droid/config.json", key: "xisland_hook")
        case .qoder:
            removeBridgeConfigValue(at: "\(home)/.qoder/config.json", key: "xisland_hook")
        case .copilot:
            removeBridgeConfigValue(at: "\(home)/.copilot/config.json", key: "xisland_hook")
        case .codeBuddy:
            removeBridgeConfigValue(at: "\(home)/.codebuddy/config.json", key: "xisland_hook")
        case .qwen:
            removeBridgeHooks(at: "\(home)/.qwen/settings.json")
        case .kimi:
            removeTOMLBlock(at: "\(home)/.kimi/config.toml", marker: "# X Island hooks")
        case .deepseek:
            removeTOMLBlock(at: "\(home)/.deepseek/config.toml", marker: "# X Island hooks")
        case .kiro:
            // Nothing to remove for Kiro
            break
        case .amp:
            try? FileManager.default.removeItem(atPath: "\(home)/.config/amp/plugins/xisland.ts")
        case .pi:
            try? FileManager.default.removeItem(atPath: "\(home)/.pi/agent/extensions/xisland.ts")
        case .hermes:
            try? FileManager.default.removeItem(atPath: "\(home)/.xisland/bin/hermes-bridge")
        case .glm:
            removeTOMLBlock(at: "\(home)/.zhipu/config.toml", marker: "# X Island hooks")
        }
    }

    private static func hooksContainBridge(_ hooks: [String: Any]) -> Bool {
        hooks.values.contains { hookList in
            guard let list = hookList as? [[String: Any]] else { return false }
            return list.contains { entry in
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                if cmds.contains(where: { ($0["command"] as? String)?.contains("di-bridge") == true }) {
                    return true
                }
                return (entry["command"] as? String)?.contains("di-bridge") == true
            }
        }
    }

    private static func configContainsBridge(path: String, key: String) -> Bool {
        guard let config = readJSON(path) else { return false }
        return (config[key] as? String)?.contains("di-bridge") == true
    }

    private static func removeBridgeHooks(at path: String) {
        guard var config = readJSON(path),
              var hooks = config["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            guard var hookList = hooks[key] as? [[String: Any]] else { continue }
            hookList.removeAll { entry in
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                return cmds.contains { ($0["command"] as? String)?.contains("di-bridge") == true }
                    || (entry["command"] as? String)?.contains("di-bridge") == true
            }
            if hookList.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = hookList
            }
        }
        config["hooks"] = hooks
        writeJSON(path, config)
    }

    private static func removeCursorBridgeHooks(at path: String) {
        guard var config = readJSON(path),
              var hooks = config["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            guard var entries = hooks[key] as? [[String: Any]] else { continue }
            entries.removeAll { ($0["command"] as? String)?.contains("di-bridge") == true }
            if entries.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = entries
            }
        }
        config["hooks"] = hooks
        writeJSON(path, config)
    }

    private static func removeBridgeConfigValue(at path: String, key: String) {
        guard var config = readJSON(path) else { return }
        if (config[key] as? String)?.contains("di-bridge") == true {
            config.removeValue(forKey: key)
            writeJSON(path, config)
        }
    }

    private static func removeTOMLBlock(at path: String, marker: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let range = text.range(of: marker) else { return }
        var cleaned = text
        let rest = cleaned[range.lowerBound...]
        if let nextSection = rest.range(of: "\n[", options: .literal, range: rest.index(after: range.lowerBound)..<rest.endIndex) {
            cleaned.removeSubrange(range.lowerBound..<nextSection.lowerBound)
        } else {
            cleaned.removeSubrange(range.lowerBound...)
        }
        try? cleaned.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
