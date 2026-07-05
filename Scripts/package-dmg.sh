#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="X Island"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# 从 VERSION 文件读取版本号（单一版本源），或使用命令行参数
VERSION="${1:-$(cat "$PROJECT_DIR/VERSION" | tr -d '[:space:]')}"
DMG_OUTPUT="$BUILD_DIR/XIsland-${VERSION}.dmg"

cd "$PROJECT_DIR"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "==> App bundle not found. Running build first..."
    bash Scripts/build.sh
fi

echo "==> Packaging DMG (v$VERSION)..."
rm -f "$DMG_OUTPUT"

create-dmg \
    --volname "$APP_NAME" \
    --volicon "Assets/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 150 190 \
    --app-drop-link 450 190 \
    --no-internet-enable \
    "$DMG_OUTPUT" \
    "$APP_BUNDLE"

echo ""
echo "DMG created: $DMG_OUTPUT"
echo "Size: $(du -h "$DMG_OUTPUT" | cut -f1)"
DMG_SHA256="$(shasum -a 256 "$DMG_OUTPUT" | awk '{print $1}')"
DMG_BASENAME="$(basename "$DMG_OUTPUT")"
echo "SHA256: $DMG_SHA256"
echo ""
echo "==> GitHub release notes (required)"
echo "Every release MUST include the Gatekeeper / xattr block from:"
echo "  $SCRIPT_DIR/release-notes-required-always.md"
echo ""
cat "$SCRIPT_DIR/release-notes-required-always.md"
echo ""
echo "## Checksums"
echo ""
echo "$DMG_BASENAME SHA256: $DMG_SHA256"
echo ""
echo "Example (prepend your changelog, then append the file above):"
echo "  NOTES=\$(mktemp)"
echo "  { echo '## Changes'; echo ''; echo '- your items'; echo ''; cat \"$SCRIPT_DIR/release-notes-required-always.md\"; echo ''; echo '## Checksums'; echo ''; echo '$DMG_BASENAME SHA256: $DMG_SHA256'; } > \"\$NOTES\""
echo "  gh release create v$VERSION \"$DMG_OUTPUT\" --title \"X Island v$VERSION\" --notes-file \"\$NOTES\""
echo "  rm -f \"\$NOTES\""
