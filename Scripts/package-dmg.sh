#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="X Island"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
VERSION="${1:-1.3.2}"
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
echo ""
echo "==> GitHub release notes (required)"
echo "Every release MUST include the Gatekeeper / xattr block from:"
echo "  $SCRIPT_DIR/release-notes-required-always.md"
echo ""
cat "$SCRIPT_DIR/release-notes-required-always.md"
echo ""
echo "Example (prepend your changelog, then append the file above):"
echo "  NOTES=\$(mktemp)"
echo "  { echo '## Changes'; echo ''; echo '- your items'; echo ''; cat \"$SCRIPT_DIR/release-notes-required-always.md\"; } > \"\$NOTES\""
echo "  gh release create v$VERSION "$DMG_OUTPUT" --title "X Island v$VERSION" --notes-file "\$NOTES""
echo "  rm -f \"\$NOTES\""
