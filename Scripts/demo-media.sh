#!/usr/bin/env bash
# Seed X Island with deterministic sessions for README / Assets screenshots & screen recording.
#
# Prerequisites:
#   1. bash Scripts/build.sh   (installs di-bridge to ~/.xisland/bin/)
#   2. Launch X Island.app (socket must exist at ~/.xisland/di.sock)
#
# Usage:
#   bash Scripts/demo-media.sh seed       # three active sessions (collapsed + expanded shots)
#   bash Scripts/demo-media.sh question   # interactive question UI (blocks until you answer in the island)
#   bash Scripts/demo-media.sh cleanup    # end demo sessions (optional reset)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${BRIDGE:-$HOME/.xisland/bin/di-bridge}"
SOCK="$HOME/.xisland/di.sock"

DEMO_SESSIONS=(
  "readme-demo-claude:claude_code"
  "readme-demo-cursor:cursor"
  "readme-demo-codex:codex"
)

check_bridge() {
  if [[ ! -x "$BRIDGE" ]]; then
    echo "error: di-bridge not found at $BRIDGE"
    echo "  Run: bash Scripts/build.sh"
    exit 1
  fi
}

check_socket() {
  if [[ ! -S "$SOCK" ]]; then
    echo "error: socket not found at $SOCK"
    echo "  Launch X Island.app, then retry."
    exit 1
  fi
}

cmd_seed() {
  check_bridge
  check_socket
  echo "==> Seeding demo sessions (IDs: readme-demo-*)..."
  echo '{"prompt":"Refactor authentication and session cookies","working_dir":"/Users/demo/Projects/acme"}' \
    | "$BRIDGE" --agent claude_code --session "readme-demo-claude" --hook session_start
  sleep 0.25
  echo '{"prompt":"Fix TypeScript errors in the API package","working_dir":"/Users/demo/Projects/acme/packages/api"}' \
    | "$BRIDGE" --agent cursor --session "readme-demo-cursor" --hook session_start
  sleep 0.25
  echo '{"prompt":"Add unit tests for the markdown parser","working_dir":"/Users/demo/Projects/acme"}' \
    | "$BRIDGE" --agent codex --session "readme-demo-codex" --hook session_start
  echo ""
  echo "Done. You should see 3 active sessions."
  echo "  • Collapsed capture: top-center island (notch Mac: compact left icon + count; external: centered icons)."
  echo "  • Expanded: hover the island, capture Assets/screenshots/expanded.png"
  echo "  • See docs/DEMO_MEDIA.md for full checklist."
}

cmd_question() {
  check_bridge
  check_socket
  echo "==> Ensuring readme-demo-claude exists..."
  echo '{"prompt":"Demo session for question screenshot","working_dir":"/Users/demo/Projects/acme"}' \
    | "$BRIDGE" --agent claude_code --session "readme-demo-claude" --hook session_start
  sleep 0.2
  echo ""
  echo "==> Sending AskUserQuestion (bridge will wait until you answer in X Island)..."
  echo "    Capture Assets/screenshots/question.png while this prompt is visible, then pick an option."
  echo ""
  echo '{"tool_name":"AskUserQuestion","tool_input":{"question":"Which approach should we take next?","options":["Incremental refactor","Rewrite module","Defer to next sprint"]}}' \
    | "$BRIDGE" --agent claude_code --session "readme-demo-claude" --hook permission
}

cmd_cleanup() {
  check_bridge
  check_socket
  echo "==> Ending demo sessions..."
  for entry in "${DEMO_SESSIONS[@]}"; do
    IFS=: read -r sid agent <<<"$entry"
    echo '{}' | "$BRIDGE" --agent "$agent" --session "$sid" --hook session_end || true
    sleep 0.15
  done
  echo "Done."
}

usage() {
  echo "Usage: bash Scripts/demo-media.sh <seed|question|cleanup>"
}

case "${1:-}" in
  seed) cmd_seed ;;
  question) cmd_question ;;
  cleanup) cmd_cleanup ;;
  *) usage; exit 1 ;;
esac
