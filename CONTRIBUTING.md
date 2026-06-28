# Contributing

感谢你愿意帮助改进 ZcAgentBeacon。

## 开发环境

```sh
dart pub get
dart format packages apps
dart analyze
cd packages/zc_agentbeacon_core && dart test && cd ../..
cd apps/dashboard && flutter test && cd ../..
```

## 开发运行

先构建 Flutter Web 仪表盘：

```sh
cd apps/dashboard
flutter build web --release
cd ../..
```

启动 companion：

```sh
dart run zc_agentbeacon_companion:zc_agentbeacon_companion
```

启动 Hub：

```sh
dart run zc_agentbeacon_hub:zc_agentbeacon_hub --web-root apps/dashboard/build/web
```

默认地址：

```text
Companion: http://<device-ip>:42180/status
Dashboard: http://<hub-ip>:42178
```

## 仓库结构

```text
packages/zc_agentbeacon_core   共享模型、Codex adapter、状态机
apps/companion                 本机 Codex raw-signal companion
apps/server                    Hub 实现、发现、扫描、屏幕控制
apps/dashboard                 Flutter Web dashboard
installers/                    各平台安装脚本
docs/                          详细文档
legacy/                        旧 Python/Dart 参考实现，不进入发布包
```

## Pull Requests

- Keep Companion raw-signal only; status inference belongs in the Hub/core.
- Add tests for status-machine changes.
- Do not commit local `.codex` data, screenshots, build outputs, or release archives.
- Document new configuration in `docs/configuration.md`.

## Issues

When reporting status bugs, include:

- OS and Codex version if available.
- Companion `/health`.
- Redacted `/status` or `/api/conversations` output.
- What the dashboard showed and what you expected.
