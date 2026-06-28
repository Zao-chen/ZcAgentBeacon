#!/bin/sh
set -eu

PORT="${ZC_AGENTBEACON_HUB_PORT:-${ZC_AGENTBEACON_SERVER_PORT:-42178}}"
INSTALL_DIR="/opt/ZcAgentBeacon"
SERVICE_USER="${SUDO_USER:-$USER}"
SOURCE_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo sh install-hub.sh" >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}/bin" "${INSTALL_DIR}/dashboard"
cp "${SOURCE_DIR}/zc-agentbeacon-hub" "${INSTALL_DIR}/bin/zc-agentbeacon-hub"
chmod +x "${INSTALL_DIR}/bin/zc-agentbeacon-hub"
if [ -d "${SOURCE_DIR}/dashboard" ]; then
  cp -R "${SOURCE_DIR}/dashboard/." "${INSTALL_DIR}/dashboard/"
fi

cat > /etc/systemd/system/zc-agentbeacon.service <<EOF
[Unit]
Description=ZcAgentBeacon Hub
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
Environment=ZC_AGENTBEACON_HUB_PORT=${PORT}
Environment=ZC_AGENTBEACON_WEB_ROOT=${INSTALL_DIR}/dashboard
ExecStart=${INSTALL_DIR}/bin/zc-agentbeacon-hub --host 0.0.0.0 --port ${PORT} --web-root ${INSTALL_DIR}/dashboard
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now zc-agentbeacon.service

echo "ZcAgentBeacon Hub installed at http://<hub-ip>:${PORT}"
echo "For kiosk mode, run: sudo sh ${SOURCE_DIR}/install-kiosk.sh"
