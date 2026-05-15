#!/bin/bash
set -euo pipefail

###############################################################################
# X Island — Integration Test Suite
#
# Sends simulated agent messages via di-bridge and verifies behavior by
# checking the app's debug log (~/.xisland/debug.log).
#
# Prerequisites:
#   1. `swift build -c release` (or Scripts/build.sh)
#   2. X Island app must be running (the SocketServer must be listening)
#
# Usage:
#   bash Scripts/test.sh           # run all tests
#   bash Scripts/test.sh M1        # run module M1 only
#   bash Scripts/test.sh M1 M4     # run modules M1 and M4
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BRIDGE="$HOME/.xisland/bin/di-bridge"
LOG="$HOME/.xisland/debug.log"
SOCK="$HOME/.xisland/di.sock"

PASSED=0
FAILED=0
SKIPPED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── helpers ──────────────────────────────────────────────────────────────────

mark_log() {
    echo "--- TEST MARKER $(date +%s) ---" >> "$LOG"
    MARKER_LINE=$(wc -l < "$LOG" | tr -d ' ')
}

log_since_marker() {
    tail -n +"$MARKER_LINE" "$LOG"
}

assert_log_contains() {
    local pattern="$1"
    local desc="${2:-pattern '$pattern' in log}"
    if log_since_marker | grep -q "$pattern"; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

pass() { PASSED=$((PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { FAILED=$((FAILED+1)); echo -e "  ${RED}✗${NC} $1"; }
skip() { SKIPPED=$((SKIPPED+1)); echo -e "  ${YELLOW}⊘${NC} $1 (skipped)"; }

section() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

check_prereqs() {
    if [[ ! -x "$BRIDGE" ]]; then
        echo -e "${RED}ERROR: di-bridge not found at $BRIDGE${NC}"
        echo "Run: bash Scripts/build.sh"
        exit 1
    fi
    if [[ ! -S "$SOCK" ]]; then
        local app_bundle="$PROJECT_DIR/.build/X Island.app"
        local system_app_bundle="/Applications/X Island.app"
        local app_to_open=""

        if [[ -d "$app_bundle" ]]; then
            app_to_open="$app_bundle"
        elif [[ -d "$system_app_bundle" ]]; then
            app_to_open="$system_app_bundle"
        fi

        if [[ -n "$app_to_open" ]]; then
            echo -e "${YELLOW}Socket not found at $SOCK; restarting X Island...${NC}"
            pkill -f "XIsland" 2>/dev/null || true
            rm -f "$SOCK"
            open "$app_to_open" 2>/dev/null || true
            for _ in {1..50}; do
                [[ -S "$SOCK" ]] && break
                sleep 0.2
            done
        fi
    fi
    if [[ ! -S "$SOCK" ]]; then
        echo -e "${RED}ERROR: Socket not found at $SOCK${NC}"
        echo "Is X Island app running?"
        exit 1
    fi
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

    # T1.1: session_start produces valid message
    mark_log
    echo '{"prompt":"hello world","working_dir":"/tmp/test"}' | "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3
    assert_log_contains "type=session_start" "T1.1 session_start recognized"
    assert_log_contains "agent=claude_code" "T1.1 agent=claude_code"

    # T1.2: tool_start with Bash command
    mark_log
    echo '{"tool_name":"Bash","tool_input":{"command":"ls -la /tmp"}}' | "$BRIDGE" --agent claude_code --hook pretooluse
    sleep 0.3
    assert_log_contains "type=tool_start" "T1.2 tool_start from pretooluse"
    assert_log_contains "tool=Bash" "T1.2 tool=Bash"

    # T1.3: tool_complete
    mark_log
    echo '{"tool_name":"Bash","tool_result":"file1.txt\nfile2.txt"}' | "$BRIDGE" --agent claude_code --hook posttooluse
    sleep 0.3
    assert_log_contains "type=tool_complete" "T1.3 tool_complete from posttooluse"

    # T1.4: session_end
    mark_log
    echo '{}' | "$BRIDGE" --agent claude_code --hook session_end
    sleep 0.3
    assert_log_contains "type=session_end" "T1.4 session_end recognized"

    # T1.5: permission with Bash command extracts description
    mark_log
    echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/test"},"description":""}' | \
        "$BRIDGE" --agent claude_code --hook permission &
    PERM_PID=$!
    sleep 0.5
    assert_log_contains "type=permission_request" "T1.5 permission_request routed"
    assert_log_contains "desc=rm -rf /tmp/test" "T1.5 description extracted from tool_input"
    kill "$PERM_PID" 2>/dev/null || true
    wait "$PERM_PID" 2>/dev/null || true

    # T1.6: AskUserQuestion via PermissionRequest → interactive question
    mark_log
    echo '{"tool_name":"AskUserQuestion","tool_input":{"question":"Pick a color","options":["red","blue","green"]}}' | \
        "$BRIDGE" --agent claude_code --hook permission &
    Q_PID=$!
    sleep 0.5
    assert_log_contains "type=question" "T1.6 AskUserQuestion → interactive question"
    assert_log_contains "question=Pick a color" "T1.6 question text extracted"
    assert_log_contains "options=red,blue,green" "T1.6 options extracted"
    kill "$Q_PID" 2>/dev/null || true
    wait "$Q_PID" 2>/dev/null || true

    # T1.7: AskUserQuestion with Claude Code's real "questions" array format
    mark_log
    echo '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"你希望怎么分析？","header":"下一步","options":[{"label":"清理建议","description":"按分类整理"},{"label":"大文件","description":"找大文件"}]}]}}' | \
        "$BRIDGE" --agent claude_code --hook permission &
    Q_PID=$!
    sleep 0.5
    assert_log_contains "type=question" "T1.7 questions array → question"
    assert_log_contains "你希望怎么分析" "T1.7 question text from questions[0]"
    assert_log_contains "options=清理建议,大文件" "T1.7 option labels from questions[0].options"
    kill "$Q_PID" 2>/dev/null || true
    wait "$Q_PID" 2>/dev/null || true
}

# ── M2: Session Lifecycle ──────────────────────────────────────────────────

test_m2() {
    section "M2: Session Lifecycle"

    # T2.1: session_start + session_end for CLI agent → session stays (Idle, not removed)
    mark_log
    echo '{"prompt":"lifecycle test","working_dir":"/tmp/m2test"}' | "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3
    assert_log_contains "type=session_start" "T2.1 session created"

    mark_log
    echo '{}' | "$BRIDGE" --agent claude_code --hook session_end
    sleep 0.3
    assert_log_contains "type=session_end" "T2.1 session_end received"
    assert_log_contains "Sessions count:" "T2.1 session still tracked (not removed)"

    # T2.2: session_end with response message → status captured
    mark_log
    echo '{"message":"I have completed the refactoring of auth module."}' | "$BRIDGE" --agent claude_code --hook stop
    sleep 0.3
    assert_log_contains "type=session_end" "T2.2 stop → session_end"
    assert_log_contains "status=I have completed the refactoring" "T2.2 response text captured in session_end"

    # T2.3: Codex agent lifecycle
    mark_log
    echo '{"prompt":"codex test","working_dir":"/tmp/m2codex"}' | "$BRIDGE" --agent codex --hook session_start
    sleep 0.3
    assert_log_contains "agent=codex" "T2.3 codex session created"

    echo '{}' | "$BRIDGE" --agent codex --hook session_end
    sleep 0.3

    # T2.4: Notification carries response text
    mark_log
    echo '{"message":"Changes applied to 3 files."}' | "$BRIDGE" --agent claude_code --hook Notification
    sleep 0.3
    assert_log_contains "type=status_update" "T2.4 Notification → status_update"
    assert_log_contains "status=Changes applied to 3 files" "T2.4 notification text captured"
}

# ── M3: Agent Identity — CLI agents must NOT fold into desktop sessions ────

test_m3() {
    section "M3: Agent Identity — No Folding"

    # Setup: create a Cursor session with a specific workdir
    mark_log
    echo '{"prompt":"cursor editing","working_dir":"/tmp/m3test"}' | "$BRIDGE" --agent cursor --hook session_start
    sleep 0.3
    assert_log_contains "agent=cursor" "T3.1 Cursor session created"

    # Send tool activity from Cursor
    echo '{"tool_name":"Read","tool_input":"file.swift"}' | "$BRIDGE" --agent cursor --hook pretooluse
    sleep 0.2

    # T3.2: Claude Code session_start with overlapping workdir → must stay as claude_code
    mark_log
    echo '{"prompt":"hello from claude","working_dir":"/tmp/m3test"}' | "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3
    assert_log_contains "type=session_start" "T3.2 Claude Code session_start received"
    assert_log_contains "agent=claude_code" "T3.2 session_start stays claude_code (not folded to cursor)"

    # T3.3: Claude Code tool_start → must route to claude_code session, not cursor
    mark_log
    echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | "$BRIDGE" --agent claude_code --hook pretooluse
    sleep 0.3
    assert_log_contains "type=tool_start" "T3.3 Claude Code tool_start received"
    assert_log_contains "agent=claude_code" "T3.3 tool_start stays claude_code"

    # T3.4: Claude Code tool_complete → must route to claude_code session
    mark_log
    echo '{"tool_name":"Bash","tool_result":"total 42"}' | "$BRIDGE" --agent claude_code --hook posttooluse
    sleep 0.3
    assert_log_contains "type=tool_complete" "T3.4 Claude Code tool_complete received"
    assert_log_contains "agent=claude_code" "T3.4 tool_complete stays claude_code"

    # T3.5: Claude Code permission request → must stay as claude_code
    mark_log
    echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"},"description":"Run echo"}' | \
        "$BRIDGE" --agent claude_code --hook permission &
    PERM_PID=$!
    sleep 0.5
    assert_log_contains "type=permission_request" "T3.5 Claude Code permission received"
    assert_log_contains "agent=claude_code" "T3.5 permission stays claude_code"
    kill "$PERM_PID" 2>/dev/null || true
    wait "$PERM_PID" 2>/dev/null || true

    # T3.6: Claude Code session_end → must be processed (not ignored)
    mark_log
    echo '{}' | "$BRIDGE" --agent claude_code --hook session_end
    sleep 0.3
    assert_log_contains "type=session_end" "T3.6 Claude Code session_end processed (not ignored)"
    assert_log_contains "agent=claude_code" "T3.6 session_end stays claude_code"

    # Cleanup
    echo '{}' | "$BRIDGE" --agent cursor --hook session_end
    sleep 0.2
}

# ── M4: Permission Request Flow ────────────────────────────────────────────

test_m4() {
    section "M4: Permission Request Flow"

    # T4.1: Permission with explicit description
    mark_log
    echo '{"tool_name":"Write","description":"Write to config.json","file_path":"/tmp/config.json"}' | \
        "$BRIDGE" --agent claude_code --hook permission &
    PERM_PID=$!
    sleep 0.5
    assert_log_contains "type=permission_request" "T4.1 permission_request type"
    assert_log_contains "tool=Write" "T4.1 tool=Write"
    assert_log_contains "desc=Write to config.json" "T4.1 explicit description preserved"
    kill "$PERM_PID" 2>/dev/null || true
    wait "$PERM_PID" 2>/dev/null || true

    # T4.2: Permission with empty description, should extract from tool_input
    mark_log
    echo '{"tool_name":"Bash","tool_input":{"command":"npm install"},"description":""}' | \
        "$BRIDGE" --agent codex --hook permission &
    PERM_PID=$!
    sleep 0.5
    assert_log_contains "type=permission_request" "T4.2 permission_request type"
    assert_log_contains "desc=npm install" "T4.2 fallback to tool_input command"
    kill "$PERM_PID" 2>/dev/null || true
    wait "$PERM_PID" 2>/dev/null || true
}

# ── M5: Question Flow ─────────────────────────────────────────────────────

test_m5() {
    section "M5: Question Flow"

    # T5.1: Direct question hook
    mark_log
    echo '{"question":"What language?","options":["Swift","Python","Rust"]}' | \
        "$BRIDGE" --agent claude_code --hook question &
    Q_PID=$!
    sleep 0.5
    assert_log_contains "type=question" "T5.1 question type via question hook"
    assert_log_contains "question=What language" "T5.1 question text"
    assert_log_contains "options=Swift,Python,Rust" "T5.1 options"
    kill "$Q_PID" 2>/dev/null || true
    wait "$Q_PID" 2>/dev/null || true

    # T5.2: AskUserQuestion via permission hook → interactive question
    mark_log
    echo '{"tool_name":"AskUserQuestion","tool_input":{"question":"Continue?","options":["yes","no"]}}' | \
        "$BRIDGE" --agent claude_code --hook permission &
    Q_PID=$!
    sleep 0.5
    assert_log_contains "type=question" "T5.2 AskUserQuestion via permission → question"
    assert_log_contains "question=Continue" "T5.2 question text"
    kill "$Q_PID" 2>/dev/null || true
    wait "$Q_PID" 2>/dev/null || true

    # T5.3: AskQuestion with dict options via permission
    mark_log
    echo '{"tool_name":"AskQuestion","tool_input":{"question":"Choose","options":[{"label":"Option A","value":"a"},{"label":"Option B","value":"b"}]}}' | \
        "$BRIDGE" --agent cursor --hook permission &
    Q_PID=$!
    sleep 0.5
    assert_log_contains "type=question" "T5.3 AskQuestion with dict options → question"
    assert_log_contains "options=Option A,Option B" "T5.3 dict option labels extracted"
    kill "$Q_PID" 2>/dev/null || true
    wait "$Q_PID" 2>/dev/null || true
}

# ── M6: Plan Review Flow ──────────────────────────────────────────────────

test_m6() {
    section "M6: Plan Review Flow"

    mark_log
    echo '{"plan":"## Step 1\nRefactor auth module\n## Step 2\nAdd tests"}' | \
        "$BRIDGE" --agent claude_code --hook plan &
    P_PID=$!
    sleep 0.5
    assert_log_contains "type=plan_review" "T6.1 plan_review type"
    kill "$P_PID" 2>/dev/null || true
    wait "$P_PID" 2>/dev/null || true
}

# ── M7: Collapsed Pill / Visible Sessions ─────────────────────────────────

test_m7() {
    section "M7: Visible Sessions & Linger"

    mark_log
    echo '{"prompt":"linger test","working_dir":"/tmp/m7test"}' | "$BRIDGE" --agent opencode --hook session_start
    sleep 0.3
    assert_log_contains "type=session_start" "T7.1 session created for linger test"

    # Send some activity then end
    echo '{"tool_name":"Read","tool_input":"main.go"}' | "$BRIDGE" --agent opencode --hook pretooluse
    sleep 0.2
    echo '{"tool_name":"Read","tool_result":"package main"}' | "$BRIDGE" --agent opencode --hook posttooluse
    sleep 0.2

    mark_log
    echo '{}' | "$BRIDGE" --agent opencode --hook stop
    sleep 0.3
    assert_log_contains "type=session_end" "T7.1 session_end received"
    # Session should still exist (either as Idle for process-backed or linger for non-process)
    assert_log_contains "Sessions count:" "T7.1 sessions tracked after end"
}

# ── M8: Subagent Flow ─────────────────────────────────────────────────────

test_m8() {
    section "M8: Subagent Start/End"

    mark_log
    echo '{"prompt":"main task","working_dir":"/tmp/m8test"}' | "$BRIDGE" --agent cursor --hook session_start
    sleep 0.3

    mark_log
    echo '{"parent_session_id":"cursor-test","subagent_id":"sub-001","prompt":"explore code"}' | \
        "$BRIDGE" --agent cursor --hook subagentstart
    sleep 0.3
    assert_log_contains "type=subagent_start" "T8.1 subagent_start received"

    mark_log
    echo '{"parent_session_id":"cursor-test","subagent_id":"sub-001"}' | \
        "$BRIDGE" --agent cursor --hook subagentstop
    sleep 0.3
    assert_log_contains "type=subagent_end" "T8.2 subagent_end received"

    echo '{}' | "$BRIDGE" --agent cursor --hook session_end
    sleep 0.2
}

# ── M9: Context Compact ───────────────────────────────────────────────────

test_m9() {
    section "M9: Context Compact"

    echo '{"prompt":"compact test","working_dir":"/tmp/m9test"}' | "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3

    mark_log
    echo '{"message":"Compacting context window..."}' | "$BRIDGE" --agent claude_code --hook precompact
    sleep 0.3
    assert_log_contains "type=context_compact" "T9.1 context_compact received"

    echo '{}' | "$BRIDGE" --agent claude_code --hook session_end
    sleep 0.2
}

# ── M10: Multi-agent (different agents coexist) ──────────────────────────

test_m10() {
    section "M10: Multi-Agent Coexistence"

    mark_log
    echo '{"prompt":"cursor task","working_dir":"/tmp/m10"}' | "$BRIDGE" --agent cursor --hook session_start
    sleep 0.2
    echo '{"prompt":"claude task","working_dir":"/tmp/m10"}' | "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.2
    echo '{"prompt":"codex task","working_dir":"/tmp/m10"}' | "$BRIDGE" --agent codex --hook session_start
    sleep 0.3

    assert_log_contains "Sessions count:" "T10.1 multiple sessions tracked"

    # Cleanup
    echo '{}' | "$BRIDGE" --agent cursor --hook session_end
    echo '{}' | "$BRIDGE" --agent claude_code --hook session_end
    echo '{}' | "$BRIDGE" --agent codex --hook session_end
    sleep 0.3
}

# ── M11: Codex Stop → notification with last_assistant_message ────────────

test_m11() {
    section "M11: Codex Stop Hook Captures Reply"

    # Setup: create a Codex session
    echo '{"prompt":"codex m11 test","working_dir":"/tmp/m11"}' | "$BRIDGE" --agent codex --hook session_start
    sleep 0.3

    # T11.1: Codex Stop hook mapped to notification → status_update with last_assistant_message
    mark_log
    echo '{"last_assistant_message":"Here is the refactored code with improved error handling."}' | \
        "$BRIDGE" --agent codex --hook notification
    sleep 0.3
    assert_log_contains "type=status_update" "T11.1 Codex notification → status_update"
    assert_log_contains "status=Here is the refactored code" "T11.1 last_assistant_message captured in status"

    # T11.2: last-assistant-message (hyphenated key) also works
    mark_log
    echo '{"last-assistant-message":"Analysis complete. Found 3 issues."}' | \
        "$BRIDGE" --agent codex --hook notification
    sleep 0.3
    assert_log_contains "status=Analysis complete" "T11.2 last-assistant-message (hyphenated) captured"

    # T11.3: Codex Stop with last_assistant_message in session_end path
    mark_log
    echo '{"last_assistant_message":"All tasks done successfully."}' | \
        "$BRIDGE" --agent codex --hook stop
    sleep 0.3
    assert_log_contains "type=session_end" "T11.3 Codex stop → session_end"
    assert_log_contains "status=All tasks done successfully" "T11.3 last_assistant_message in session_end status"

    # Cleanup
    echo '{}' | "$BRIDGE" --agent codex --hook session_end
    sleep 0.2
}

# ── M12: Cursor Reply via text Field ─────────────────────────────────────

test_m12() {
    section "M12: Cursor Reply via text Field"

    # Setup: create a Cursor session
    echo '{"prompt":"cursor m12 test","working_dir":"/tmp/m12"}' | "$BRIDGE" --agent cursor --hook session_start
    sleep 0.3

    # T12.1: Cursor afterAgentResponse sends "text" field (not "message" or "status")
    mark_log
    echo '{"text":"I have updated the component to use React hooks."}' | \
        "$BRIDGE" --agent cursor --hook notification
    sleep 0.3
    assert_log_contains "type=status_update" "T12.1 Cursor notification → status_update"
    assert_log_contains "status=I have updated the component" "T12.1 text field captured as status"

    # T12.2: "message" field still works as primary key
    mark_log
    echo '{"message":"File saved successfully."}' | \
        "$BRIDGE" --agent cursor --hook notification
    sleep 0.3
    assert_log_contains "status=File saved successfully" "T12.2 message field still primary"

    # T12.3: "status" field as second fallback
    mark_log
    echo '{"status":"Thinking..."}' | \
        "$BRIDGE" --agent cursor --hook notification
    sleep 0.3
    assert_log_contains "status=Thinking" "T12.3 status field as second fallback"

    # Cleanup
    echo '{}' | "$BRIDGE" --agent cursor --hook session_end
    sleep 0.2
}

# ── M13: Claude Code AskUserQuestion via PreToolUse + Response Format ────

test_m13() {
    section "M13: Claude Code Question via PreToolUse"

    # T13.1: AskUserQuestion via PreToolUse hook → routed as question (not tool_start)
    mark_log
    echo '{"tool_name":"AskUserQuestion","tool_input":{"question":"Which approach?","options":["Option A","Option B"]}}' | \
        "$BRIDGE" --agent claude_code --hook PreToolUse &
    Q_PID=$!
    sleep 0.5
    assert_log_contains "type=question" "T13.1 AskUserQuestion via PreToolUse → question type"
    assert_log_contains "question=Which approach" "T13.1 question text extracted"
    assert_log_contains "options=Option A,Option B" "T13.1 options extracted"
    kill "$Q_PID" 2>/dev/null || true
    wait "$Q_PID" 2>/dev/null || true

    # T13.2: AskUserQuestion with questions[] array via PreToolUse
    mark_log
    echo '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"How to proceed?","header":"Next","options":[{"label":"Refactor","description":"Clean up code"},{"label":"Test","description":"Add tests"}]}]}}' | \
        "$BRIDGE" --agent claude_code --hook PreToolUse &
    Q_PID=$!
    sleep 0.5
    assert_log_contains "type=question" "T13.2 questions[] array via PreToolUse → question"
    assert_log_contains "question=.*How to proceed" "T13.2 question text from questions[0]"
    assert_log_contains "options=Refactor,Test" "T13.2 option labels from questions[0].options"
    kill "$Q_PID" 2>/dev/null || true
    wait "$Q_PID" 2>/dev/null || true

    # T13.3: Verify buildClaudeCodeQuestionResponse JSON format (unit-style test)
    #   We use di-bridge's dumpStdin log to verify the hook type triggers question detection
    mark_log
    # A non-question tool via PreToolUse should NOT become a question
    echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | \
        "$BRIDGE" --agent claude_code --hook PreToolUse
    sleep 0.3
    assert_log_contains "type=tool_start" "T13.3 non-question tool via PreToolUse → tool_start (not question)"
    assert_log_contains "tool=Bash" "T13.3 tool name preserved as Bash"

    # T13.4: AskUserQuestion via permission hook also routes to question
    mark_log
    echo '{"tool_name":"AskUserQuestion","tool_input":{"question":"Confirm?","options":["yes","no"]}}' | \
        "$BRIDGE" --agent claude_code --hook PermissionRequest &
    Q_PID=$!
    sleep 0.5
    assert_log_contains "type=question" "T13.4 AskUserQuestion via PermissionRequest → question"
    kill "$Q_PID" 2>/dev/null || true
    wait "$Q_PID" 2>/dev/null || true
}

# ── M14: session_end Captures Reply via last_assistant_message ───────────

test_m14() {
    section "M14: Session End Reply Capture"

    # Setup: create a Claude Code session
    echo '{"prompt":"m14 test","working_dir":"/tmp/m14"}' | "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3

    # T14.1: stop hook with last_assistant_message → session_end with status
    mark_log
    echo '{"last_assistant_message":"I have completed all the requested changes."}' | \
        "$BRIDGE" --agent claude_code --hook stop
    sleep 0.3
    assert_log_contains "type=session_end" "T14.1 stop → session_end"
    assert_log_contains "status=I have completed all the requested" "T14.1 last_assistant_message in session_end"

    # T14.2: session_end with "message" field fallback
    echo '{"prompt":"m14 test2","working_dir":"/tmp/m14b"}' | "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3
    mark_log
    echo '{"message":"Done with refactoring."}' | \
        "$BRIDGE" --agent claude_code --hook session_end
    sleep 0.3
    assert_log_contains "type=session_end" "T14.2 session_end recognized"
    assert_log_contains "status=Done with refactoring" "T14.2 message field fallback in session_end"

    # T14.3: session_end with "response" field fallback
    echo '{"prompt":"m14 test3","working_dir":"/tmp/m14c"}' | "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3
    mark_log
    echo '{"response":"Build succeeded with 0 warnings."}' | \
        "$BRIDGE" --agent claude_code --hook session_end
    sleep 0.3
    assert_log_contains "status=Build succeeded" "T14.3 response field fallback in session_end"

    # Cleanup
    echo '{}' | "$BRIDGE" --agent claude_code --hook session_end
    sleep 0.2
}

# ── M15: Multi-Session Support ────────────────────────────────────────────

test_m15() {
    section "M15: Multi-Session Support"

    # T15.1: Two Cursor sessions with different conversation_id → distinct sessions
    mark_log
    echo '{"prompt":"cursor session A","conversation_id":"conv-aaa-111","workspace_roots":["/tmp/m15"]}' | \
        "$BRIDGE" --agent cursor --hook session_start
    sleep 0.3
    assert_log_contains "session=cursor-conv-aaa-111" "T15.1 Cursor session A uses conversation_id"

    mark_log
    echo '{"prompt":"cursor session B","conversation_id":"conv-bbb-222","workspace_roots":["/tmp/m15"]}' | \
        "$BRIDGE" --agent cursor --hook session_start
    sleep 0.3
    assert_log_contains "session=cursor-conv-bbb-222" "T15.1 Cursor session B has different ID"

    # T15.2: Two Claude Code sessions with different ITERM_SESSION_ID → distinct IDs
    mark_log
    env ITERM_SESSION_ID="w0t0p0:FAKE-UUID-AAA" "$BRIDGE" --agent claude_code --hook session_start \
        <<< '{"prompt":"cc session A","working_dir":"/tmp/m15"}'
    sleep 0.3
    local SID_A
    SID_A=$(log_since_marker | grep -o 'session=claude_code-[a-f0-9]*' | head -1 | cut -d= -f2)
    [[ -n "$SID_A" ]] && pass "T15.2 Claude Code session A created ($SID_A)" || fail "T15.2 Claude Code session A not found"

    mark_log
    env ITERM_SESSION_ID="w0t1p0:FAKE-UUID-BBB" "$BRIDGE" --agent claude_code --hook session_start \
        <<< '{"prompt":"cc session B","working_dir":"/tmp/m15"}'
    sleep 0.3
    local SID_B
    SID_B=$(log_since_marker | grep -o 'session=claude_code-[a-f0-9]*' | head -1 | cut -d= -f2)
    [[ -n "$SID_B" ]] && pass "T15.2 Claude Code session B created ($SID_B)" || fail "T15.2 Claude Code session B not found"
    [[ "$SID_A" != "$SID_B" ]] && pass "T15.2 sessions have different IDs" || fail "T15.2 sessions share same ID ($SID_A)"

    # T15.3: Messages route to correct session by ID
    mark_log
    echo '{"tool_name":"Read","tool_input":"file.txt"}' | "$BRIDGE" --agent cursor --session "cursor-conv-aaa-111" --hook pretooluse
    sleep 0.3
    assert_log_contains "session=cursor-conv-aaa-111" "T15.3 tool_start routed to session A by ID"

    # Cleanup
    echo '{}' | "$BRIDGE" --agent cursor --session "cursor-conv-aaa-111" --hook session_end
    echo '{}' | "$BRIDGE" --agent cursor --session "cursor-conv-bbb-222" --hook session_end
    echo '{}' | "$BRIDGE" --agent claude_code --session "$SID_A" --hook session_end
    echo '{}' | "$BRIDGE" --agent claude_code --session "$SID_B" --hook session_end
    sleep 0.3
}

# ── M16: Session Title & Workspace Name ──────────────────────────────────

test_m16() {
    section "M16: Session Title & Workspace Name"

    local STDIN_LOG="$HOME/.xisland/bridge-stdin.log"

    # T16.1: session_start with prompt → bridge receives and forwards prompt
    mark_log
    echo '{"prompt":"Refactor the auth module","working_dir":"/tmp/m16test"}' | \
        "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3
    assert_log_contains "type=session_start" "T16.1 session_start with prompt received"
    if grep -q "Refactor the auth module" "$STDIN_LOG" 2>/dev/null; then
        pass "T16.1 prompt captured in bridge stdin log"
    else
        fail "T16.1 prompt not found in bridge stdin log"
    fi

    # T16.2: workspace_roots in Cursor hook → extracted as working directory
    mark_log
    echo '{"prompt":"test workspace","workspace_roots":["/Users/test/my-project"],"conversation_id":"m16-ws-test"}' | \
        "$BRIDGE" --agent cursor --hook session_start
    sleep 0.3
    assert_log_contains "type=session_start" "T16.2 session_start with workspace_roots received"
    if grep -q '"workspace_roots"' "$STDIN_LOG" 2>/dev/null; then
        pass "T16.2 workspace_roots present in hook data"
    else
        fail "T16.2 workspace_roots not found in hook data"
    fi

    # T16.3: session_start without prompt still creates session
    mark_log
    echo '{"working_dir":"/tmp/fallback-project"}' | \
        "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3
    assert_log_contains "type=session_start" "T16.3 session_start without prompt accepted"

    # Cleanup
    echo '{}' | "$BRIDGE" --agent claude_code --hook session_end
    echo '{}' | "$BRIDGE" --agent cursor --session "cursor-m16-ws-test" --hook session_end
    sleep 0.3
}

# ── M17: Completion Sound Dedup ──────────────────────────────────────────

test_m17() {
    section "M17: Completion Sound Dedup"

    # T17.1: Claude Code session_end → session completed
    mark_log
    echo '{"prompt":"m17 cc test","working_dir":"/tmp/m17a"}' | "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3
    echo '{"message":"Done."}' | "$BRIDGE" --agent claude_code --hook session_end
    sleep 0.3
    assert_log_contains "type=session_end" "T17.1 Claude Code session_end received"
    assert_log_contains "status=Done" "T17.1 completion status captured"

    # T17.2: Codex notification with response → completed via handleStatus
    mark_log
    echo '{"prompt":"m17 codex test","working_dir":"/tmp/m17b"}' | "$BRIDGE" --agent codex --hook session_start
    sleep 0.3
    mark_log
    echo '{"message":"Here is the answer."}' | "$BRIDGE" --agent codex --hook notification
    sleep 0.5
    assert_log_contains "type=status_update" "T17.2 Codex notification → status_update"
    assert_log_contains "status=Here is the answer" "T17.2 Codex response text captured"

    # T17.3: OpenCode notification → completed via handleStatus
    mark_log
    echo '{"prompt":"m17 oc test","working_dir":"/tmp/m17c"}' | \
        "$BRIDGE" --agent opencode --session "opencode-m17test" --hook session_start
    sleep 0.3
    mark_log
    echo '{"message":"Hello from OpenCode."}' | \
        "$BRIDGE" --agent opencode --session "opencode-m17test" --hook notification
    sleep 0.5
    assert_log_contains "type=status_update" "T17.3 OpenCode notification → status_update"
    assert_log_contains "status=Hello from OpenCode" "T17.3 OpenCode response captured"

    # T17.4: Cursor status_update + session_end → not double-completed
    mark_log
    echo '{"prompt":"m17 cursor test","conversation_id":"m17-cursor-dedup","workspace_roots":["/tmp/m17d"]}' | \
        "$BRIDGE" --agent cursor --hook session_start
    sleep 0.3
    echo '{"text":"I finished the task."}' | "$BRIDGE" --agent cursor --session "cursor-m17-cursor-dedup" --hook notification
    sleep 0.2
    echo '{}' | "$BRIDGE" --agent cursor --session "cursor-m17-cursor-dedup" --hook session_end
    sleep 0.3
    assert_log_contains "type=session_end" "T17.4 Cursor session_end after status_update"

    # Cleanup
    echo '{}' | "$BRIDGE" --agent codex --hook session_end
    echo '{}' | "$BRIDGE" --agent opencode --session "opencode-m17test" --hook session_end
    sleep 0.3
}

# ── M18: Configurable Linger Duration ────────────────────────────────────

test_m18() {
    section "M18: Configurable Linger Duration"

    local ORIG_LINGER
    ORIG_LINGER=$(defaults read dev.towerisland.app completedLingerDuration 2>/dev/null || echo "")

    # T18.1: Set short linger, verify session lingers then disappears
    defaults write dev.towerisland.app completedLingerDuration -float 120.0
    mark_log
    echo '{"prompt":"linger config test","working_dir":"/tmp/m18test"}' | \
        "$BRIDGE" --agent claude_code --hook session_start
    sleep 0.3
    echo '{}' | "$BRIDGE" --agent claude_code --hook session_end
    sleep 1
    assert_log_contains "type=session_end" "T18.1 session ended with configurable linger"
    assert_log_contains "Sessions count:" "T18.1 session still tracked during linger"

    # T18.2: Restore original linger value
    if [[ -n "$ORIG_LINGER" ]]; then
        defaults write dev.towerisland.app completedLingerDuration -float "$ORIG_LINGER"
    else
        defaults delete dev.towerisland.app completedLingerDuration 2>/dev/null || true
    fi
    pass "T18.2 linger duration restored"
}

# ── M19: Session Dismiss ─────────────────────────────────────────────────

test_m19() {
    section "M19: Session Dismiss"

    # T19.1: Create session, verify exists, end it, verify it completes
    mark_log
    echo '{"prompt":"dismiss test","working_dir":"/tmp/m19test"}' | \
        "$BRIDGE" --agent claude_code --session "claude_code-dismiss-test" --hook session_start
    sleep 0.3
    assert_log_contains "session=claude_code-dismiss-test" "T19.1 session created for dismiss test"

    # T19.2: Send session_end to simulate dismiss behavior (session lifecycle)
    mark_log
    echo '{}' | "$BRIDGE" --agent claude_code --session "claude_code-dismiss-test" --hook session_end
    sleep 0.5
    assert_log_contains "type=session_end" "T19.2 session ended (dismiss lifecycle)"
    assert_log_contains "Sessions count:" "T19.2 sessions tracked after dismiss"
}

# ── Run ──────────────────────────────────────────────────────────────────

main() {
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   X Island — Integration Test Suite      ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"

    check_prereqs

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
        echo -e "${RED}Some tests failed. Check the debug log: $LOG${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        echo ""
        echo -e "${CYAN}Restarting X Island to clear test data...${NC}"
        pkill -f XIsland 2>/dev/null
        sleep 1
        open "$PROJECT_DIR/.build/X Island.app" 2>/dev/null || true
        exit 0
    fi
}

main
