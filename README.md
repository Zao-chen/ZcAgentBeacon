# ZcAgentBeacon

[English](README_EN.md)

🌟 一个运行在局域网内的 **Codex 会话状态仪表盘**。🌟

它可以自动发现多台设备上的 Codex companion，实时展示正在思考、运行工具、完成或中断的对话状态。仪表盘可以运行在任意局域网设备上，也适合放在桌面小屏、房间状态面板、常驻浏览器页面上使用。

[![GitHub Release](https://img.shields.io/github/v/release/Zao-chen/ZcAgentBeacon?color=22c55e&style=for-the-badge)](https://github.com/Zao-chen/ZcAgentBeacon/releases)
[![GitHub Downloads](https://img.shields.io/github/downloads/Zao-chen/ZcAgentBeacon/total?color=6366f1&style=for-the-badge)](https://github.com/Zao-chen/ZcAgentBeacon/releases)
[![GitHub Stars](https://img.shields.io/github/stars/Zao-chen/ZcAgentBeacon?color=f59e0b&style=for-the-badge)](https://github.com/Zao-chen/ZcAgentBeacon/stargazers)
[![GitHub License](https://img.shields.io/github/license/Zao-chen/ZcAgentBeacon?color=ef4444&style=for-the-badge)](LICENSE)

## 🎯 项目介绍

ZcAgentBeacon 由三部分组成：

- **Companion：** 安装在运行 Codex 的 Windows / macOS / Linux 设备上，读取本机 `.codex` 状态并输出 raw signals。
- **Hub：** 运行在承载仪表盘的设备上，自动发现设备、聚合状态、判断会话阶段。
- **Dashboard：** 由 Hub 提供的 Flutter Web 仪表盘，展示局域网内所有设备的 Codex 状态。

### ✨ 核心特性

* 🧭 **局域网自动发现：** Hub 自动扫描和接收 Companion 广播，减少手动配置。
* 🖥 **智能面板：** 可运行在任意浏览器设备上，支持全屏、自启动和小屏布局。
* 🌙 **自动深色模式：** 跟随系统或夜间环境；在支持屏幕控制的 Linux/X11 设备上可空闲黑屏、有新动态自动亮屏。
* 🧠 **统一状态机：** 在 Hub 端判断思考、工具调用、完成、中断、离线和过期状态。
* 🛠 **工具调用可视化：** 展示最近工具名、命令、输出摘要、cwd、设备名和更新时间。
* 🔔 **完成提醒：** 对话从运行状态进入完成状态时弹出提醒。

## 🚀 快速入门

### Step1: 在 Codex 设备安装 Companion

在 [Release](https://github.com/Zao-chen/ZcAgentBeacon/releases) 下载对应 Codex 设备平台的 Companion 安装包。

Windows：

```powershell
Expand-Archive .\ZcAgentBeaconCompanion-windows-x64.zip
.\install-companion.ps1
```

macOS：

```sh
tar -xzf ZcAgentBeaconCompanion-macos-x64.tar.gz
sh install-companion.sh
```

Linux：

```sh
tar -xzf ZcAgentBeaconCompanion-linux-x64.tar.gz
sh install-companion.sh
```

安装后 companion 默认监听：

```text
http://<device-ip>:42180/status
```

### Step2: 在仪表盘设备安装 Hub

```sh
tar -xzf ZcAgentBeaconHub-linux-x64.tar.gz
sudo sh install-hub.sh
```

默认面板地址：

```text
http://<hub-ip>:42178
```

## 🤗 如何贡献

ZcAgentBeacon 是一个开源项目，欢迎一起把它变成更稳定的小工具！

* **提交功能或修复：** 欢迎通过 [Pull Request](https://github.com/Zao-chen/ZcAgentBeacon/pulls) 参与开发，详情见 [CONTRIBUTING.md](CONTRIBUTING.md)。
* **报告 BUG / 建议：** 如果发现状态判断不准、设备发现失败、面板显示异常，请通过 [Issues](https://github.com/Zao-chen/ZcAgentBeacon/issues) 提交。
* **或者……** 给项目点一个 star ⭐，也很有帮助！

## 📄 许可证

本项目采用 GPL-3.0 许可证，见 [LICENSE](LICENSE)。
