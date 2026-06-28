# Installation

## Release Artifacts

GitHub Actions publishes role-based packages:

- `ZcAgentBeaconCompanion-windows-x64.zip`
- `ZcAgentBeaconCompanion-macos-x64.tar.gz`
- `ZcAgentBeaconCompanion-linux-x64.tar.gz`
- `ZcAgentBeaconHub-linux-x64.tar.gz`
- `ZcAgentBeaconHub-linux-x64.deb`
- `ZcAgentBeaconHub-raspberry-pi-source.tar.gz`
- `SHA256SUMS`

## Companion

Install Companion on every Codex workstation.

Windows:

```powershell
Expand-Archive .\ZcAgentBeaconCompanion-windows-x64.zip
cd .\ZcAgentBeaconCompanion-windows-x64
.\install-companion.ps1
```

macOS:

```sh
tar -xzf ZcAgentBeaconCompanion-macos-x64.tar.gz
sh install-companion.sh
```

Linux:

```sh
tar -xzf ZcAgentBeaconCompanion-linux-x64.tar.gz
sh install-companion.sh
```

## Hub And Dashboard

Install Hub on the device that serves the dashboard.

Linux x64:

```sh
tar -xzf ZcAgentBeaconHub-linux-x64.tar.gz
sudo sh install-hub.sh
```

Debian/Ubuntu x64:

```sh
sudo apt install ./ZcAgentBeaconHub-linux-x64.deb
sudo systemctl enable --now zc-agentbeacon
```

Raspberry Pi:

```sh
tar -xzf ZcAgentBeaconHub-raspberry-pi-source.tar.gz
sh scripts/build_on_pi.sh
cd installers/raspberry-pi
sudo sh install-hub.sh
sudo sh install-kiosk.sh
```
