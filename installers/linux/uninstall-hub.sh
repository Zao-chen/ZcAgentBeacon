#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo sh uninstall-hub.sh" >&2
  exit 1
fi

systemctl disable --now zc-agentbeacon.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/zc-agentbeacon.service
rm -rf /opt/ZcAgentBeacon/Hub
systemctl daemon-reload

echo "ZcAgentBeacon Hub uninstalled."
