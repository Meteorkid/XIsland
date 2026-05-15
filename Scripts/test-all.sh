#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SOCK="$HOME/.xisland/di.sock"
APP_BUNDLE="$PROJECT_DIR/.build/X Island.app"
SYSTEM_APP_BUNDLE="/Applications/X Island.app"

cd "$PROJECT_DIR"

resolve_app_bundle() {
    if [[ -d "$APP_BUNDLE" ]]; then
        printf '%s\n' "$APP_BUNDLE"
        return 0
    fi
    if [[ -d "$SYSTEM_APP_BUNDLE" ]]; then
        printf '%s\n' "$SYSTEM_APP_BUNDLE"
        return 0
    fi
    return 1
}

restart_xisland() {
    local app_to_open
    if ! app_to_open="$(resolve_app_bundle)"; then
        echo "ERROR: X Island socket not found at $SOCK"
        echo "Please launch X Island first, then rerun: bash Scripts/test-all.sh"
        exit 1
    fi

    echo "==> Restarting X Island for integration tests..."
    pkill -f "XIsland" 2>/dev/null || true
    rm -f "$SOCK"
    open "$app_to_open"

    for _ in {1..50}; do
        if [[ -S "$SOCK" ]]; then
            return 0
        fi
        sleep 0.2
    done

    echo "ERROR: X Island socket not found at $SOCK after launching $app_to_open"
    exit 1
}

echo "==> [1/2] Running Swift unit tests..."
swift test

echo "==> [2/2] Running integration tests..."
restart_xisland

bash Scripts/test.sh

echo ""
echo "All automated tests passed."
