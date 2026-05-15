import * as net from "net";
import * as os from "os";
import * as path from "path";
import * as vscode from "vscode";

const SOCKET_PATH = path.join(os.homedir(), ".xisland", "di.sock");
const IDLE_TIMEOUT_MS = 30_000; // 30s inactivity → session_end
const DEBOUNCE_MS = 2_000; // batch rapid edits into one session_start

let socket: net.Socket | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let idleTimer: ReturnType<typeof setTimeout> | null = null;
let debounceTimer: ReturnType<typeof setTimeout> | null = null;
let currentSessionId: string | null = null;
let currentAgent: string | null = null;
let currentCwd: string = "";

// --- Socket helpers ---

function connect(): void {
    if (socket && !socket.destroyed) return;

    socket = new net.Socket();
    socket.connect(SOCKET_PATH, () => {
        console.log(`[XIsland] Connected to ${SOCKET_PATH}`);
    });

    socket.on("error", (err: Error) => {
        console.error(`[XIsland] Socket error: ${err.message}`);
        scheduleReconnect();
    });

    socket.on("close", () => {
        console.log("[XIsland] Socket closed");
        scheduleReconnect();
    });
}

function scheduleReconnect(): void {
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        connect();
    }, 5_000);
}

function sendMessage(msg: Record<string, unknown>): void {
    if (!socket || socket.destroyed) {
        connect();
        return;
    }
    try {
        const json = JSON.stringify(msg) + "\n";
        socket.write(json);
    } catch {
        // Socket write failed, will reconnect on next attempt
    }
}

// --- Session lifecycle ---

function startSession(agent: string): void {
    if (currentSessionId) {
        // Already tracking a session — just reset the idle timer
        resetIdleTimer();
        return;
    }

    currentSessionId = `vscode-${agent}-${Date.now()}`;
    currentAgent = agent;
    currentCwd = getWorkspaceDir();

    sendMessage({
        type: "session_start",
        session_id: currentSessionId,
        agent_type: agent,
        terminal: "VS Code",
        working_dir: currentCwd,
        prompt: "",
        timestamp: new Date().toISOString(),
    });

    console.log(`[XIsland] session_start: ${currentSessionId} (${agent})`);
    resetIdleTimer();
}

function endSession(): void {
    if (!currentSessionId) return;

    sendMessage({
        type: "session_end",
        session_id: currentSessionId,
        agent_type: currentAgent,
        timestamp: new Date().toISOString(),
    });

    console.log(`[XIsland] session_end: ${currentSessionId}`);
    currentSessionId = null;
    currentAgent = null;
    if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
}

function resetIdleTimer(): void {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
        endSession();
    }, IDLE_TIMEOUT_MS);
}

function getWorkspaceDir(): string {
    const folders = vscode.workspace.workspaceFolders;
    return folders?.length ? folders[0].uri.fsPath : "";
}

// --- Activity signals ---

function onActivity(agent: string): void {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
        startSession(agent);
    }, DEBOUNCE_MS);
}

// --- Heuristic: rapid consecutive file edits → AI activity ---

function detectAIByExtension(): string | null {
    const ids = [
        { id: "github.copilot", agent: "copilot" },
        { id: "github.copilot-chat", agent: "copilot" },
        { id: "saoudrizwan.claude-dev", agent: "claude_code" },
        { id: "continue.continue", agent: "continue" },
    ];

    for (const { id, agent } of ids) {
        const ext = vscode.extensions.getExtension(id);
        if (ext && ext.isActive) {
            console.log(`[XIsland] Detected active extension: ${id} → ${agent}`);
            return agent;
        }
    }
    return null;
}

// --- Activation ---

export function activate(context: vscode.ExtensionContext): void {
    console.log("[XIsland] VS Code extension activated");

    // Connect to X Island socket
    connect();

    // 1. File edit heuristic: rapid edits within DEBOUNCE_MS → likely AI
    context.subscriptions.push(
        vscode.workspace.onDidChangeTextDocument((e: vscode.TextDocumentChangeEvent) => {
            // Only react to AI-initiated changes: document has no associated editor
            // (user-typed changes come through an active TextEditor)
            const editors = vscode.window.visibleTextEditors.filter(
                (ed) => ed.document.uri.toString() === e.document.uri.toString()
            );

            // If there's a visible editor for this document, the change is likely user-initiated.
            // AI tools (Copilot inline, Cline file edits) often modify files in the background.
            const likelyAI = editors.length === 0;

            if (likelyAI) {
                const agent = detectAIByExtension() || "copilot";
                onActivity(agent);
            }
        })
    );

    // 2. Active editor change — detect when user starts chatting with AI
    context.subscriptions.push(
        vscode.window.onDidChangeActiveTextEditor(() => {
            const agent = detectAIByExtension();
            if (agent) {
                onActivity(agent);
            }
        })
    );

    // 3. Terminal open — Cline/Copilot Chat may open terminals for agent execution
    context.subscriptions.push(
        vscode.window.onDidOpenTerminal((terminal: vscode.Terminal) => {
            const name = terminal.name.toLowerCase();
            if (name.includes("cline") || name.includes("copilot") || name.includes("codex")) {
                onActivity("copilot");
            }
        })
    );

    // Periodic check: if an AI extension is active, keep session alive
    const interval = setInterval(() => {
        const agent = detectAIByExtension();
        if (agent && currentSessionId) {
            resetIdleTimer();
        }
    }, 15_000);

    context.subscriptions.push({ dispose: () => clearInterval(interval) });

    // Show status bar indicator
    const statusBar = vscode.window.createStatusBarItem(
        vscode.StatusBarAlignment.Right,
        100
    );
    statusBar.text = "$(pulse) X Island";
    statusBar.tooltip = "X Island bridge active";
    statusBar.show();
    context.subscriptions.push(statusBar);
}

export function deactivate(): void {
    endSession();
    if (socket) { socket.destroy(); socket = null; }
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
    if (debounceTimer) { clearTimeout(debounceTimer); debounceTimer = null; }
    console.log("[XIsland] VS Code extension deactivated");
}
