#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_SCRIPT="$PROJECT_DIR/Scripts/build.sh"
APP_BUNDLE="$PROJECT_DIR/.build/X Island.app"
UI_DRIVER="$PROJECT_DIR/.build/release/XIslandUITestDriver"
MODE="${1:-smoke}"
ANIMATION_PROFILE="${X_ISLAND_TEST_ANIMATION_PROFILE:-deterministic}"
TEST_BIN_DIR="$PROJECT_DIR/.build/ui-test-bin"

case "$ANIMATION_PROFILE" in
    deterministic|normal) ;;
    *)
        echo "ERROR: X_ISLAND_TEST_ANIMATION_PROFILE must be deterministic or normal"
        exit 1
        ;;
esac

cd "$PROJECT_DIR"

mkdir -p "$TEST_BIN_DIR"

env \
    X_ISLAND_BIN_DIR="$TEST_BIN_DIR" \
    X_ISLAND_SKIP_BRIDGE_INSTALL=1 \
    X_ISLAND_SKIP_PATH_CONFIGURE=1 \
    bash "$BUILD_SCRIPT"

if [[ ! -x "$UI_DRIVER" ]]; then
    echo "ERROR: UI driver binary not found at $UI_DRIVER"
    exit 1
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: App bundle not found at $APP_BUNDLE"
    exit 1
fi

case "$MODE" in
    smoke|full)
        ;;
    permission-smoke|question-smoke|plan-smoke|preferences-update|session-list)
        ;;
    *)
        echo "ERROR: unsupported UI mode '$MODE'"
        echo "Usage: bash Scripts/test-ui.sh [smoke|full|permission-smoke|question-smoke|plan-smoke|preferences-update|session-list]"
        exit 1
        ;;
esac

X_ISLAND_TEST_ANIMATION_PROFILE="$ANIMATION_PROFILE" "$UI_DRIVER" --app-path "$APP_BUNDLE" "$MODE"
