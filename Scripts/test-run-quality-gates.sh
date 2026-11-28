#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/Scripts/run-quality-gates.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/xisland-quality-gates.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

SHA="0000000000000000000000000000000000000000000000000000000000000000"
MISMATCH_SHA="1111111111111111111111111111111111111111111111111111111111111111"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_output() {
    local label="$1" file="$2" text="$3"
    if ! grep -Fq "$text" "$file"; then
        echo "FAIL: $label did not report: $text" >&2
        cat "$file" >&2
        exit 1
    fi
}

[[ -f "$GATE" ]] || fail "run-quality-gates.sh is missing"
bash -n "$GATE" || fail "run-quality-gates.sh has a syntax error"
"$GATE" > "$FIXTURE/real.out" 2>&1 || {
    cat "$FIXTURE/real.out" >&2
    fail "no-build run against repository should pass"
}
require_output "no-build run" "$FIXTURE/real.out" "Quality gates passed."

mkdir -p "$FIXTURE/repo/Casks" "$FIXTURE/repo/docs/releases" \
    "$FIXTURE/repo/docs/compatibility" "$FIXTURE/repo/docs/engineering-loop" \
    "$FIXTURE/repo/Sources" "$FIXTURE/repo/.build"
ln -s "$ROOT/Scripts" "$FIXTURE/repo/Scripts"

printf '9.9.9\n' > "$FIXTURE/repo/VERSION"
printf 'cask "x-island" do\n  version "9.9.9"\n  sha256 "%s"\nend\n' "$SHA" > "$FIXTURE/repo/Casks/x-island.rb"
printf '## English summary\n\n## Integration changes\n\n## macOS Gatekeeper\n\nXIsland-9.9.9.dmg SHA256: %s\n' "$SHA" > "$FIXTURE/repo/docs/releases/9.9.9.md"
printf '%s  XIsland-9.9.9.dmg\n' "$SHA" > "$FIXTURE/repo/.build/SHA256SUMS.txt"
printf '# Fixture\n\n[release note](docs/releases/9.9.9.md)\n' > "$FIXTURE/repo/README.md"
printf 'let value = try? risky()\n' > "$FIXTURE/repo/Sources/Clean.swift"
printf '# Engineering Loop State\n\n' > "$FIXTURE/repo/docs/engineering-loop/STATE.md"
for field in \
    '- cycle: 1' \
    '- cycle_start_iteration: 1' \
    '- cycle_end_iteration: 8' \
    '- planned_iterations: 8' \
    '- completed_iterations: 8' \
    '- next_iteration: 9' \
    '- status: complete' \
    '- branch: fixture' \
    '- last_iteration: 8' \
    '- last_task: fixture' \
    '- last_check: fixture' \
    '- next_task: fixture'; do
    printf '%s\n' "$field" >> "$FIXTURE/repo/docs/engineering-loop/STATE.md"
done
{
    printf '# Central prompts\n\n'
    for _ in {1..15}; do printf '```text\nfixture prompt\n```\n\n'; done
} > "$FIXTURE/repo/docs/compatibility/llm-setup-prompts.md"
{
    printf '# More prompts\n\n'
    for _ in {1..15}; do printf '```text\nfixture prompt\n```\n\n'; done
} > "$FIXTURE/repo/docs/more-prompts.md"

XISLAND_QUALITY_ROOT="$FIXTURE/repo" "$GATE" > "$FIXTURE/fixture.out" 2>&1 || {
    cat "$FIXTURE/fixture.out" >&2
    fail "complete fixture should pass all quality gates"
}
require_output "complete fixture" "$FIXTURE/fixture.out" "Quality gates passed."

sed "s/$SHA/$MISMATCH_SHA/" "$FIXTURE/repo/Casks/x-island.rb" > "$FIXTURE/repo/Casks/x-island.rb.tmp"
mv "$FIXTURE/repo/Casks/x-island.rb.tmp" "$FIXTURE/repo/Casks/x-island.rb"
set +e
XISLAND_QUALITY_ROOT="$FIXTURE/repo" "$GATE" > "$FIXTURE/failure.out" 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail "late release-preflight failure should exit nonzero"
require_output "late failure" "$FIXTURE/failure.out" "Quality gates failed: Release preflight"

echo "run-quality-gates tests passed: syntax, repository no-build run, complete fixture, late preflight failure propagation."
