#!/bin/sh
set -eu

systemctl --user disable --now zc-agentbeacon-companion.service >/dev/null 2>&1 || true
rm -f "${HOME}/.config/systemd/user/zc-agentbeacon-companion.service"
rm -f "${HOME}/.local/bin/zc-agentbeacon-companion"
rm -rf "${HOME}/.local/share/ZcAgentBeacon/Companion"
systemctl --user daemon-reload >/dev/null 2>&1 || true

echo "ZcAgentBeacon Companion uninstalled."
