#!/bin/sh
set -eu

PORT="${ZC_AGENTBEACON_COMPANION_PORT:-42180}"
LABEL="com.zcagentbeacon.companion"
SOURCE_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${HOME}/Library/Application Support/ZcAgentBeacon/Companion"
LOG_DIR="${HOME}/Library/Logs/ZcAgentBeacon"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/${LABEL}.plist"
BIN="${INSTALL_DIR}/zc-agentbeacon-companion"

mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$PLIST_DIR"
cp "${SOURCE_DIR}/zc-agentbeacon-companion" "$BIN"
chmod +x "$BIN"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN}</string>
    <string>--port</string>
    <string>${PORT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/companion.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/companion.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true

echo "ZcAgentBeacon Companion installed."
echo "LaunchAgent: ${PLIST_PATH}"
