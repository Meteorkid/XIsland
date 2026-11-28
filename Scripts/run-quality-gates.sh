#!/bin/bash
set -euo pipefail

# Run every non-destructive X Island quality gate in one fail-fast entry point.
#
# Usage:
#   bash Scripts/run-quality-gates.sh [--build]
#
#   --build  Also run the release Swift build through preflight-release.sh.
#
# XISLAND_QUALITY_ROOT may point at a fixture checkout for negative-path tests.
# An unset environment variable uses this checkout.

ROOT="${XISLAND_QUALITY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BUILD=0

for arg in "$@"; do
    case "$arg" in
        --build) BUILD=1 ;;
        --help|-h)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# / /'
            exit 0
            ;;
        *)
            echo "run-quality-gates: unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$ROOT" ]]; then
    echo "run-quality-gates: root is not a directory: $ROOT" >&2
    exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"

run_gate() {
    local label="$1"
    shift
    printf '\n==> %s\n' "$label"
    if ! "$@"; then
        echo "Quality gates failed: $label" >&2
        exit 1
    fi
}

run_gate "Documentation checks" \
    python3 "$ROOT/Scripts/check-docs.py" --root "$ROOT"
run_gate "Documentation failure paths" \
    python3 "$ROOT/Scripts/test-check-docs.py"
run_gate "Swift runtime safety" \
    python3 "$ROOT/Scripts/check-swift-safety.py" --root "$ROOT"
run_gate "Swift runtime safety failure paths" \
    python3 "$ROOT/Scripts/test-check-swift-safety.py"
run_gate "Engineering loop state" \
    python3 "$ROOT/Scripts/check-loop-state.py" --state "$ROOT/docs/engineering-loop/STATE.md"
run_gate "Engineering loop state failure paths" \
    python3 "$ROOT/Scripts/test-check-loop-state.py"

if (( BUILD )); then
    run_gate "Release preflight (metadata + build)" \
        env XISLAND_RELEASE_ROOT="$ROOT" bash "$ROOT/Scripts/preflight-release.sh" --build
else
    run_gate "Release preflight" \
        env XISLAND_RELEASE_ROOT="$ROOT" bash "$ROOT/Scripts/preflight-release.sh"
fi
run_gate "Release preflight failure paths" \
    env XISLAND_RELEASE_ROOT="$ROOT" bash "$ROOT/Scripts/test-preflight-release.sh"

echo
echo "Quality gates passed."
