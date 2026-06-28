#!/bin/sh
set -eu

PORT="${AGENTBEACON_AGENT_PORT:-42180}"
LABEL="com.agentbeacon.companion"
SOURCE_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${HOME}/Library/Application Support/AgentBeacon/Companion"
LOG_DIR="${HOME}/Library/Logs/AgentBeacon"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/${LABEL}.plist"

PYTHON="${PYTHON:-$(command -v python3 || true)}"
if [ -z "$PYTHON" ]; then
  echo "Python 3 was not found. Install Python 3 first, then run this installer again." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$PLIST_DIR"
cp "$SOURCE_DIR/agentbeacon_agent.py" "$INSTALL_DIR/agentbeacon_agent.py"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PYTHON}</string>
    <string>${INSTALL_DIR}/agentbeacon_agent.py</string>
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

echo "AgentBeacon Companion installed."
echo "LaunchAgent: ${PLIST_PATH}"
echo "Status URL: http://$(ipconfig getifaddr en0 2>/dev/null || hostname):${PORT}/status"
