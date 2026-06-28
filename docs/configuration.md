# Configuration

All configuration is optional. Defaults are LAN-first and token-free.

## Companion

| Variable | Default | Description |
| --- | --- | --- |
| `ZC_AGENTBEACON_COMPANION_HOST` | LAN IP | Bind address |
| `ZC_AGENTBEACON_COMPANION_PORT` | `42180` | HTTP port |
| `ZC_AGENTBEACON_CODEX_HOME` | `~/.codex` | Codex data directory |
| `ZC_AGENTBEACON_SQLITE3` | `sqlite3` | sqlite command |
| `ZC_AGENTBEACON_ALLOWED_SERVER` | empty | Comma-separated allowed server IPs |
| `ZC_AGENTBEACON_TOKEN` | empty | Optional bearer/query token |

## Server

| Variable | Default | Description |
| --- | --- | --- |
| `ZC_AGENTBEACON_SERVER_HOST` | `0.0.0.0` | Bind address |
| `ZC_AGENTBEACON_SERVER_PORT` | `42178` | HTTP port |
| `ZC_AGENTBEACON_WEB_ROOT` | `apps/dashboard/build/web` | Dashboard static files |
| `ZC_AGENTBEACON_DEVICES` | empty | Manual `host:port` list |
| `ZC_AGENTBEACON_SCAN_CIDRS` | local `/24` | Scan ranges |
| `ZC_AGENTBEACON_SCAN_ENABLED` | `1` | Enable LAN scan |
| `ZC_AGENTBEACON_STALE_SECONDS` | `15` | Stale device threshold |
| `ZC_AGENTBEACON_OFFLINE_SECONDS` | `45` | Offline threshold |
| `ZC_AGENTBEACON_SCREEN_CONTROL` | `1` | Linux/X11 screen blanking |
| `ZC_AGENTBEACON_SCREEN_IDLE_SECONDS` | `600` | Idle seconds before blanking |

Legacy `AGENTBEACON_*` variables are only recognized by the old reference implementation under `legacy/`.
