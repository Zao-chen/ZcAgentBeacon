# ZcAgentBeacon

[中文](README.md)

🌟 A **Codex / Claude Code conversation status dashboard** for your local network. 🌟

ZcAgentBeacon discovers companion agents across your LAN and shows whether each conversation is thinking, running tools, completed, interrupted, stale, or offline. The dashboard can run on any device in the same network, and it is especially useful for a desk display, room status panel, Raspberry Pi kiosk, or always-on browser page.

[![GitHub Release](https://img.shields.io/github/v/release/Zao-chen/ZcAgentBeacon?color=22c55e&style=for-the-badge)](https://github.com/Zao-chen/ZcAgentBeacon/releases)
[![GitHub Downloads](https://img.shields.io/github/downloads/Zao-chen/ZcAgentBeacon/total?color=6366f1&style=for-the-badge)](https://github.com/Zao-chen/ZcAgentBeacon/releases)
[![GitHub Stars](https://img.shields.io/github/stars/Zao-chen/ZcAgentBeacon?color=f59e0b&style=for-the-badge)](https://github.com/Zao-chen/ZcAgentBeacon/stargazers)
[![GitHub License](https://img.shields.io/github/license/Zao-chen/ZcAgentBeacon?color=ef4444&style=for-the-badge)](LICENSE)

## 🎯 Project Overview

ZcAgentBeacon has three main parts:

- **Companion:** Runs on each Windows / macOS / Linux device that uses Codex or Claude Code. It reads local `.codex` / `.claude` data and exposes raw signals.
- **Hub:** Runs on the dashboard host. It discovers devices, aggregates signals, and infers conversation status.
- **Dashboard:** A Flutter Web interface served by the Hub that lists Codex conversation activity from every discovered device.

### ✨ Core Features

* 🧭 **LAN discovery:** The Hub scans for companions and receives UDP announcements to reduce manual setup.
* 🖥 **Smart dashboard:** Runs in any modern browser, with fullscreen, autostart, and compact small-screen layouts.
* 🌙 **Automatic dark mode:** Follows the system theme; on supported Linux/X11 displays it can blank the screen after idle time and wake it on new activity.
* 🧠 **Hub-side state engine:** Companions only send raw signals. The Hub determines thinking, tool calls, completion, interruption, offline, and stale states.
* 🛠 **Tool-call visibility:** Shows the latest tool name, command, output summary, working directory, device name, and update time.
* 🔔 **Completion notifications:** Pops a local notification when a conversation moves from running to completed.

## 🚀 Quick Start

### Step 1: Install Companion On Agent Devices

Download the Companion package for each agent device from [Releases](https://github.com/Zao-chen/ZcAgentBeacon/releases).

Windows:

```powershell
Expand-Archive .\ZcAgentBeaconCompanion-windows-x64.zip
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

After installation, the companion listens on:

```text
http://<device-ip>:42180/status
```

### Step 2: Install Hub On The Dashboard Device

```sh
tar -xzf ZcAgentBeaconHub-linux-x64.tar.gz
sudo sh install-hub.sh
```

The dashboard is available at:

```text
http://<hub-ip>:42178
```

For Raspberry Pi kiosk mode:

```sh
sudo sh install-kiosk.sh
```

## 🧑‍💻 Development

```sh
dart pub get
cd packages/zc_agentbeacon_core && dart test && cd ../..
cd apps/dashboard && flutter test && flutter build web --release
```

## 📁 Repository Layout

```text
packages/zc_agentbeacon_core   shared models, agent adapters, status engine
apps/companion                 local raw-signal companion
apps/server                    Hub implementation
apps/dashboard                 Flutter Web dashboard
installers/                    platform installers
docs/                          documentation
legacy/                        previous reference implementations
```

## 🤗 Contributing

ZcAgentBeacon is open source, and contributions are welcome.

* **Submit features or fixes:** Pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.
* **Report bugs or ideas:** If status detection is inaccurate, discovery fails, or the dashboard layout breaks, please open an [Issue](https://github.com/Zao-chen/ZcAgentBeacon/issues).
* **Or...** leaving a star is also a lovely way to help the project grow.

## 📄 License

This project is licensed under GPL-3.0. See [LICENSE](LICENSE).
