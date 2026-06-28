# Configuration

All configuration is optional. Defaults are LAN-first and token-free.

## Companion

| Variable | Default | Description |
| --- | --- | --- |
| `ZC_AGENTBEACON_COMPANION_HOST` | LAN IP | Bind address |
| `ZC_AGENTBEACON_COMPANION_PORT` | `42180` | HTTP port |
| `ZC_AGENTBEACON_CODEX_HOME` | `~/.codex` | Codex data directory |
| `ZC_AGENTBEACON_CLAUDE_HOME` | `~/.claude` | Claude Code data directory |
| `CLAUDE_CONFIG_DIR` | empty | Claude Code config directory; used when `ZC_AGENTBEACON_CLAUDE_HOME` is unset |
| `ZC_AGENTBEACON_SQLITE3` | `sqlite3` | sqlite command |
| `ZC_AGENTBEACON_ALLOWED_HUB` | empty | Comma-separated allowed Hub IPs |
| `ZC_AGENTBEACON_TOKEN` | empty | Optional bearer/query token |

The companion reads both Codex and Claude Code by default. Set the relevant home variable only when the app runs under a different system user or the agent stores data outside the default directory.

## Hub

| Variable | Default | Description |
| --- | --- | --- |
| `ZC_AGENTBEACON_HUB_HOST` | `0.0.0.0` | Hub bind address |
| `ZC_AGENTBEACON_HUB_PORT` | `42178` | Hub HTTP port |
| `ZC_AGENTBEACON_WEB_ROOT` | `apps/dashboard/build/web` | Dashboard static files |
| `ZC_AGENTBEACON_DEVICES` | empty | Manual `host:port` list |
| `ZC_AGENTBEACON_SCAN_CIDRS` | local `/24` | Scan ranges |
| `ZC_AGENTBEACON_SCAN_ENABLED` | `1` | Enable LAN scan |
| `ZC_AGENTBEACON_STALE_SECONDS` | `15` | Stale device threshold |
| `ZC_AGENTBEACON_OFFLINE_SECONDS` | `45` | Offline threshold |
| `ZC_AGENTBEACON_SCREEN_CONTROL` | `1` | Linux/X11 screen blanking |
| `ZC_AGENTBEACON_SCREEN_IDLE_SECONDS` | `600` | Idle seconds before blanking |

`ZC_AGENTBEACON_ALLOWED_SERVER`, `ZC_AGENTBEACON_SERVER_HOST`, and `ZC_AGENTBEACON_SERVER_PORT` are still accepted as compatibility aliases. Legacy `AGENTBEACON_*` variables are only recognized by the old reference implementation under `legacy/`.
