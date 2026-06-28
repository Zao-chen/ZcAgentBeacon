#!/bin/sh
set -eu

PORT="${ZC_AGENTBEACON_HUB_PORT:-${ZC_AGENTBEACON_SERVER_PORT:-42178}}"
KIOSK_USER="${SUDO_USER:-$USER}"
AUTOSTART_DIR="/home/${KIOSK_USER}/.config/autostart"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo sh install-kiosk.sh" >&2
  exit 1
fi

mkdir -p "$AUTOSTART_DIR"
cat > "${AUTOSTART_DIR}/zc-agentbeacon-kiosk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ZcAgentBeacon Kiosk
Exec=chromium-browser --autoplay-policy=no-user-gesture-required --disable-infobars --disable-session-crashed-bubble --noerrdialogs --kiosk http://127.0.0.1:${PORT}
X-GNOME-Autostart-enabled=true
EOF

chown -R "${KIOSK_USER}:${KIOSK_USER}" "$AUTOSTART_DIR"
echo "ZcAgentBeacon kiosk autostart installed for ${KIOSK_USER}."
