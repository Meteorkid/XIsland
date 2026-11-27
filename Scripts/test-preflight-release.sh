#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/xisland-preflight.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/Casks" "$FIXTURE/docs/releases" "$FIXTURE/.build"

SHA="7dcdd9b8c703bebc0e041d6ec9b143900259dae3ac19bb0f2220d539196fb7ce"
MISMATCH_SHA="0000000000000000000000000000000000000000000000000000000000000000"

write_cask() {
    printf 'cask "x-island" do\n  version "9.9.9"\n  sha256 "%s"\nend\n' "$SHA" > "$FIXTURE/Casks/x-island.rb"
}

write_version() {
    printf '9.9.9\n' > "$FIXTURE/VERSION"
}

write_release() {
    printf '## English summary\n\n## Integration changes\n\n## macOS Gatekeeper\n\nXIsland-9.9.9.dmg SHA256: %s\n' "$SHA" > "$FIXTURE/docs/releases/9.9.9.md"
}

write_sums() {
    printf '%s  XIsland-9.9.9.dmg\n' "$SHA" > "$FIXTURE/.build/SHA256SUMS.txt"
}

run_preflight() {
    XISLAND_RELEASE_ROOT="$FIXTURE" bash "$ROOT/Scripts/preflight-release.sh" "$@" > "$FIXTURE/out" 2>&1
}

expect_pass() {
    local label="$1"
    if ! run_preflight; then
        echo "FAIL: $label unexpectedly failed"
        cat "$FIXTURE/out"
        exit 1
    fi
}

expect_failure() {
    local label="$1"
    shift
    if run_preflight "$@"; then
        echo "FAIL: $label unexpectedly passed"
        cat "$FIXTURE/out"
        exit 1
    fi
}

expect_output() {
    local label="$1" text="$2"
    if ! grep -Fq "$text" "$FIXTURE/out"; then
        echo "FAIL: $label did not report: $text"
        cat "$FIXTURE/out"
        exit 1
    fi
}

write_version
write_cask
write_release
write_sums
expect_pass "baseline"

sed 's/version "9.9.9"/version "2.3.1"/' "$FIXTURE/Casks/x-island.rb" > "$FIXTURE/Casks/x-island.rb.tmp"
mv "$FIXTURE/Casks/x-island.rb.tmp" "$FIXTURE/Casks/x-island.rb"
expect_failure "version mismatch"
expect_output "version mismatch" "Cask version"
write_cask

expect_failure "missing required DMG" --require-dmg
expect_output "missing required DMG" "missing DMG"

sed "s/$SHA/$MISMATCH_SHA/" "$FIXTURE/Casks/x-island.rb" > "$FIXTURE/Casks/x-island.rb.tmp"
mv "$FIXTURE/Casks/x-island.rb.tmp" "$FIXTURE/Casks/x-island.rb"
expect_failure "Cask checksum drift"
expect_output "Cask checksum drift" "Cask sha256 does not match SHA256SUMS.txt"
write_cask

sed "s/$SHA/$MISMATCH_SHA/" "$FIXTURE/docs/releases/9.9.9.md" > "$FIXTURE/docs/releases/9.9.9.md.tmp"
mv "$FIXTURE/docs/releases/9.9.9.md.tmp" "$FIXTURE/docs/releases/9.9.9.md"
expect_failure "release-note checksum drift"
expect_output "release-note checksum drift" "release-note checksum does not match SHA256SUMS.txt"
write_release

sed "s/$SHA/$MISMATCH_SHA/" "$FIXTURE/.build/SHA256SUMS.txt" > "$FIXTURE/.build/SHA256SUMS.txt.tmp"
mv "$FIXTURE/.build/SHA256SUMS.txt.tmp" "$FIXTURE/.build/SHA256SUMS.txt"
expect_failure "SHA256SUMS checksum drift"
expect_output "SHA256SUMS checksum drift" "Cask sha256 does not match SHA256SUMS.txt"
write_sums

echo "preflight-release tests passed: baseline, version mismatch, missing DMG, Cask/release-note/SHA256SUMS checksum drift all checked."
