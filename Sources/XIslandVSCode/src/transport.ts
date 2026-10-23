import { ChildProcess, spawn } from "child_process";
import * as os from "os";
import * as path from "path";
import { performance } from "perf_hooks";
import { Message } from "./task-observer";

/** 每条连接只发送一帧；无应答的观察事件开始写入后不重发。 */
export class ObservationTransport {
    private bridge?: ChildProcess;
    private retry?: ReturnType<typeof setTimeout>;
    private pending: { frame: Buffer; key?: string; agent: string; expiresAt: number }[] = [];
    private bytes = 0;
    private disposed = false;
    private drainPromise?: Promise<void>;
    private finishDrain?: () => void;
    private drainTimer?: ReturnType<typeof setTimeout>;

    constructor(private readonly socketPath: string, private readonly status: (state: string) => void,
                private readonly retryMilliseconds = 2000, private readonly now = () => performance.now(),
                private readonly bridgePath = path.join(os.homedir(), ".xisland", "bin", "di-bridge")) {}

    send(message: Message): void {
        if (this.disposed || this.drainPromise) return;
        this.expire();
        const frame = Buffer.from(JSON.stringify(message) + "\n");
        if (frame.length > 256 * 1024) { this.status("消息过大，未发送"); return; }
        const key = message.type === "status_update" && typeof message.nativeMessageId === "string"
            ? message.sessionId + "\0" + message.nativeMessageId : undefined;
        // 只合并队尾的同一行流式更新，不能越过其他事件改变顺序。
        const last = this.pending.at(-1);
        if (key && last?.key === key) {
            this.bytes -= last.frame.length;
            this.pending.pop();
        }
        // 断连积压不能在恢复后冒充当前状态；心跳只保留几秒。
        const ttl = message.type === "observation_heartbeat" ? 3000 : 30_000;
        this.pending.push({ frame, key, agent: message.agentType, expiresAt: this.now() + ttl }); this.bytes += frame.length;
        if (this.bytes > 2 * 1024 * 1024 || this.pending.length > 2048) {
            this.pending = []; this.bytes = 0;
            this.status("观察队列溢出，已丢弃积压；状态需后续事件确认");
            this.bridge?.kill();
            return;
        }
        if (!this.bridge && !this.retry) this.connect();
    }

    private connect(): void {
        this.expire();
        if (this.disposed || this.bridge || !this.pending.length) return;
        // 路径和参数不经过 shell；只有原生 di-bridge 能通过接收端的进程身份检查。
        const bridge = spawn(this.bridgePath, ["vscode-observation"], {
            shell: false, stdio: ["pipe", "pipe", "ignore"],
            env: { ...process.env, DI_SOCKET_PATH: this.socketPath },
        });
        this.bridge = bridge;
        let attempted = false, failed = false, ready = "";
        const timer = setTimeout(() => { failed = true; bridge.kill(); }, 2500);
        bridge.stdout?.on("data", (chunk: Buffer) => {
            if (attempted || bridge !== this.bridge) return;
            ready += chunk.toString("utf8");
            if (!"ready\n".startsWith(ready)) { failed = true; bridge.kill(); return; }
            if (ready !== "ready\n") return;
            this.expire();
            if (this.disposed || bridge !== this.bridge) { bridge.kill(); return; }
            const next = this.pending.shift();
            if (!next) { bridge.kill(); return; }
            this.bytes -= next.frame.length;
            // ready 只证明原生进程已连接。交给它后无法确认 socket 是否已消费，故不重放。
            attempted = true;
            this.status("已连接本地 X Island");
            bridge.stdin?.end(next.frame);
        });
        const fail = () => { failed = true; this.status("本地 X Island 暂未连接"); bridge.kill(); };
        bridge.on("error", fail);
        bridge.stdin?.on("error", fail);
        bridge.once("close", code => {
            clearTimeout(timer);
            if (bridge !== this.bridge) return;
            this.bridge = undefined;
            this.expire();
            if (code !== 0) this.status("本地 X Island 暂未连接");
            if (this.disposed || this.retry || !this.pending.length) return;
            if (attempted && !failed && code === 0) { this.connect(); return; }
            this.retry = setTimeout(() => { this.retry = undefined; this.connect(); }, this.retryMilliseconds);
            this.retry.unref();
        });
    }

    discard(agent: string): void {
        this.pending = this.pending.filter(item => item.agent !== agent);
        this.bytes = this.pending.reduce((sum, item) => sum + item.frame.length, 0);
    }

    private expire(): void {
        const now = this.now();
        this.pending = this.pending.filter(item => item.expiresAt > now);
        this.bytes = this.pending.reduce((sum, item) => sum + item.frame.length, 0);
        if (this.drainPromise && !this.pending.length && !this.bridge) this.dispose();
    }

    /** 给已排队的结束通知有限发送时间，不接收新事件。 */
    drain(graceMilliseconds = 500): Promise<void> {
        if (this.drainPromise) return this.drainPromise;
        if (this.disposed) return Promise.resolve();
        this.drainPromise = new Promise(resolve => { this.finishDrain = resolve; });
        this.drainTimer = setTimeout(() => this.dispose(), Math.max(0, Math.min(graceMilliseconds, 2000)));
        if (this.retry) clearTimeout(this.retry);
        this.retry = undefined;
        this.connect();
        return this.drainPromise;
    }

    dispose(): void {
        this.disposed = true;
        if (this.retry) clearTimeout(this.retry);
        this.retry = undefined; this.pending = []; this.bytes = 0;
        this.bridge?.kill(); this.bridge = undefined;
        if (this.drainTimer) clearTimeout(this.drainTimer);
        this.drainTimer = undefined; this.finishDrain?.(); this.finishDrain = undefined;
    }
}
