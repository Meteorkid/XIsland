import * as crypto from "crypto";
import * as os from "os";
import * as path from "path";
import * as vscode from "vscode";
import { Agent, observeTasks, TaskAPI } from "./task-observer";
import { ObservationTransport } from "./transport";

const targets: { id: string; version: string; agent: Agent; setting: string }[] = [
    { id: "RooVeterinaryInc.roo-cline", version: "3.54.0", agent: "roo_code", setting: "observeRooCode" },
    { id: "PearAI.pearai-roo-cline", version: "3.15.3", agent: "pearai", setting: "observePearAIExperimental" },
];
let cleanup: (() => Promise<void>) | undefined;

export function activate(context: vscode.ExtensionContext): void {
    cleanup?.();
    let stopped = false;
    let drained: Promise<void> | undefined;
    const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    const attached = new Map<Agent, { api: TaskAPI; dispose(): void }>();
    let connection = "等待原生任务事件";
    let problems: string[] = [];
    const render = () => {
        if (stopped) return;
        status.text = `$(pulse) X Island · ${attached.size} 来源`;
        status.tooltip = [connection, ...problems, "只观察已核实版本的侧栏任务；审批和回答请在原应用处理。"].join("\n");
    };
    const transport = new ObservationTransport(path.join(os.homedir(), ".xisland", "di.sock"), value => {
        connection = value; render();
    });
    // 持久来源命名空间，不以本次窗口启动时间或工作目录伪造原生 taskId。
    const source = crypto.createHash("sha256").update(JSON.stringify([
        vscode.env.machineId, vscode.env.appName, context.globalStorageUri.toString(),
    ])).digest("hex").slice(0, 24);
    const refresh = () => {
        if (stopped) return;
        problems = [];
        const local = process.platform === "darwin" && !vscode.env.remoteName && vscode.workspace.isTrusted;
        if (!local) problems.push("仅在受信任的本地 macOS 扩展宿主观察；未启用远程转发。");
        for (const target of targets) {
            const extension = vscode.extensions.getExtension(target.id);
            const enabled = vscode.workspace.getConfiguration("xisland").get<boolean>(target.setting, false);
            const api = extension?.isActive ? extension.exports as Partial<TaskAPI> | undefined : undefined;
            const valid = local && enabled && extension?.packageJSON.version === target.version
                && typeof api?.on === "function" && typeof api?.removeListener === "function";
            const previous = attached.get(target.agent);
            if (previous && (!valid || previous.api !== api)) {
                transport.discard(target.agent); previous.dispose(); attached.delete(target.agent);
            }
            if (valid && !attached.has(target.agent)) {
                try {
                    const subscription = observeTasks(api as TaskAPI, target.agent, source, message =>
                        transport.send({ ...message, terminal: vscode.env.appName }));
                    attached.set(target.agent, { api: api as TaskAPI, dispose: () => subscription.dispose() });
                } catch { problems.push(`${target.id} 事件订阅失败`); }
            } else if (enabled && !valid) {
                problems.push(`${target.id}：等待已激活的 ${target.version}；其他版本未验收`);
            }
        }
        render();
    };
    const changes = vscode.extensions.onDidChange(refresh);
    const settings = vscode.workspace.onDidChangeConfiguration(event => {
        if (event.affectsConfiguration("xisland")) refresh();
    });
    // onDidChange 不保证覆盖所有激活状态变化；仅检查两个已安装扩展，不自动激活或创建任务。
    const timer = setInterval(refresh, 2000);
    timer.unref();
    cleanup = () => {
        if (stopped) return drained ?? Promise.resolve();
        stopped = true; clearInterval(timer); changes.dispose(); settings.dispose();
        for (const [agent, entry] of attached) { transport.discard(agent); entry.dispose(); }
        attached.clear(); status.dispose();
        drained = transport.drain();
        return drained;
    };
    context.subscriptions.push({ dispose: cleanup });
    status.show(); refresh();
}

export function deactivate(): Promise<void> | undefined {
    const drained = cleanup?.(); cleanup = undefined; return drained;
}
