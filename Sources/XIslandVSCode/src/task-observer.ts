import { createHash, randomUUID } from "crypto";

export type Agent = "roo_code" | "pearai";
export type Message = Record<string, unknown> & { type: string; sessionId: string; agentType: Agent };
export interface TaskAPI {
    on(event: string, listener: (...args: unknown[]) => void): unknown;
    removeListener(event: string, listener: (...args: unknown[]) => void): unknown;
}

const commonEvents = ["taskCreated", "taskStarted", "taskCompleted", "taskAborted", "taskPaused", "taskUnpaused",
    "taskSpawned", "taskModeSwitched", "taskAskResponded", "taskToolFailed", "taskTokenUsageUpdated", "message"];
const rooEvents = ["taskActive", "taskInteractive", "taskResumable", "taskIdle", "taskDelegationCompleted"];
const object = (value: unknown): Record<string, unknown> | undefined =>
    value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
const identifier = (value: unknown): value is string => typeof value === "string" && value.length > 0
    && value.length <= 4096 && !/[\x00-\x1f]/.test(value) && Buffer.from(value, "utf8").toString("utf8") === value;
const number = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value >= 0;
const preview = (value: string): string => {
    // 流式片段可能暂时只有半个 UTF-16 字符，转成有效 UTF-8 后再进入 Swift JSON 解码。
    if (value.length <= 32_768) return Buffer.from(value, "utf8").toString("utf8");
    let end = 32_768;
    if (/[\uD800-\uDBFF]/.test(value[end - 1])) end--;
    return Buffer.from(value.slice(0, end), "utf8").toString("utf8") + "\n[预览已截断]";
};

/** 只消费公开事件；不调用 sendMessage、press*、startNewTask 或读取供应商配置。 */
export function observeTasks(api: TaskAPI, agent: Agent, source: string, send: (message: Message) => void): { dispose(): void } {
    if (source.length !== 24 || !/^[0-9a-f]{24}$/.test(source)) throw new Error("Invalid source identity");
    const sourceInstanceId = randomUUID().toLowerCase();
    const sourceSession = `${agent}-${source}-${sourceInstanceId}`;
    const running = new Set<string>(), aborted = new Set<string>();
    const asks = new Map<string, string>();
    const seen = new Map<string, string>();
    let disposed = false, hasActivity = false, sequence = 0;
    let heartbeat: ReturnType<typeof setInterval> | undefined;
    const session = (id: string) => `${sourceSession}-${Buffer.from(id, "utf8").toString("base64url")}`;
    const publish = (fields: Message) => {
        if (sequence === Number.MAX_SAFE_INTEGER) return;
        send({ ...fields, sourceNamespace: source, sourceInstanceId, observationSequence: ++sequence,
            timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, "Z") });
    };
    const control = (type: string) => publish({ type, sessionId: sourceSession, agentType: agent });
    const emit = (id: string, event: string, fields: Record<string, unknown> = {}) => {
        if (disposed) return;
        if (!hasActivity) {
            hasActivity = true;
            heartbeat = setInterval(() => {
                if (!disposed) { try { control("observation_heartbeat"); } catch { /* 观察失败不影响宿主。 */ } }
            }, 10_000);
            heartbeat.unref();
        }
        publish({ type: "status_update", sessionId: session(id), agentType: agent,
            nativeEvent: event, nativeTaskId: id, statusIsAssistantReply: false, ...fields });
    };
    const usage = (value: unknown): Record<string, unknown> => {
        const data = object(value);
        if (!data || !number(data.totalTokensIn) || !number(data.totalTokensOut) || !number(data.totalCost)) return {};
        if (!Number.isSafeInteger(data.totalTokensIn) || !Number.isSafeInteger(data.totalTokensOut)) return {};
        return { tokensIn: data.totalTokensIn, tokensOut: data.totalTokensOut, costUSD: data.totalCost, usageIsCumulative: true };
    };
    const message = (value: unknown) => {
        const data = object(value), row = object(data?.message), id = data?.taskId;
        if (!identifier(id) || aborted.has(id) || !row || !["created", "updated"].includes(String(data?.action))) return;
        if (!number(row.ts) || !Number.isSafeInteger(row.ts) || !["ask", "say"].includes(String(row.type))) return;
        if (row.partial !== undefined && typeof row.partial !== "boolean") return;
        if (row.text !== undefined && typeof row.text !== "string") return;
        const text = preview(typeof row.text === "string" ? row.text : "");
        const key = id + "\0" + row.ts;
        // 缓存摘要，避免为去重常驻保留成千段长输出。
        const fingerprint = createHash("sha256").update(JSON.stringify([row.type, row.ask, row.say, text, row.partial, row.isAnswered])).digest("hex");
        if (seen.get(key) === fingerprint) return;
        seen.delete(key); seen.set(key, fingerprint);
        if (seen.size > 2048) seen.delete(seen.keys().next().value!);
        if (row.type === "ask") {
            if (row.partial === true) return;
            if (row.isAnswered === true) { asks.delete(id); return; }
            if (typeof row.ask !== "string") return;
            asks.set(id, row.ask);
            // Pear 没有 taskInteractive，ask 也可能自动批准；只显示原应用提示。
            emit(id, "message", { status: `原应用提示 (${row.ask})：${text}` });
            return;
        }
        if (row.say === "api_req_started") {
            running.add(id);
            emit(id, "message", { observedState: "active", status: "原应用开始请求" });
        } else if (row.say === "text" || row.say === "completion_result") {
            // startTask() 的第一条 say:text 实际是用户任务，不能直接当成助手回答。
            const isReply = row.say === "completion_result" || running.has(id);
            if (!isReply) return; // 初始任务文字与晚接入的历史文字没有可靠角色字段。
            emit(id, "message", { status: text, statusIsAssistantReply: isReply,
                nativeMessageId: `${row.ts}`, nativeMessagePartial: row.partial === true });
        } else if (row.say === "user_feedback" && row.partial !== true) {
            emit(id, "message", { type: "session_start", prompt: text, nativeMessageId: `${row.ts}` });
        } else if (["error", "diff_error", "rooignore_error", "condense_context_error"].includes(String(row.say))) {
            emit(id, "message", { status: text, observedState: "error" });
        } else if (["command_output", "mcp_server_request_started", "mcp_server_response"].includes(String(row.say))) {
            emit(id, "message", { status: `${row.say}: ${text}` });
        }
    };
    const accept = (event: string, args: unknown[]) => {
        if (disposed) return;
        if (event === "message") { message(args[0]); return; }
        const id = args[0];
        if (!identifier(id)) return;
        if (event === "taskStarted") { aborted.delete(id); running.add(id); }
        else if (aborted.has(id) && event !== "taskCreated") return;
        switch (event) {
        case "taskCreated": break; // 对象创建（含历史恢复）不证明任务在运行。
        case "taskStarted": emit(id, event, { type: "session_start" }); break;
        case "taskActive": case "taskUnpaused":
            emit(id, event, { observedState: "active" }); break;
        case "taskCompleted":
            asks.delete(id);
            emit(id, event, { observedState: "idle", status: "原应用报告完成，可继续反馈", ...usage(args[1]) }); break;
        case "taskAborted":
            aborted.add(id); running.delete(id); asks.delete(id);
            emit(id, event, { observedState: "idle", status: "原应用运行已中止" }); break;
        case "taskPaused": case "taskResumable":
            emit(id, event, { observedState: "idle", status: "原应用暂停或等待后续操作" }); break;
        case "taskIdle": {
            const ask = asks.get(id);
            if (ask === "api_req_failed") emit(id, event, { observedState: "error", status: "原应用请求失败，等待重试" });
            else if (["mistake_limit_reached", "auto_approval_max_req_reached"].includes(ask ?? ""))
                emit(id, event, { observedState: "waitingAnswer", status: "原应用达到运行限制，请在原应用处理" });
            else emit(id, event, { observedState: "idle", status: "原应用等待后续操作" });
            break;
        }
        case "taskAskResponded":
            asks.delete(id); emit(id, event, { observedState: "active", status: "原应用已处理输入" }); break;
        case "taskInteractive": {
            const ask = asks.get(id);
            emit(id, event, { status: "请在原应用处理交互", ...(ask === "followup" ? { observedState: "waitingAnswer" }
                : ["command", "tool", "use_mcp_server"].includes(ask ?? "") ? { observedState: "waitingPermission" } : {}) });
            break;
        }
        case "taskTokenUsageUpdated": {
            const snapshot = usage(args[1]);
            if (snapshot.usageIsCumulative === true) emit(id, event, snapshot);
            break;
        }
        case "taskToolFailed":
            if (typeof args[1] === "string" && typeof args[2] === "string")
                emit(id, event, { observedState: "error", status: preview(`${args[1]}: ${args[2]}`) });
            break;
        case "taskModeSwitched":
            if (typeof args[1] === "string") emit(id, event, { status: "原应用模式：" + preview(args[1]) });
            break;
        case "taskSpawned": case "taskDelegationCompleted":
            if (identifier(args[1])) emit(id, event, { type: event === "taskSpawned" ? "subagent_start" : "subagent_end",
                parentSessionId: session(id), subagentId: session(args[1]) });
            break;
        }
    };
    const listeners: { event: string; listener: (...args: unknown[]) => void }[] = [];
    const remove = () => {
        for (const { event, listener } of listeners) {
            try { api.removeListener(event, listener); } catch { /* 继续清理其他已注册监听器。 */ }
        }
    };
    try { for (const event of [...commonEvents, ...(agent === "roo_code" ? rooEvents : [])]) {
        const listener = (...args: unknown[]) => {
            // 外部扩展事件不能把异常传播回供应商的任务执行栈。
            try { accept(event, args); } catch { /* 丢弃不可解析的观察数据。 */ }
        };
        api.on(event, listener);
        listeners.push({ event, listener });
    } } catch (error) {
        disposed = true;
        if (heartbeat) clearInterval(heartbeat);
        remove(); throw error;
    }
    return { dispose() {
        if (disposed) return;
        disposed = true;
        if (heartbeat) clearInterval(heartbeat);
        remove();
        asks.clear(); seen.clear(); running.clear(); aborted.clear();
        // 只结束本次观察；原生任务可能仍然运行。
        if (hasActivity) { try { control("observation_ended"); } catch { /* 接收端租约处理未送达的结束通知。 */ } }
    } };
}
