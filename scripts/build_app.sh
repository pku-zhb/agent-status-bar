#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/AgentStatusBar.app"
BIN="$ROOT/.build/release/AgentStatusBar"
APP_VERSION="${APP_VERSION:-0.1.15}"
BUILD_VERSION="${BUILD_VERSION:-16}"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentStatusBar"
cp "$ROOT/Assets/claude.png" "$APP/Contents/Resources/claude.png"
cp "$ROOT/Assets/codex.png" "$APP/Contents/Resources/codex.png"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AgentStatusBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.zhuhuibin.AgentStatusBar</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIcons</key>
  <dict>
    <key>CFBundlePrimaryIcon</key>
    <dict>
      <key>CFBundleIconFiles</key>
      <array>
        <string>AppIcon</string>
      </array>
      <key>CFBundleIconName</key>
      <string>AppIcon</string>
    </dict>
  </dict>
  <key>CFBundleDisplayName</key>
  <string>AgentStatusBar</string>
  <key>CFBundleName</key>
  <string>AgentStatusBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP"

echo "$APP"
