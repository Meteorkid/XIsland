#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION="${1:-$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")}"
DMG_PATH="${2:-$PROJECT_DIR/.build/XIsland-${VERSION}.dmg}"
MANIFEST_PATH="$PROJECT_DIR/.build/XIsland-${VERSION}.manifest.json"
SIGNATURE_PATH="$PROJECT_DIR/.build/XIsland-${VERSION}.manifest.sig"
PRIVATE_KEY="${X_ISLAND_UPDATE_SIGNING_KEY:-$HOME/.xisland/update-signing/xisland-update-2026-11.private.key}"
KEY_ID_FILE="$PROJECT_DIR/Config/UpdateSigningKeyID.txt"
PUBLIC_KEY_FILE="$PROJECT_DIR/Config/UpdateSigningPublicKey.txt"

if [[ ! -f "$DMG_PATH" ]]; then
    echo "sign-update: missing DMG: $DMG_PATH" >&2
    exit 1
fi
if [[ ! -f "$PRIVATE_KEY" ]]; then
    echo "sign-update: missing update signing private key: $PRIVATE_KEY" >&2
    echo "Generate one with: swift Scripts/update-signing.swift generate <private-key> <public-key>" >&2
    exit 1
fi
if [[ ! -f "$KEY_ID_FILE" ]]; then
    echo "sign-update: missing key id file: $KEY_ID_FILE" >&2
    exit 1
fi

KEY_ID="$(tr -d '[:space:]' < "$KEY_ID_FILE")"
PUBLIC_KEY="$(tr -d '[:space:]' < "$PUBLIC_KEY_FILE")"
DMG_NAME="$(basename "$DMG_PATH")"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

export VERSION DMG_NAME DMG_SHA256 KEY_ID MANIFEST_PATH
python3 - <<'PY'
import json
import os

manifest = {
    "schema": 1,
    "version": os.environ["VERSION"],
    "dmg": os.environ["DMG_NAME"],
    "sha256": os.environ["DMG_SHA256"],
    "key_id": os.environ["KEY_ID"],
}
with open(os.environ["MANIFEST_PATH"], "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
    handle.write("\n")
PY

swift "$SCRIPT_DIR/update-signing.swift" sign "$PRIVATE_KEY" "$MANIFEST_PATH" "$SIGNATURE_PATH"

echo "Signed update manifest:"
echo "  Manifest: $MANIFEST_PATH"
echo "  Signature: $SIGNATURE_PATH"
echo "  SHA256: $DMG_SHA256"
echo "  Key ID: $KEY_ID"
echo "  Public key: $PUBLIC_KEY"
