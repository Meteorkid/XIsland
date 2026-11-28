#!/bin/bash
set -euo pipefail

# X Island release preflight: read-only metadata checks by default.
# It never publishes, tags, pushes, or edits repository files.
#
# Usage:
#   bash Scripts/preflight-release.sh [--build] [--require-dmg]
#
#   --build        Also run a release Swift build (writes only .build).
#   --require-dmg  Require .build/XIsland-<VERSION>.dmg and verify its SHA256.

ROOT="${XISLAND_RELEASE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
VERSION_FILE="$ROOT/VERSION"
CASK_FILE="$ROOT/Casks/x-island.rb"
SUMS_FILE="$ROOT/.build/SHA256SUMS.txt"

BUILD=0
REQUIRE_DMG=0
for arg in "$@"; do
    case "$arg" in
        --build) BUILD=1 ;;
        --require-dmg) REQUIRE_DMG=1 ;;
        --help|-h)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# / /'
            exit 0
            ;;
        *)
            echo "preflight-release: unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

errors=0
fail() {
    echo "  FAIL: $*" >&2
    errors=$((errors + 1))
}

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "preflight-release: missing VERSION file at $VERSION_FILE" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ -z "$VERSION" ]]; then
    echo "preflight-release: VERSION is empty" >&2
    exit 1
fi
RELEASE_NOTES="$ROOT/docs/releases/${VERSION}.md"
DMG="$ROOT/.build/XIsland-${VERSION}.dmg"
MANIFEST="$ROOT/.build/XIsland-${VERSION}.manifest.json"
SIGNATURE="$ROOT/.build/XIsland-${VERSION}.manifest.sig"
PUBLIC_KEY_FILE="$ROOT/Config/UpdateSigningPublicKey.txt"
KEY_ID_FILE="$ROOT/Config/UpdateSigningKeyID.txt"

MODE="metadata"
if (( BUILD )); then MODE="$MODE + build"; fi
if (( REQUIRE_DMG )); then MODE="$MODE + require-dmg"; fi

echo "X Island release preflight"
echo "  root:    $ROOT"
echo "  version: $VERSION"
echo "  mode:    $MODE"

if [[ ! -f "$CASK_FILE" ]]; then
    fail "missing Cask file: $CASK_FILE"
else
    CASK_VERSION="$(sed -n 's/^[[:space:]]*version[[:space:]]*"\([^"]*\)".*/\1/p' "$CASK_FILE" | head -n 1)"
    CASK_SHA="$(sed -n 's/^[[:space:]]*sha256[[:space:]]*"\([^"]*\)".*/\1/p' "$CASK_FILE" | head -n 1)"
    if [[ "$CASK_VERSION" != "$VERSION" ]]; then
        fail "Cask version '$CASK_VERSION' does not match VERSION '$VERSION'"
    fi
    if [[ ! "$CASK_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
        fail "Cask sha256 is not a 64-character hex digest"
    fi
fi

if [[ ! -f "$RELEASE_NOTES" ]]; then
    fail "missing release notes: $RELEASE_NOTES"
else
    for section in "## English summary" "## Integration changes" "## macOS Gatekeeper"; do
        if ! grep -Fqx "$section" "$RELEASE_NOTES"; then
            fail "release notes missing required section: $section"
        fi
    done
    if grep -Fq "<pending>" "$RELEASE_NOTES"; then
        fail "release notes still contain an unresolved <pending> placeholder"
    fi
    RELEASE_SHA="$(awk -v name="XIsland-${VERSION}.dmg" '$1 == name && $2 == "SHA256:" && $3 ~ /^[0-9a-fA-F]{64}$/ { print $3; exit }' "$RELEASE_NOTES")"
    if [[ -z "$RELEASE_SHA" ]]; then
        fail "release notes do not contain the XIsland-${VERSION}.dmg SHA256 line"
    fi
fi

SUMS_SHA=""
if [[ -f "$SUMS_FILE" ]]; then
    SUMS_SHA="$(awk -v name="XIsland-${VERSION}.dmg" '$2 == name && $1 ~ /^[0-9a-fA-F]{64}$/ { print $1; exit }' "$SUMS_FILE")"
    if [[ -z "$SUMS_SHA" ]]; then
        fail "SHA256SUMS.txt has no valid entry for XIsland-${VERSION}.dmg"
    fi
fi

if [[ -n "${CASK_SHA:-}" && -n "${RELEASE_SHA:-}" && "$CASK_SHA" != "$RELEASE_SHA" ]]; then
    fail "Cask sha256 does not match the release-note checksum"
fi
if [[ -n "${RELEASE_SHA:-}" && -n "$SUMS_SHA" && "$RELEASE_SHA" != "$SUMS_SHA" ]]; then
    fail "release-note checksum does not match SHA256SUMS.txt"
fi
if [[ -n "${CASK_SHA:-}" && -n "$SUMS_SHA" && "$CASK_SHA" != "$SUMS_SHA" ]]; then
    fail "Cask sha256 does not match SHA256SUMS.txt"
fi

if [[ -f "$DMG" ]]; then
    ACTUAL_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
    if [[ -n "${RELEASE_SHA:-}" && "$ACTUAL_SHA" != "$RELEASE_SHA" ]]; then
        fail "actual DMG sha256 does not match release notes"
    fi
    if [[ -n "$SUMS_SHA" && "$ACTUAL_SHA" != "$SUMS_SHA" ]]; then
        fail "actual DMG sha256 does not match SHA256SUMS.txt"
    fi
    if [[ -n "${CASK_SHA:-}" && "$ACTUAL_SHA" != "$CASK_SHA" ]]; then
        fail "actual DMG sha256 does not match Cask"
    fi
    echo "  dmg:      $DMG"
    echo "  dmg sha:  $ACTUAL_SHA"

    if [[ ! -f "$MANIFEST" ]]; then
        fail "missing signed update manifest: $MANIFEST"
    fi
    if [[ ! -f "$SIGNATURE" ]]; then
        fail "missing update manifest signature: $SIGNATURE"
    fi
    if [[ ! -f "$PUBLIC_KEY_FILE" ]]; then
        fail "missing update public key: $PUBLIC_KEY_FILE"
    fi
    if [[ ! -f "$KEY_ID_FILE" ]]; then
        fail "missing update key id: $KEY_ID_FILE"
    fi

    MANIFEST_SHA="$(python3 - "$MANIFEST" "$VERSION" "XIsland-${VERSION}.dmg" <<'PY'
import json
import sys

path, version, dmg = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as handle:
        manifest = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
if manifest.get("schema") != 1:
    raise SystemExit(1)
if manifest.get("version") != version:
    raise SystemExit(1)
if manifest.get("dmg") != dmg:
    raise SystemExit(1)
sha = str(manifest.get("sha256", ""))
if len(sha) != 64 or any(c not in "0123456789abcdefABCDEF" for c in sha):
    raise SystemExit(1)
print(sha.lower())
PY
)" || fail "update manifest fields do not match version or DMG name"

    if [[ -n "${RELEASE_SHA:-}" && "$MANIFEST_SHA" != "$RELEASE_SHA" ]]; then
        fail "update manifest sha256 does not match release notes"
    fi
    if [[ -n "$SUMS_SHA" && "$MANIFEST_SHA" != "$SUMS_SHA" ]]; then
        fail "update manifest sha256 does not match SHA256SUMS.txt"
    fi
    if [[ "$ACTUAL_SHA" != "$MANIFEST_SHA" ]]; then
        fail "update manifest sha256 does not match actual DMG"
    fi

    PUBLIC_KEY="$(tr -d '[:space:]' < "$PUBLIC_KEY_FILE")"
    KEY_ID="$(tr -d '[:space:]' < "$KEY_ID_FILE")"
    MANIFEST_KEY_ID="$(python3 - "$MANIFEST" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        print(json.load(handle).get("key_id", ""))
except (OSError, ValueError):
    raise SystemExit(1)
PY
)" || fail "cannot read update manifest key_id"
    if [[ "$MANIFEST_KEY_ID" != "$KEY_ID" ]]; then
        fail "update manifest key_id '$MANIFEST_KEY_ID' does not match '$KEY_ID'"
    fi
    if ! swift "$ROOT/Scripts/update-signing.swift" verify "$PUBLIC_KEY" "$MANIFEST" "$SIGNATURE"; then
        fail "update manifest signature did not verify"
    fi
    echo "  manifest: $MANIFEST"
    echo "  manifest sha: $MANIFEST_SHA"
elif (( REQUIRE_DMG )); then
    fail "missing DMG: $DMG"
else
    echo "  dmg:      absent (skipped; use --require-dmg before publishing)"
fi

if (( BUILD )); then
    echo "  build:    swift build -c release --product XIsland -j 2"
    if ! (cd "$ROOT" && swift build -c release --product XIsland -j 2); then
        fail "release build failed"
    fi
fi

if (( errors > 0 )); then
    echo "Preflight failed: $errors error(s)." >&2
    exit 1
fi
echo "Preflight passed."
