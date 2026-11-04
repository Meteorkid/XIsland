#!/bin/bash
# 本地验收部署：把 Debug 构建组装成可双击的 .app。
#
# 与正式打包的区别：
#   - 独立 bundle id（dev.xisland.app.debug），不会覆盖或混淆正式版的设置与授权；
#   - Info.plist 写入 LSEnvironment: X_ISLAND_ACCEPTANCE=1，双击即进入验收模式；
#   - 只做 ad-hoc 签名，不公证、不写 ~/.xisland/bin。
#
# 用法：bash Scripts/package-debug-acceptance.sh [--build]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${X_ISLAND_BUILD_DIR:-$PROJECT_DIR/.build}"
APP_NAME="X Island (Debug)"
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"

cd "$PROJECT_DIR"
if [[ "${1:-}" == "--build" ]]; then
    echo "==> Building debug..."
    swift build --disable-sandbox
fi

test -f "$BUILD_DIR/debug/XIsland" || { echo "缺少 $BUILD_DIR/debug/XIsland，先运行 swift build"; exit 1; }

echo "==> Assembling $APP_BUNDLE"
mkdir -p "$HOME/Applications"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/debug/XIsland" "$APP_BUNDLE/Contents/MacOS/XIsland"
cp "$BUILD_DIR/debug/DIBridge" "$APP_BUNDLE/Contents/MacOS/di-bridge"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>dev.xisland.app.debug</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>XIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>X Island needs local network access to discover iPhone and Apple Watch companions on the same Wi-Fi.</string>
    <key>NSBonjourServices</key>
    <array><string>_xisland-buddy._tcp</string><string>_xisland-buddy._udp</string></array>
    <key>LSEnvironment</key>
    <dict><key>X_ISLAND_ACCEPTANCE</key><string>1</string></dict>
</dict>
</plist>
PLIST

codesign -s - -f "$APP_BUNDLE/Contents/MacOS/di-bridge" 2>/dev/null
codesign -s - -f "$APP_BUNDLE/Contents/MacOS/XIsland" 2>/dev/null
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null

echo "==> Done"
echo "App:      $APP_BUNDLE"
echo "BundleID: dev.xisland.app.debug（与正式版隔离）"
echo "启动:     open \"$APP_BUNDLE\""
echo "提示:     先退出正在运行的正式版，避免两者同时订阅岛切换通知。"
