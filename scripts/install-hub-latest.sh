#!/bin/sh
set -eu

REPO="${ZC_AGENTBEACON_REPO:-Zao-chen/ZcAgentBeacon}"
VERSION="${ZC_AGENTBEACON_VERSION:-latest}"
PORT="${ZC_AGENTBEACON_HUB_PORT:-${ZC_AGENTBEACON_SERVER_PORT:-42178}}"
INSTALL_KIOSK="${ZC_AGENTBEACON_INSTALL_KIOSK:-0}"
ARCH="$(uname -m)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install-hub-latest.sh | sudo sh" >&2
  exit 1
fi

download() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    echo "curl or wget is required to download ZcAgentBeacon." >&2
    exit 1
  fi
}

release_url() {
  asset="$1"
  if [ "$VERSION" = "latest" ]; then
    echo "https://github.com/${REPO}/releases/latest/download/${asset}"
  else
    echo "https://github.com/${REPO}/releases/download/${VERSION}/${asset}"
  fi
}

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

case "$ARCH" in
  x86_64|amd64)
    ASSET="ZcAgentBeaconHub-linux-x64.tar.gz"
    PACKAGE_DIR="$WORK_DIR/hub"
    mkdir -p "$PACKAGE_DIR"
    echo "Downloading ${ASSET} from ${REPO} (${VERSION})..."
    download "$(release_url "$ASSET")" "$WORK_DIR/$ASSET"
    tar -xzf "$WORK_DIR/$ASSET" -C "$PACKAGE_DIR"
    ZC_AGENTBEACON_HUB_PORT="$PORT" sh "$PACKAGE_DIR/install-hub.sh"
    ;;
  aarch64|arm64|armv7l|armv6l|armhf)
    ASSET="ZcAgentBeaconHub-raspberry-pi-source.tar.gz"
    PACKAGE_DIR="$WORK_DIR/pi-source"
    mkdir -p "$PACKAGE_DIR"
    echo "Downloading ${ASSET} from ${REPO} (${VERSION})..."
    download "$(release_url "$ASSET")" "$WORK_DIR/$ASSET"
    tar -xzf "$WORK_DIR/$ASSET" -C "$PACKAGE_DIR"
    if ! command -v dart >/dev/null 2>&1 || ! command -v flutter >/dev/null 2>&1; then
      echo "Raspberry Pi source install requires Dart and Flutter on the Pi." >&2
      echo "Install them first, then run this command again." >&2
      exit 1
    fi
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && command -v sudo >/dev/null 2>&1; then
      chown -R "$SUDO_USER:$SUDO_USER" "$WORK_DIR"
      sudo -u "$SUDO_USER" sh -c "cd '$PACKAGE_DIR' && sh scripts/build_on_pi.sh"
    else
      (cd "$PACKAGE_DIR" && sh scripts/build_on_pi.sh)
    fi
    ZC_AGENTBEACON_HUB_PORT="$PORT" sh "$PACKAGE_DIR/installers/raspberry-pi/install-hub.sh"
    if [ "$INSTALL_KIOSK" = "1" ]; then
      ZC_AGENTBEACON_HUB_PORT="$PORT" sh "$PACKAGE_DIR/installers/raspberry-pi/install-kiosk.sh"
    fi
    ;;
  *)
    echo "Unsupported architecture: ${ARCH}" >&2
    echo "Download a release package manually from https://github.com/${REPO}/releases" >&2
    exit 1
    ;;
esac

echo "ZcAgentBeacon Hub is ready at http://<hub-ip>:${PORT}"
