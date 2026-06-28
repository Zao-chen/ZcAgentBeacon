#!/bin/sh
set -eu

LABEL="com.agentbeacon.companion"
INSTALL_DIR="${HOME}/Library/Application Support/AgentBeacon/Companion"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -rf "$INSTALL_DIR"

echo "AgentBeacon Companion uninstalled."
