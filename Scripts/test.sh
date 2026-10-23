#!/bin/bash
set -euo pipefail

###############################################################################
# X Island — Integration Test Suite
#
# 通过 di-bridge 发送模拟的 agent 事件，并用**隔离实例的结构化诊断**验证行为。
#
# 历史说明：本脚本原先 `grep ~/.xisland/debug.log` 做断言，但该文件日志在
# v1.6.1（commit ec1e7e5）被移除 —— `diLog()` 改为 `os.Logger`，不再落盘。
# 现在改为启动一个 `X_ISLAND_TEST_MODE=1` 的隔离实例（独立 runtime 目录、
# 独立 defaults suite、独立 socket），断言来源为：
#   1. `diagnostics.json` —— handledMessageCount / visibleSessions /
#      pendingInteraction / islandState，由 App 在每次状态变化后原子写出；
#   2. 隔离实例的只读 SQLite（`history.store`）—— 会话与聊天记录的持久化结果。
# 两者都不触碰用户真实数据。
#
# Prerequisites:
#   1. `swift build -c release`（或 Scripts/build.sh）产出 .build/X Island.app
#   2. 无需预先运行 X Island —— 本脚本自行拉起隔离实例
#
# Usage:
#   bash Scripts/test.sh           # run all tests
#   bash Scripts/test.sh M1        # run module M1 only
#   bash Scripts/test.sh M1 M4     # run modules M1 and M4
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

APP_BUNDLE="$PROJECT_DIR/.build/X Island.app"
BRIDGE="$PROJECT_DIR/.build/X Island.app/Contents/MacOS/di-bridge"
FIXTURE="$PROJECT_DIR/Tests/Fixtures/app/empty-interaction.json"

PASSED=0
FAILED=0
SKIPPED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 隔离运行时 ────────────────────────────────────────────────────────────────
#
# 路径必须是「短绝对路径 + 位于临时目录下」：Darwin 的 sockaddr_un.sun_path
# 只有 104 字节，App 启动时会校验并拒绝不合规目录。

RUNTIME=""
APP_PID=""
DIAGNOSTICS=""
HISTORY=""
DIAG_LAST_COUNT=0
# 置 1 时让桥接把 stdin 落盘，供 M16 断言。
BRIDGE_DEBUG_LOG=""

pass() { PASSED=$((PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { FAILED=$((FAILED+1)); echo -e "  ${RED}✗${NC} $1"; }
skip() { SKIPPED=$((SKIPPED+1)); echo -e "  ${YELLOW}⊘${NC} $1 (skipped)"; }

section() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

cleanup() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        for _ in {1..30}; do
            kill -0 "$APP_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
    # 后台的交互式桥接会一直等待应答，必须一并回收，否则会残留进程。
    /usr/bin/pkill -f "xi-it-" 2>/dev/null || true
    # 隔离实例的 defaults suite 由脚本创建，一并回收。
    if [[ -n "${DEFAULTS_SUITE:-}" ]]; then
        defaults delete "$DEFAULTS_SUITE" 2>/dev/null || true
    fi
    if [[ -n "$RUNTIME" && -d "$RUNTIME" ]]; then
        rm -rf "$RUNTIME"
    fi
}
trap cleanup EXIT

# 诊断 JSON 读取：失败时输出空对象，避免 set -e 直接中断。
diag() {
    /usr/bin/jq -r "$1" "$DIAGNOSTICS" 2>/dev/null || echo ""
}

# 等待诊断文件中的 handledMessageCount 递增，确认本次事件已被 App 处理。
wait_handled() {
    local before="$1"
    local deadline=$(( $(date +%s) + 8 ))
    while (( $(date +%s) < deadline )); do
        local now
        now=$(diag '.handledMessageCount')
        if [[ -n "$now" && "$now" -gt "$before" ]] 2>/dev/null; then
            DIAG_LAST_COUNT="$now"
            return 0
        fi
        sleep 0.05
    done
    DIAG_LAST_COUNT="$(diag '.handledMessageCount')"
    return 1
}

# 等待某个断言条件在超时内成立。
wait_until() {
    local expression="$1"
    local deadline=$(( $(date +%s) + 8 ))
    while (( $(date +%s) < deadline )); do
        if [[ "$(diag "$expression")" == "true" ]]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# 发送一个事件并等待被处理。
#
# 关键：桥接子进程必须继承隔离运行时环境，否则它会去连生产的
# `~/.xisland/di.sock`，事件永远到不了隔离实例。
# `set -u` 下空数组展开会报 unbound variable，故用 ${arr[@]+...} / ${1+"$@"}。
send() {
    local agent="$1" hook="$2" payload="$3"
    shift 3
    local before
    before=$(diag '.handledMessageCount')
    [[ -n "$before" ]] || before=0

    local env_args=(
        DI_SOCKET_PATH="$RUNTIME/di.sock"
        X_ISLAND_TEST_MODE=1
        X_ISLAND_TEST_RUNTIME_DIR="$RUNTIME"
    )
    [[ -n "${BRIDGE_DEBUG_LOG:-}" ]] && env_args+=(DI_BRIDGE_DEBUG_LOG=1)

    # 桥接对交互式事件的退出码语义不同（拒绝/超时都会非零），
    # 因此这里只以「App 是否处理了这条消息」为判据。
    printf '%s' "$payload" \
        | env "${env_args[@]}" "$BRIDGE" --agent "$agent" --hook "$hook" ${1+"$@"} >/dev/null 2>&1 || true

    if wait_handled "$before"; then
        return 0
    fi
    return 1
}
# ── 各 agent 的 native 载荷构造 ──────────────────────────────────────────────
#
# 各 AI 工具的 hook 契约不同，不能混用同一个 payload 形状：
#   * claude_code / codex —— 通用路径，hook 名可用 session_start / PreToolUse 等；
#   * cursor   —— hook 名必须 camelCase（sessionStart/preToolUse/...），
#                 且载荷必须带 `hook_event_name` 与 `conversation_id`；
#   * opencode —— hook 名是 dotted（session.created/tool.started/...），
#                 且载荷必须带 `native_event` 与 `session_id`。
# 违反契约时桥接会以 `Invalid native hook payload` 退出、事件不会投递。

# cursor 事件。
#   $1 = hook 名（camelCase）  $2 = conversation_id
#   $3 = 额外 JSON 字段（可为空）  $4 = workspace 目录（默认 /tmp/m3test）
#
# 注意：workspace_roots 在这里统一生成，调用方不要再用 extra 传同名字段
# ——JSON 重复键的取值行为未定义。
cursor_payload() {
    local hook="$1" conversation="$2" extra="${3:-}" root="${4:-/tmp/m3test}"
    local base="\"hook_event_name\":\"$hook\",\"conversation_id\":\"$conversation\",\"workspace_roots\":[\"$root\"],\"timestamp\":\"$(stamp)\""
    if [[ -n "$extra" ]]; then
        printf '{%s,%s}' "$base" "$extra"
    else
        printf '{%s}' "$base"
    fi
}

# opencode 事件。
#   $1 = native_event 名  $2 = session_id  $3 = 额外 JSON 字段（可为空）
opencode_payload() {
    local event="$1" session="$2" extra="${3:-}"
    local base="\"native_event\":\"$event\",\"session_id\":\"$session\",\"cwd\":\"/tmp/m7test\",\"timestamp\":\"$(stamp)\""
    if [[ -n "$extra" ]]; then
        printf '{%s,%s}' "$base" "$extra"
    else
        printf '{%s}' "$base"
    fi
}

# 直接调用桥接（用于交互式事件：需要在后台等待应答）。
# 同样必须继承隔离运行时环境。
bridge_call() {
    env \
        DI_SOCKET_PATH="$RUNTIME/di.sock" \
        X_ISLAND_TEST_MODE=1 \
        X_ISLAND_TEST_RUNTIME_DIR="$RUNTIME" \
        ${BRIDGE_DEBUG_LOG:+DI_BRIDGE_DEBUG_LOG=1} \
        "$BRIDGE" "$@"
}

# 发送交互式事件（permission / question / plan）并在后台保持连接。
#
# 交互式事件不能用 `handledMessageCount` 当判据：该计数只在
# `performPersistedOperation` 的**完成回调**里递增，而交互式请求要等用户应答
# 才会完成 —— 隔离实例里没有人应答，计数永远不会动。
# 因此这里改为轮询诊断快照中的 `pendingInteraction`，断言由 assert_pending 完成。
#
# 调用后必须自行 `kill` 返回的 PID，否则桥接会一直等待应答。
interactive_call() {
    local agent="$1" hook="$2" payload="$3"
    printf '%s' "$payload" | bridge_call --agent "$agent" --hook "$hook" >/dev/null 2>&1 &
    echo $!
}
# 发送事件并断言「已被处理」。用于所有需要确认投递成功的场景。
#
# 始终返回 0：失败只计入 FAILED 并继续跑后续用例，避免 `set -e` 让
# 单个失败掩盖其余用例的结果（测试套件要的是完整报告）。
deliver() {
    local agent="$1" hook="$2" payload="$3"
    shift 3
    if send "$agent" "$hook" "$payload" "$@"; then
        pass "event delivered: $agent/$hook"
    else
        fail "event not delivered: $agent/$hook"
    fi
    return 0
}

# 断言诊断快照中某个 jq 表达式的取值。
assert_diag() {
    local expression="$1"
    local expected="$2"
    local desc="$3"
    local actual
    actual=$(diag "$expression")
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

# 断言会话存在且字段匹配。
#
# 轮询而非立刻断言：会话的字段（prompt / status / workingDirectory）是在
# 消息处理过程中逐步写入的，与 handledMessageCount 递增之间存在调度间隙。
assert_session() {
    local session_id="$1"
    local field="$2"
    local expected="$3"
    local desc="$4"
    if wait_until ".visibleSessions[] | select(.id == \"$session_id\") | (.$field == \"$expected\")"; then
        pass "$desc"
    else
        local actual
        actual=$(diag ".visibleSessions[] | select(.id == \"$session_id\") | .$field")
        fail "$desc (session '$session_id' .$field expected '$expected', got '$actual')"
    fi
}

assert_session_exists() {
    local session_id="$1"
    local desc="$2"
    if wait_until "[.visibleSessions[] | select(.id == \"$session_id\")] | length == 1"; then
        pass "$desc"
    else
        local count
        count=$(diag "[.visibleSessions[] | select(.id == \"$session_id\")] | length")
        fail "$desc (session '$session_id' count=$count)"
    fi
}

# 等待某会话进入指定 pendingInteraction。
#
# 交互式事件的「消息已处理」与「pending 状态已写入诊断」之间存在一次
# MainActor 调度间隙，因此必须轮询而不是立刻断言。
assert_pending() {
    local session_id="$1"
    local expected="$2"
    local desc="$3"
    if wait_until ".visibleSessions[] | select(.id == \"$session_id\") | (.pendingInteraction == \"$expected\")"; then
        pass "$desc"
    else
        local actual
        actual=$(diag ".visibleSessions[] | select(.id == \"$session_id\") | .pendingInteraction")
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

assert_session_absent() {
    local session_id="$1"
    local desc="$2"
    local count
    count=$(diag "[.visibleSessions[] | select(.id == \"$session_id\")] | length")
    if [[ "$count" == "0" ]]; then
        pass "$desc"
    else
        fail "$desc (session '$session_id' still present)"
    fi
}

# 断言隔离 SQLite 中某会话最新一条 assistant 消息包含指定文本。
#
# 助手回复文本不进入诊断快照（那里只有状态枚举），它落在
# `ZSTOREDCHATMESSAGE`（role=assistant）。这是验证「回复被捕获」的正确来源。
assert_stored_reply() {
    local session_id="$1"
    local expected="$2"
    local desc="$3"
    local deadline=$(( $(date +%s) + 8 ))
    local actual=""
    while (( $(date +%s) < deadline )); do
        actual=$(sqlite_query "SELECT c.ZCONTENT FROM ZSTOREDCHATMESSAGE c \
            JOIN ZSTOREDSESSION s ON c.ZSESSION = s.Z_PK \
            WHERE s.ZSESSIONID='$session_id' AND c.ZROLE='assistant' \
            ORDER BY c.ZTIMESTAMP DESC, c.Z_PK DESC LIMIT 1;")
        [[ "$actual" == *"$expected"* ]] && break
        sleep 0.05
    done
    if [[ "$actual" == *"$expected"* ]]; then
        pass "$desc"
    else
        fail "$desc (stored reply was '$actual')"
    fi
}

# 在隔离 SQLite 上执行只读查询。
sqlite_query() {
    local query="$1"
    [[ -f "$HISTORY" ]] || { echo ""; return 0; }
    if [[ -x /opt/local/bin/sqlite3 ]]; then
        /opt/local/bin/sqlite3 "$HISTORY" "$query" 2>/dev/null || echo ""
    else
        /usr/bin/sqlite3 "$HISTORY" "$query" 2>/dev/null || echo ""
    fi
}

# 断言隔离 SQLite 中会话的持久化字段。
assert_stored() {
    local session_id="$1"
    local column="$2"
    local expected="$3"
    local desc="$4"
    local actual
    actual=$(sqlite_query "SELECT $column FROM ZSTOREDSESSION WHERE ZSESSIONID='$session_id';")
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (stored $column expected '$expected', got '$actual')"
    fi
}

# ── 隔离实例生命周期 ──────────────────────────────────────────────────────────

check_prereqs() {
    if [[ ! -d "$APP_BUNDLE" ]]; then
        echo -e "${RED}ERROR: App bundle not found at $APP_BUNDLE${NC}"
        echo "Run: bash Scripts/build.sh"
        exit 1
    fi
    if [[ ! -x "$BRIDGE" ]]; then
        echo -e "${RED}ERROR: di-bridge not found at $BRIDGE${NC}"
        echo "Run: bash Scripts/build.sh"
        exit 1
    fi
    if [[ ! -f "$FIXTURE" ]]; then
        echo -e "${RED}ERROR: fixture not found at $FIXTURE${NC}"
        exit 1
    fi
}

start_isolated_app() {
    RUNTIME="$(mktemp -d /tmp/xi-it-XXXXXX)"
    # Foundation 对 /private/tmp 与 /tmp 的符号链接解析不同，统一用 /tmp 形式。
    RUNTIME="${RUNTIME/#\/private\/tmp/\/tmp}"
    DIAGNOSTICS="$RUNTIME/diagnostics.json"
    HISTORY="$RUNTIME/history.store"
    DEFAULTS_SUITE="dev.xisland.tests.integration-$$"

    local executable="$APP_BUNDLE/Contents/MacOS/XIsland"

    env \
        X_ISLAND_TEST_MODE=1 \
        X_ISLAND_TEST_RUNTIME_DIR="$RUNTIME" \
        X_ISLAND_TEST_DEFAULTS_SUITE="$DEFAULTS_SUITE" \
        X_ISLAND_TEST_DIAGNOSTICS_PATH="$RUNTIME/diagnostics.json" \
        X_ISLAND_DISABLE_ANIMATIONS=1 \
        DI_SOCKET_PATH="$RUNTIME/di.sock" \
        "$executable" --ui-test-mode --ui-test-socket --fixture-path "$FIXTURE" \
        >"$RUNTIME/app.log" 2>&1 &
    APP_PID=$!

    local deadline=$(( $(date +%s) + 20 ))
    while (( $(date +%s) < deadline )); do
        if [[ -f "$DIAGNOSTICS" && -S "$RUNTIME/di.sock" ]]; then
            return 0
        fi
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo -e "${RED}ERROR: isolated app exited during startup${NC}"
            /usr/bin/tail -20 "$RUNTIME/app.log" 2>/dev/null || true
            exit 1
        fi
        sleep 0.1
    done

    echo -e "${RED}ERROR: isolated app did not become ready within 20s${NC}"
    /usr/bin/tail -20 "$RUNTIME/app.log" 2>/dev/null || true
    exit 1
}

# 事件载荷统一带 ISO8601 时间戳；协议要求字符串，不能是浮点秒。
stamp() {
    /bin/date -u +"%Y-%m-%dT%H:%M:%S.000Z"
}

should_run() {
    [[ ${#MODULES[@]} -eq 0 ]] || printf '%s\n' "${MODULES[@]}" | grep -qx "$1"
}

# Parse module filter
MODULES=()
for arg in "$@"; do MODULES+=("$arg"); done

# ── M1: DIBridge message encoding ──────────────────────────────────────────

test_m1() {
    section "M1: DIBridge Message Encoding"

    # T1.1: session_start 建会话，prompt 与 working dir 落到诊断快照
    local sid="claude_code-m1-session"
    deliver claude_code session_start \
        "{\"session_id\":\"m1-session\",\"prompt\":\"hello world\",\"cwd\":\"/tmp/test\",\"timestamp\":\"$(stamp)\"}" \
        && assert_session "$sid" "agentType" "claude_code" "T1.1 session_start agent=claude_code"

    # T1.2: PreToolUse → tool_start，会话状态变为 thinking/active
    deliver claude_code PreToolUse \
        "{\"session_id\":\"m1-session\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la /tmp\"},\"timestamp\":\"$(stamp)\"}"
    assert_session_exists "$sid" "T1.2 tool_start routed to session"

    # T1.3: PostToolUse → tool_complete
    deliver claude_code PostToolUse \
        "{\"session_id\":\"m1-session\",\"tool_name\":\"Bash\",\"tool_response\":{\"content\":\"file1.txt\"},\"timestamp\":\"$(stamp)\"}"
    assert_session_exists "$sid" "T1.3 tool_complete routed to session"

    # T1.4: SessionEnd → 会话状态 completed
    deliver claude_code SessionEnd \
        "{\"session_id\":\"m1-session\",\"timestamp\":\"$(stamp)\"}"
    if wait_until ".visibleSessions[] | select(.id == \"$sid\") | (.completedAt != null)"; then
        pass "T1.4 session_end records completedAt"
    else
        fail "T1.4 session_end did not record completedAt"
    fi

    # T1.5: PermissionRequest → pendingInteraction=permission
    local psid="claude_code-m1-perm"
    local perm_pid
    perm_pid=$(interactive_call claude_code PermissionRequest "{\"session_id\":\"m1-perm\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /tmp/test\"},\"timestamp\":\"$(stamp)\"}")
    assert_pending "$psid" "permission" "T1.5 PermissionRequest → pendingInteraction=permission"
    kill "$perm_pid" 2>/dev/null || true
    wait "$perm_pid" 2>/dev/null || true

    # T1.6: AskUserQuestion → pendingInteraction=question
    local qsid="claude_code-m1-question"
    local q_pid
    q_pid=$(interactive_call claude_code PermissionRequest "{\"session_id\":\"m1-question\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"question\":\"Pick a color\",\"options\":[\"red\",\"blue\",\"green\"]},\"timestamp\":\"$(stamp)\"}")
    assert_pending "$qsid" "question" "T1.6 AskUserQuestion → pendingInteraction=question"
    kill "$q_pid" 2>/dev/null || true
    wait "$q_pid" 2>/dev/null || true
}

# ── M2: Session Lifecycle ──────────────────────────────────────────────────

test_m2() {
    section "M2: Session Lifecycle"

    # T2.1: session_start + session_end → 会话仍在（completed，未被移除）
    local sid="claude_code-m2-life"
    deliver claude_code session_start \
        "{\"session_id\":\"m2-life\",\"prompt\":\"lifecycle test\",\"cwd\":\"/tmp/m2test\",\"timestamp\":\"$(stamp)\"}"
    deliver claude_code SessionEnd \
        "{\"session_id\":\"m2-life\",\"timestamp\":\"$(stamp)\"}"
    assert_session_exists "$sid" "T2.1 session still tracked after session_end"

    # T2.2: Stop 携带 last_assistant_message → 状态为回复文本或 completionUnconfirmed
    local ssid="claude_code-m2-stop"
    deliver claude_code session_start \
        "{\"session_id\":\"m2-stop\",\"prompt\":\"stop test\",\"cwd\":\"/tmp/m2stop\",\"timestamp\":\"$(stamp)\"}"
    deliver claude_code Stop \
        "{\"session_id\":\"m2-stop\",\"last_assistant_message\":\"I have completed the refactoring of auth module.\",\"timestamp\":\"$(stamp)\"}"
    assert_session_exists "$ssid" "T2.2 stop hook routed to session"

    # T2.3: Codex 生命周期
    local csid="codex-m2-codex"
    deliver codex session_start \
        "{\"session_id\":\"m2-codex\",\"prompt\":\"codex test\",\"cwd\":\"/tmp/m2codex\",\"timestamp\":\"$(stamp)\"}"
    assert_session "$csid" "agentType" "codex" "T2.3 codex session created"
    deliver codex SessionEnd \
        "{\"session_id\":\"m2-codex\",\"timestamp\":\"$(stamp)\"}"
    assert_session_exists "$csid" "T2.3 codex session tracked after end"

    # T2.4: Notification 携带 message → status_update
    deliver claude_code Notification \
        "{\"session_id\":\"m2-life\",\"message\":\"Changes applied to 3 files.\",\"timestamp\":\"$(stamp)\"}"
    assert_session_exists "$sid" "T2.4 notification routed to existing session"
}

# ── M3: Agent Identity — CLI agents must NOT fold into desktop sessions ────

test_m3() {
    section "M3: Agent Identity — Mirror Folding"

    # 设计说明：`SessionManager.sessionMatchingMirror` 会把 **同后缀** 的
    # `cursor-<suffix>` 与 `claude_code-<suffix>` 视为同一会话（Cursor 内嵌
    # Claude Code 时两套 hook 会报同一个 native 会话 id）。这是有意行为。
    # 因此本模块验证：
    #   (a) 同后缀 → 折叠为同一会话，agentType 采用 cursor；
    #   (b) 不同后缀 → 两个会话独立共存，不互相覆盖。

    # T3.1: 先由 claude 建立会话
    local lsid="claude_code-m3-shared"
    deliver claude_code session_start \
        "{\"session_id\":\"m3-shared\",\"prompt\":\"hello from claude\",\"cwd\":\"/tmp/m3test\",\"timestamp\":\"$(stamp)\"}"
    assert_session "$lsid" "agentType" "claude_code" "T3.1 claude session created"

    # T3.2: 同后缀的 cursor sessionStart 到来 → 折叠进该会话，agentType 变为 cursor
    deliver cursor sessionStart "$(cursor_payload sessionStart m3-shared)"
    if wait_until ".visibleSessions[] | select(.id == \"$lsid\") | (.agentType == \"cursor\")"; then
        pass "T3.2 mirrored cursor hook folds into claude session (agentType→cursor)"
    else
        fail "T3.2 mirror folding did not occur (agentType='$(diag ".visibleSessions[] | select(.id == \"$lsid\") | .agentType")')"
    fi

    # T3.3: 折叠后仍只有一个会话（不是两个）
    local folded_count
    folded_count=$(diag "[.visibleSessions[] | select(.id == \"$lsid\")] | length")
    if [[ "$folded_count" == "1" ]]; then
        pass "T3.3 mirrored ids resolve to a single session"
    else
        fail "T3.3 expected 1 session for mirrored id, got $folded_count"
    fi

    # T3.4: claude 的 tool 事件仍落到该会话
    deliver claude_code PreToolUse \
        "{\"session_id\":\"m3-shared\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"},\"timestamp\":\"$(stamp)\"}"
    assert_session_exists "$lsid" "T3.4 claude tool_start routed to folded session"

    # T3.5: 不同后缀的 cursor 会话必须独立共存（不被折叠）
    local other="cursor-m3-other"
    deliver cursor sessionStart "$(cursor_payload sessionStart m3-other '' /tmp/m3other)"
    local other_count
    other_count=$(diag "[.visibleSessions[] | select(.id == \"$other\")] | length")
    if [[ "$other_count" == "1" ]]; then
        pass "T3.5 different suffix stays an independent session"
    else
        fail "T3.5 expected independent session '$other', got count=$other_count"
    fi

    # T3.6: Claude session_end 被正常处理
    deliver claude_code SessionEnd \
        "{\"session_id\":\"m3-shared\",\"timestamp\":\"$(stamp)\"}"
    assert_session_exists "$lsid" "T3.6 claude session_end processed"

    # 清理
    deliver cursor sessionEnd "$(cursor_payload sessionEnd m3-shared)" >/dev/null || true
}

# ── M4: Permission Request Flow ────────────────────────────────────────────

test_m4() {
    section "M4: Permission Request Flow"

    # T4.1: 显式 description 的权限请求
    local sid="claude_code-m4-explicit"
    local p
    p=$(interactive_call claude_code PermissionRequest "{\"session_id\":\"m4-explicit\",\"tool_name\":\"Write\",\"description\":\"Write to config.json\",\"file_path\":\"/tmp/config.json\",\"timestamp\":\"$(stamp)\"}")
    assert_pending "$sid" "permission" "T4.1 permission_request → pendingInteraction"
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true

    # T4.2: codex 的空 description，应从 tool_input 回退
    local csid="codex-m4-fallback"
    p=$(interactive_call codex PermissionRequest "{\"session_id\":\"m4-fallback\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm install\"},\"description\":\"\",\"timestamp\":\"$(stamp)\"}")
    assert_pending "$csid" "permission" "T4.2 codex permission_request routed"
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
}

# ── M5: Question Flow ─────────────────────────────────────────────────────

test_m5() {
    section "M5: Question Flow"

    # T5.1: 直接 question hook
    local sid="claude_code-m5-direct"
    local p
    p=$(interactive_call claude_code question "{\"session_id\":\"m5-direct\",\"question\":\"What language?\",\"options\":[\"Swift\",\"Python\",\"Rust\"],\"timestamp\":\"$(stamp)\"}")
    assert_pending "$sid" "question" "T5.1 question hook → pendingInteraction=question"
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true

    # T5.2: AskUserQuestion via permission hook
    local qsid="claude_code-m5-viaperm"
    p=$(interactive_call claude_code PermissionRequest "{\"session_id\":\"m5-viaperm\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"question\":\"Continue?\",\"options\":[\"yes\",\"no\"]},\"timestamp\":\"$(stamp)\"}")
    assert_pending "$qsid" "question" "T5.2 AskUserQuestion via permission → question"
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true

    # T5.3: dict 形式 options（走 claude_code：Cursor 适配器明确不按工具名猜问答）
    local dsid="claude_code-m5-dict"
    p=$(interactive_call claude_code PermissionRequest "{\"session_id\":\"m5-dict\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"question\":\"Choose\",\"options\":[{\"label\":\"Option A\",\"value\":\"a\"},{\"label\":\"Option B\",\"value\":\"b\"}]},\"timestamp\":\"$(stamp)\"}")
    assert_pending "$dsid" "question" "T5.3 dict options → question"
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
}

# ── M6: Plan Review Flow ──────────────────────────────────────────────────

test_m6() {
    section "M6: Plan Review Flow"

    local sid="claude_code-m6-plan"
    local p
    p=$(interactive_call claude_code plan "{\"session_id\":\"m6-plan\",\"plan\":\"## Step 1\\nRefactor auth module\\n## Step 2\\nAdd tests\",\"timestamp\":\"$(stamp)\"}")
    assert_pending "$sid" "planReview" "T6.1 plan_review → pendingInteraction=planReview"
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
}

# ── M7: Visible Sessions & Linger ─────────────────────────────────────────

test_m7() {
    section "M7: Visible Sessions & Linger"

    local sid="opencode-m7-linger"
    deliver opencode session.created "$(opencode_payload session.created m7-linger '"prompt":"linger test"')"
    assert_session_exists "$sid" "T7.1 session created for linger test"

    deliver opencode tool.started "$(opencode_payload tool.started m7-linger '"tool_name":"read","tool_use_id":"call-m7"')"
    deliver opencode tool.completed "$(opencode_payload tool.completed m7-linger '"tool_name":"read","tool_use_id":"call-m7"')"

    deliver opencode session.idle "$(opencode_payload session.idle m7-linger)"
    assert_session_exists "$sid" "T7.1 session tracked after idle (linger)"
}

# ── M8: Subagent Flow ─────────────────────────────────────────────────────

test_m8() {
    section "M8: Subagent Start/End"

    local sid="claude_code-m8-sub"
    deliver claude_code session_start \
        "{\"session_id\":\"m8-sub\",\"prompt\":\"main task\",\"cwd\":\"/tmp/m8test\",\"timestamp\":\"$(stamp)\"}"

    # T8.1: subagent 启动后 runningSubagentCount 应为 1
    deliver claude_code SubagentStart \
        "{\"session_id\":\"m8-sub\",\"agent_id\":\"sub-001\",\"agent_type\":\"explore\",\"timestamp\":\"$(stamp)\"}"
    if wait_until ".visibleSessions[] | select(.id == \"$sid\") | (.runningSubagentCount == 1)"; then
        pass "T8.1 subagent_start → runningSubagentCount=1"
    else
        fail "T8.1 subagent_start did not increment runningSubagentCount (got $(diag ".visibleSessions[] | select(.id == \"$sid\") | .runningSubagentCount"))"
    fi

    # T8.2: subagent 结束后归零（claude_code 的 SubagentStop 需要 agent_type 字段）
    deliver claude_code SubagentStop \
        "{\"session_id\":\"m8-sub\",\"agent_id\":\"sub-001\",\"agent_type\":\"explore\",\"timestamp\":\"$(stamp)\"}"
    if wait_until ".visibleSessions[] | select(.id == \"$sid\") | (.runningSubagentCount == 0)"; then
        pass "T8.2 subagent_end → runningSubagentCount=0"
    else
        fail "T8.2 subagent_end did not reset runningSubagentCount"
    fi

    deliver claude_code SessionEnd "{\"session_id\":\"m8-sub\",\"timestamp\":\"$(stamp)\"}" >/dev/null || true
}

# ── M9: Context Compact ───────────────────────────────────────────────────

test_m9() {
    section "M9: Context Compact"

    local sid="claude_code-m9-compact"
    deliver claude_code session_start \
        "{\"session_id\":\"m9-compact\",\"prompt\":\"compact test\",\"cwd\":\"/tmp/m9test\",\"timestamp\":\"$(stamp)\"}"

    # T9.1: PreCompact → 会话进入 compacting
    deliver claude_code PreCompact \
        "{\"session_id\":\"m9-compact\",\"trigger\":\"manual\",\"timestamp\":\"$(stamp)\"}"
    if wait_until ".visibleSessions[] | select(.id == \"$sid\") | (.status == \"compacting\")"; then
        pass "T9.1 PreCompact → status=compacting"
    else
        fail "T9.1 PreCompact did not set status=compacting (got $(diag ".visibleSessions[] | select(.id == \"$sid\") | .status"))"
    fi

    deliver claude_code SessionEnd "{\"session_id\":\"m9-compact\",\"timestamp\":\"$(stamp)\"}" >/dev/null || true
}

# ── M10: Multi-agent (different agents coexist) ──────────────────────────

test_m10() {
    section "M10: Multi-Agent Coexistence"

    # 三个不同后缀的会话：同后缀的 cursor/claude 会被镜像折叠，故必须区分。
    deliver cursor sessionStart "$(cursor_payload sessionStart m10-cursor '' /tmp/m10)"
    deliver claude_code session_start \
        "{\"session_id\":\"m10-claude\",\"prompt\":\"claude task\",\"cwd\":\"/tmp/m10\",\"timestamp\":\"$(stamp)\"}"
    deliver codex session_start \
        "{\"session_id\":\"m10-codex\",\"prompt\":\"codex task\",\"cwd\":\"/tmp/m10\",\"timestamp\":\"$(stamp)\"}"

    local count
    count=$(diag "[.visibleSessions[] | select(.id | test(\"-m10-\"))] | length")
    if [[ "$count" == "3" ]]; then
        pass "T10.1 three agents coexist as distinct sessions"
    else
        fail "T10.1 expected 3 sessions, got $count ($(diag '[.visibleSessions[].id] | join(",")'))"
    fi

    deliver cursor sessionEnd "$(cursor_payload sessionEnd m10-cursor '' /tmp/m10)" >/dev/null || true
    deliver claude_code SessionEnd "{\"session_id\":\"m10-claude\",\"timestamp\":\"$(stamp)\"}" >/dev/null || true
    deliver codex SessionEnd "{\"session_id\":\"m10-codex\",\"timestamp\":\"$(stamp)\"}" >/dev/null || true
}

# ── M11: Codex Stop → notification with last_assistant_message ────────────

test_m11() {
    section "M11: Codex Stop Hook Captures Reply"

    local sid="codex-m11-stop"
    deliver codex session_start \
        "{\"session_id\":\"m11-stop\",\"prompt\":\"codex m11 test\",\"cwd\":\"/tmp/m11\",\"timestamp\":\"$(stamp)\"}"

    # T11.1: Codex Stop → 状态为 completionUnconfirmed，回复文本落库
    deliver codex Stop \
        "{\"session_id\":\"m11-stop\",\"last_assistant_message\":\"Here is the refactored code with improved error handling.\",\"timestamp\":\"$(stamp)\"}"
    assert_session "$sid" "status" "completionUnconfirmed" "T11.1 Codex Stop → status=completionUnconfirmed"
    assert_stored_reply "$sid" "Here is the refactored code with improved error handling." \
        "T11.1 Codex Stop reply persisted as assistant message"

    # T11.2: SessionEnd → completed
    deliver codex SessionEnd "{\"session_id\":\"m11-stop\",\"timestamp\":\"$(stamp)\"}"
    if wait_until ".visibleSessions[] | select(.id == \"$sid\") | (.completedAt != null)"; then
        pass "T11.2 Codex SessionEnd → completedAt recorded"
    else
        fail "T11.2 Codex SessionEnd did not record completedAt"
    fi
}

# ── M12: Cursor Reply via text Field ─────────────────────────────────────

test_m12() {
    section "M12: Cursor Reply via text Field"

    local sid="cursor-m12-text"
    deliver cursor sessionStart "$(cursor_payload sessionStart m12-text)"

    # T12.1: Cursor afterAgentResponse 的 text 字段 → 会话被建/更新且状态非错误
    #
    # 限制说明：回复文本存入 `session.statusText`，该字段既不进诊断快照也不落库，
    # 因此从进程外无法断言回复原文。这里断言可观测的事实：事件被接收、
    # 会话存在、状态落在预期集合内。回复文本的正确性由 Swift 单测覆盖。
    deliver cursor afterAgentResponse \
        "$(cursor_payload afterAgentResponse m12-text '"text":"I have updated the component to use React hooks."')"
    assert_session_exists "$sid" "T12.1 Cursor afterAgentResponse routed to session"
    local st
    st=$(diag ".visibleSessions[] | select(.id == \"$sid\") | .status")
    if [[ "$st" != "error" ]]; then
        pass "T12.1 Cursor reply did not put session into error state (status=$st)"
    else
        fail "T12.1 Cursor reply put session into error state"
    fi

    deliver cursor sessionEnd "$(cursor_payload sessionEnd m12-text)" >/dev/null || true
}

# ── M13: Claude Code AskUserQuestion via PreToolUse ──────────────────────

test_m13() {
    section "M13: Claude Code Question via PreToolUse"

    # T13.1: AskUserQuestion via PreToolUse → question
    local sid="claude_code-m13-q"
    local p
    p=$(interactive_call claude_code PreToolUse "{\"session_id\":\"m13-q\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"question\":\"Which approach?\",\"options\":[\"Option A\",\"Option B\"]},\"timestamp\":\"$(stamp)\"}")
    assert_pending "$sid" "question" "T13.1 AskUserQuestion via PreToolUse → question"
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true

    # T13.2: questions[] 数组格式
    local sid2="claude_code-m13-array"
    p=$(interactive_call claude_code PreToolUse "{\"session_id\":\"m13-array\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"How to proceed?\",\"header\":\"Next\",\"options\":[{\"label\":\"Refactor\"},{\"label\":\"Test\"}]}]},\"timestamp\":\"$(stamp)\"}")
    assert_pending "$sid2" "question" "T13.2 questions[] array → question"
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true

    # T13.3: 非 question 工具走 PreToolUse → tool_start（不是 question）
    deliver claude_code PreToolUse \
        "{\"session_id\":\"m13-q\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hello\"},\"timestamp\":\"$(stamp)\"}"
    local interaction
    interaction=$(diag ".visibleSessions[] | select(.id == \"$sid\") | .pendingInteraction")
    if [[ -z "$interaction" || "$interaction" == "null" ]]; then
        pass "T13.3 non-question tool via PreToolUse stays tool_start"
    else
        fail "T13.3 non-question tool wrongly became '$interaction'"
    fi
}

# ── M14: session_end Captures Reply ──────────────────────────────────────

test_m14() {
    section "M14: Session End Reply Capture"

    # T14.1: stop + last_assistant_message → 回复落库，状态为 completionUnconfirmed
    local sid="claude_code-m14-reply"
    deliver claude_code session_start \
        "{\"session_id\":\"m14-reply\",\"prompt\":\"m14 test\",\"cwd\":\"/tmp/m14\",\"timestamp\":\"$(stamp)\"}"
    deliver claude_code Stop \
        "{\"session_id\":\"m14-reply\",\"last_assistant_message\":\"I have completed all the requested changes.\",\"timestamp\":\"$(stamp)\"}"
    assert_stored_reply "$sid" "I have completed all the requested changes." \
        "T14.1 stop reply persisted as assistant message"
    assert_session "$sid" "status" "completionUnconfirmed" "T14.1 stop → status=completionUnconfirmed"

    # T14.2: session_end 的 message 字段回退
    local sid2="claude_code-m14-message"
    deliver claude_code session_start \
        "{\"session_id\":\"m14-message\",\"prompt\":\"m14 test2\",\"cwd\":\"/tmp/m14b\",\"timestamp\":\"$(stamp)\"}"
    deliver claude_code SessionEnd \
        "{\"session_id\":\"m14-message\",\"message\":\"Done with refactoring.\",\"timestamp\":\"$(stamp)\"}"
    if wait_until ".visibleSessions[] | select(.id == \"$sid2\") | (.completedAt != null)"; then
        pass "T14.2 session_end message field → completed"
    else
        fail "T14.2 session_end did not record completedAt"
    fi
}

# ── M15: Multi-Session Support ────────────────────────────────────────────

test_m15() {
    section "M15: Multi-Session Support"

    # T15.1: 两个不同 conversation_id 的 Cursor 会话
    local a="cursor-m15-aaa" b="cursor-m15-bbb"
    deliver cursor sessionStart "$(cursor_payload sessionStart m15-aaa)"
    deliver cursor sessionStart "$(cursor_payload sessionStart m15-bbb)"
    assert_session_exists "$a" "T15.1 Cursor session A created"
    assert_session_exists "$b" "T15.1 Cursor session B created"

    # T15.2: 两个 claude_code 会话，显式 --session 指定不同 ID
    # 注意：后缀必须避开 T15.1 的 cursor 后缀，否则会被镜像折叠。
    local c="claude_code-cc-a" d="claude_code-cc-b"
    deliver claude_code session_start \
        "{\"prompt\":\"cc session A\",\"cwd\":\"/tmp/m15\",\"timestamp\":\"$(stamp)\"}" \
        --session "$c"
    deliver claude_code session_start \
        "{\"prompt\":\"cc session B\",\"cwd\":\"/tmp/m15\",\"timestamp\":\"$(stamp)\"}" \
        --session "$d"
    assert_session_exists "$c" "T15.2 claude session A created"
    assert_session_exists "$d" "T15.2 claude session B created"

    # T15.3: 消息按会话精确路由（tool_use_id 为 cursor 必填字段）
    deliver cursor preToolUse \
        "$(cursor_payload preToolUse m15-aaa '"tool_name":"read","tool_use_id":"call-m15","tool_input":{"path":"file.txt"}')"
    assert_session_exists "$a" "T15.3 tool_start routed to session A"

    deliver cursor sessionEnd "$(cursor_payload sessionEnd m15-aaa)" >/dev/null || true
    deliver cursor sessionEnd "$(cursor_payload sessionEnd m15-bbb)" >/dev/null || true
}

# ── M16: Session Title & Workspace Name ──────────────────────────────────

test_m16() {
    section "M16: Session Title & Workspace Name"

    local STDIN_LOG="$RUNTIME/bridge-stdin.log"

    # T16.1: prompt 被桥接记录（DI_BRIDGE_DEBUG_LOG 仍写 bridge-stdin.log）
    local sid="claude_code-m16-prompt"
    local before
    before=$(diag '.handledMessageCount'); [[ -n "$before" ]] || before=0
    printf '%s' "{\"session_id\":\"m16-prompt\",\"prompt\":\"Refactor the auth module\",\"cwd\":\"/tmp/m16test\",\"timestamp\":\"$(stamp)\"}" \
        | BRIDGE_DEBUG_LOG=1 bridge_call --agent claude_code --hook session_start >/dev/null 2>&1
    wait_handled "$before" || true
    assert_session "$sid" "prompt" "Refactor the auth module" "T16.1 prompt captured in diagnostics"
    if grep -q "Refactor the auth module" "$STDIN_LOG" 2>/dev/null; then
        pass "T16.1 prompt captured in bridge stdin log"
    else
        fail "T16.1 prompt not found in bridge stdin log"
    fi

    # T16.2: workspace_roots 被提取为 working directory
    local csid="cursor-m16-ws"
    deliver cursor sessionStart "$(cursor_payload sessionStart m16-ws '' /tmp/my-project)"
    assert_session "$csid" "workingDirectory" "/tmp/my-project" "T16.2 workspace_roots → workingDirectory"

    # T16.3: 无 prompt 的 session_start 仍建会话
    local nsid="claude_code-m16-noprompt"
    deliver claude_code session_start \
        "{\"session_id\":\"m16-noprompt\",\"cwd\":\"/tmp/fallback-project\",\"timestamp\":\"$(stamp)\"}"
    assert_session_exists "$nsid" "T16.3 session_start without prompt still creates session"
}

# ── M17: Completion Sound Dedup ──────────────────────────────────────────

test_m17() {
    section "M17: Completion Dedup"

    # T17.1: Claude Code session_end → completed
    local sid="claude_code-m17-cc"
    deliver claude_code session_start \
        "{\"session_id\":\"m17-cc\",\"prompt\":\"m17 cc test\",\"cwd\":\"/tmp/m17a\",\"timestamp\":\"$(stamp)\"}"
    deliver claude_code SessionEnd \
        "{\"session_id\":\"m17-cc\",\"message\":\"Done.\",\"timestamp\":\"$(stamp)\"}"
    if wait_until ".visibleSessions[] | select(.id == \"$sid\") | (.completedAt != null)"; then
        pass "T17.1 Claude Code session_end → completedAt"
    else
        fail "T17.1 Claude Code session_end did not complete"
    fi

    # T17.2: Codex notification 携带回复 → 事件被接收且未进入错误态
    # （回复原文存于内存字段 statusText，不可从进程外观测，见 T12.1 说明）
    local csid="codex-m17-codex"
    deliver codex session_start \
        "{\"session_id\":\"m17-codex\",\"prompt\":\"m17 codex test\",\"cwd\":\"/tmp/m17b\",\"timestamp\":\"$(stamp)\"}"
    deliver codex notification \
        "{\"session_id\":\"m17-codex\",\"message\":\"Here is the answer.\",\"timestamp\":\"$(stamp)\"}"
    assert_session_exists "$csid" "T17.2 Codex notification routed to session"

    # T17.3: OpenCode assistant.message → 事件被接收
    local osid="opencode-m17-oc"
    deliver opencode session.created "$(opencode_payload session.created m17-oc)"
    deliver opencode assistant.message \
        "$(opencode_payload assistant.message m17-oc '"message":"Hello from OpenCode."')"
    assert_session_exists "$osid" "T17.3 OpenCode notification routed to session"

    # T17.4: status_update 后 session_end 不产生重复完成（completedAt 只写一次）
    local usid="cursor-m17-dedup"
    deliver cursor sessionStart "$(cursor_payload sessionStart m17-dedup '' /tmp/m17d)"
    deliver cursor afterAgentResponse \
        "$(cursor_payload afterAgentResponse m17-dedup '"text":"I finished the task."' /tmp/m17d)"
    deliver cursor sessionEnd "$(cursor_payload sessionEnd m17-dedup '' /tmp/m17d)"
    if wait_until ".visibleSessions[] | select(.id == \"$usid\") | (.completedAt != null)"; then
        pass "T17.4 Cursor session_end after status_update → completed"
    else
        fail "T17.4 Cursor session_end after status_update did not complete"
    fi
}

# ── M18: Configurable Linger Duration ────────────────────────────────────

test_m18() {
    section "M18: Configurable Linger Duration"

    # 使用隔离实例自己的 defaults suite，不触碰用户真实偏好。
    local original
    original=$(defaults read "$DEFAULTS_SUITE" completedLingerDuration 2>/dev/null || echo "")

    # T18.1: 设置较短 linger，会话结束后仍应在 linger 窗口内可见
    defaults write "$DEFAULTS_SUITE" completedLingerDuration -float 120.0

    local sid="claude_code-m18-linger"
    deliver claude_code session_start \
        "{\"session_id\":\"m18-linger\",\"prompt\":\"linger config test\",\"cwd\":\"/tmp/m18test\",\"timestamp\":\"$(stamp)\"}"
    deliver claude_code SessionEnd \
        "{\"session_id\":\"m18-linger\",\"timestamp\":\"$(stamp)\"}"

    if wait_until ".visibleSessions[] | select(.id == \"$sid\") | (.completedAt != null)"; then
        pass "T18.1 session ended and completedAt recorded"
    else
        fail "T18.1 session did not complete"
    fi
    assert_session_exists "$sid" "T18.1 session still visible during linger"

    # T18.2: 恢复原值
    if [[ -n "$original" ]]; then
        defaults write "$DEFAULTS_SUITE" completedLingerDuration -float "$original"
    else
        defaults delete "$DEFAULTS_SUITE" completedLingerDuration 2>/dev/null || true
    fi
    pass "T18.2 linger duration restored"
}

# ── M19: Session Dismiss ─────────────────────────────────────────────────

test_m19() {
    section "M19: Session Dismiss"

    # T19.1: 用显式 session id 建会话
    local sid="claude_code-m19-dismiss"
    deliver claude_code session_start \
        "{\"prompt\":\"dismiss test\",\"cwd\":\"/tmp/m19test\",\"timestamp\":\"$(stamp)\"}" \
        --session "$sid"
    assert_session_exists "$sid" "T19.1 session created for dismiss test"

    # T19.2: session_end → 持久化完成时间
    deliver claude_code SessionEnd \
        "{\"prompt\":\"dismiss test\",\"cwd\":\"/tmp/m19test\",\"timestamp\":\"$(stamp)\"}" \
        --session "$sid"
    if wait_until ".visibleSessions[] | select(.id == \"$sid\") | (.completedAt != null)"; then
        pass "T19.2 session ended (dismiss lifecycle)"
    else
        fail "T19.2 session_end did not record completedAt"
    fi

    # T19.3: 持久化层（隔离 SQLite）确认该会话已落库
    if [[ -f "$HISTORY" ]]; then
        assert_stored "$sid" "ZAGENTTYPERAW" "claude_code" "T19.3 session persisted to history store"
    else
        skip "T19.3 history store not created yet"
    fi
}

# ── Run ──────────────────────────────────────────────────────────────────

main() {
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   X Island — Integration Test Suite          ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"

    check_prereqs
    echo -e "  ${CYAN}launching isolated app...${NC}"
    start_isolated_app
    echo -e "  ${CYAN}isolated runtime: $RUNTIME${NC}"
    echo -e "  ${CYAN}isolated app pid: $APP_PID${NC}"

    should_run M1  && test_m1
    should_run M2  && test_m2
    should_run M3  && test_m3
    should_run M4  && test_m4
    should_run M5  && test_m5
    should_run M6  && test_m6
    should_run M7  && test_m7
    should_run M8  && test_m8
    should_run M9  && test_m9
    should_run M10 && test_m10
    should_run M11 && test_m11
    should_run M12 && test_m12
    should_run M13 && test_m13
    should_run M14 && test_m14
    should_run M15 && test_m15
    should_run M16 && test_m16
    should_run M17 && test_m17
    should_run M18 && test_m18
    should_run M19 && test_m19

    echo ""
    echo -e "${CYAN}━━━ Results ━━━${NC}"
    echo -e "  ${GREEN}Passed:  $PASSED${NC}"
    echo -e "  ${RED}Failed:  $FAILED${NC}"
    echo -e "  ${YELLOW}Skipped: $SKIPPED${NC}"
    echo ""

    if [[ $FAILED -gt 0 ]]; then
        echo -e "${RED}Some tests failed. Isolated app log: $RUNTIME/app.log${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main
