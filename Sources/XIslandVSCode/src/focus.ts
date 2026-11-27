/**
 * Pure parsing/matching helpers for the companion focus URI. They deliberately
 * do not import `vscode` so the matching rules can be tested without an
 * extension host.
 */

export interface FocusRequest {
    tty?: string;
    pid?: number;
    cwd?: string;
}

export interface TerminalCandidate {
    index: number;
    name: string;
    pid?: number;
    tty?: string;
    cwd?: string;
}

/** macOS PTY names are `ttys000`/`ttyp0`/… under `/dev`. */
export function normalizeTTY(value: string | undefined): string | undefined {
    if (value === undefined) return undefined;
    let trimmed = value.trim();
    if (trimmed.startsWith("/dev/")) trimmed = trimmed.slice(5);
    if (!/^tty[A-Za-z0-9]+$/.test(trimmed)) return undefined;
    return "/dev/" + trimmed;
}

/** Parse `vscode://meteorkid.xisland-vscode/focus?tty=/dev/ttys004&cwd=...`. */
export function parseFocusRequest(path: string, query: string): FocusRequest | undefined {
    if (path !== "/focus" && path !== "/focus/") return undefined;
    const parameters = new URLSearchParams(query);
    const request: FocusRequest = {};

    const ttyValue = parameters.get("tty");
    if (ttyValue !== null) {
        if (!ttyValue.startsWith("/dev/")) return undefined;
        const tty = normalizeTTY(ttyValue);
        if (tty === undefined) return undefined;
        request.tty = tty;
    }

    const pidValue = parameters.get("pid");
    if (pidValue !== null) {
        if (!/^[1-9][0-9]{0,9}$/.test(pidValue)) return undefined;
        const pid = Number(pidValue);
        if (!Number.isSafeInteger(pid) || pid > 2_147_483_647) return undefined;
        request.pid = pid;
    }

    const cwdValue = parameters.get("cwd");
    if (cwdValue !== null) {
        if (!cwdValue.startsWith("/") || cwdValue.length > 4096 || /[\x00-\x1f]/.test(cwdValue)) return undefined;
        request.cwd = cwdValue;
    }

    return request.tty !== undefined || request.pid !== undefined || request.cwd !== undefined
        ? request : undefined;
}

/**
 * Resolve one existing terminal, never a new one. Exact tty wins over pid,
 * which wins over cwd; every ambiguous level fails closed.
 */
export function selectTerminal(candidates: readonly TerminalCandidate[], request: FocusRequest): number | undefined {
    const selectUnique = (matches: readonly TerminalCandidate[]): number | undefined =>
        matches.length === 1 ? matches[0].index : undefined;

    if (request.tty !== undefined) {
        const matches = candidates.filter(candidate => normalizeTTY(candidate.tty) === request.tty);
        if (matches.length > 0) return selectUnique(matches);
    }
    if (request.pid !== undefined) {
        const matches = candidates.filter(candidate => candidate.pid === request.pid);
        if (matches.length > 0) return selectUnique(matches);
    }
    if (request.cwd !== undefined) {
        const matches = candidates.filter(candidate => candidate.cwd === request.cwd);
        if (matches.length > 0) return selectUnique(matches);
    }
    return undefined;
}

/** `ps -o tty=` prints `ttys004` (or a bare `??` for no controlling tty). */
export function ttyFromPSOutput(output: string): string | undefined {
    const first = output.split(/\r?\n/, 1)[0]?.trim();
    if (!first) return undefined;
    return normalizeTTY("/dev/" + first);
}
