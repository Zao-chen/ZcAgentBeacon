# Installation

## Release Artifacts

GitHub Actions publishes:

- `ZcAgentBeacon-windows-x64.zip`
- `ZcAgentBeacon-macos-universal.tar.gz`
- `ZcAgentBeacon-linux-x64.tar.gz`
- `ZcAgentBeacon-linux-x64.deb`
- `ZcAgentBeacon-RaspberryPi-arm64.tar.gz`
- `ZcAgentBeacon-RaspberryPi-source.tar.gz`
- `SHA256SUMS`

## Companion

Install companion on every Codex workstation.

Windows:

```powershell
Expand-Archive .\ZcAgentBeacon-windows-x64.zip
cd .\ZcAgentBeacon-windows-x64
.\install-companion.ps1
```

macOS:

```sh
tar -xzf ZcAgentBeacon-macos-universal.tar.gz
sh install-companion.sh
```

Linux:

```sh
tar -xzf ZcAgentBeacon-linux-x64.tar.gz
sh install-companion.sh
```

## Raspberry Pi Dashboard

```sh
tar -xzf ZcAgentBeacon-RaspberryPi-arm64.tar.gz
sudo sh install-server.sh
sudo sh install-kiosk.sh
```

If the arm64 artifact is unavailable for your Pi, use the source package and build on-device with Dart/Flutter installed:

```sh
tar -xzf ZcAgentBeacon-RaspberryPi-source.tar.gz
sh scripts/build_on_pi.sh
cd installers/raspberry-pi
sudo sh install-server.sh
```
