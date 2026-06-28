#!/bin/sh
set -eu

PORT="${ZC_AGENTBEACON_COMPANION_PORT:-42180}"
INSTALL_DIR="${HOME}/.local/share/ZcAgentBeacon/Companion"
BIN_DIR="${HOME}/.local/bin"
SERVICE_DIR="${HOME}/.config/systemd/user"
SOURCE_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$SERVICE_DIR"
cp "${SOURCE_DIR}/zc-agentbeacon-companion" "${INSTALL_DIR}/zc-agentbeacon-companion"
chmod +x "${INSTALL_DIR}/zc-agentbeacon-companion"
ln -sf "${INSTALL_DIR}/zc-agentbeacon-companion" "${BIN_DIR}/zc-agentbeacon-companion"

cat > "${SERVICE_DIR}/zc-agentbeacon-companion.service" <<EOF
[Unit]
Description=ZcAgentBeacon Companion

[Service]
ExecStart=${INSTALL_DIR}/zc-agentbeacon-companion --port ${PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now zc-agentbeacon-companion.service

echo "ZcAgentBeacon Companion installed."
