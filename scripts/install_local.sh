#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT_APP="$ROOT/dist/AgentStatusBar.app"
INSTALLED_APP="/Applications/AgentStatusBar.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.zhuhuibin.AgentStatusBar.plist"
LAUNCH_LABEL="com.zhuhuibin.AgentStatusBar"
GUI_DOMAIN="gui/$(id -u)"

"$ROOT/scripts/build_app.sh"
/usr/bin/codesign --verify --deep --strict "$BUILT_APP"

/bin/launchctl bootout "$GUI_DOMAIN/$LAUNCH_LABEL" >/dev/null 2>&1 || true
/usr/bin/ditto "$BUILT_APP" "$INSTALLED_APP"
/bin/mkdir -p "$HOME/Library/LaunchAgents"
/usr/bin/install -m 0644 "$ROOT/LaunchAgents/com.zhuhuibin.AgentStatusBar.plist" "$LAUNCH_AGENT"

/bin/launchctl bootstrap "$GUI_DOMAIN" "$LAUNCH_AGENT"
/bin/launchctl kickstart -k "$GUI_DOMAIN/$LAUNCH_LABEL"

echo "$INSTALLED_APP"
echo "$LAUNCH_AGENT"
