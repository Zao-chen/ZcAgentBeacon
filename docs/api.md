# HTTP API

## Companion

### `GET /health`

```json
{ "ok": true, "product": "ZcAgentBeacon", "version": "0.1.0" }
```

### `GET /status`

Returns raw Codex signals:

```json
{
  "nodeId": "stable-device-id",
  "hostname": "workstation",
  "os": "windows",
  "agentVersion": "0.3.0-dart-raw-signals",
  "codexRunning": true,
  "rawConversations": [],
  "errors": [],
  "collectedAt": "2026-06-28T00:00:00Z"
}
```

## Server

### `GET /api/conversations`

Returns devices, inferred conversations, and screen activity metadata.

### `GET /api/devices`

Returns discovered/manual devices.

### `POST /api/devices`

Adds a manual device:

```json
{ "host": "192.168.1.20", "port": 42180 }
```

### `GET /ws`

WebSocket stream of the same shape as `GET /api/conversations`.
