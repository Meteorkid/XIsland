#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/xisland-preflight.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/Casks" "$FIXTURE/docs/releases" "$FIXTURE/.build"
printf '9.9.9\n' > "$FIXTURE/VERSION"
printf 'cask "x-island" do\n  version "2.3.1"\n  sha256 "7dcdd9b8c703bebc0e041d6ec9b143900259dae3ac19bb0f2220d539196fb7ce"\nend\n' > "$FIXTURE/Casks/x-island.rb"
printf '## English summary\n\n## Integration changes\n\n## macOS Gatekeeper\n\nXIsland-9.9.9.dmg SHA256: 7dcdd9b8c703bebc0e041d6ec9b143900259dae3ac19bb0f2220d539196fb7ce\n' > "$FIXTURE/docs/releases/9.9.9.md"
printf '7dcdd9b8c703bebc0e041d6ec9b143900259dae3ac19bb0f2220d539196fb7ce  XIsland-9.9.9.dmg\n' > "$FIXTURE/.build/SHA256SUMS.txt"

run_and_expect_failure() {
    local label="$1"
    shift
    if XISLAND_RELEASE_ROOT="$FIXTURE" bash "$ROOT/Scripts/preflight-release.sh" "$@" > "$FIXTURE/out" 2>&1; then
        echo "FAIL: $label unexpectedly passed"
        cat "$FIXTURE/out"
        exit 1
    fi
}

run_and_expect_failure "version mismatch" 
grep -Fq "Cask version" "$FIXTURE/out"

run_and_expect_failure "missing required DMG" --require-dmg
grep -Fq "missing DMG" "$FIXTURE/out"

echo "preflight-release tests passed: version mismatch and missing DMG both rejected."
