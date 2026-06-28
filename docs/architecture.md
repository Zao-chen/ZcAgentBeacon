# Architecture

ZcAgentBeacon has three runtime parts:

1. Companion runs on each Codex workstation.
2. Server runs on Raspberry Pi or a LAN host.
3. Dashboard is Flutter Web served by the server.

The companion reads local Codex state and returns raw signals. It does not decide whether a conversation is thinking, running a tool, completed, or interrupted. The server owns all state inference so behavior updates usually require only a server/dashboard upgrade.

## Data Flow

```text
.codex/state_5.sqlite
.codex/sessions/**/rollout-*.jsonl
.codex/process_manager/chat_processes.json
        |
        v
companion /status rawConversations
        |
        v
server status engine + history + discovery
        |
        v
Flutter Web dashboard over HTTP/WebSocket
```

## Status Engine

The core package infers:

- `thinking`: an open turn without pending tool calls.
- `tool_running`: a pending function call or fresh process manager record.
- `idle`: a completed turn.
- `interrupted`: an abort/cancel/interrupt event.
- `stale`: device is reachable but beyond stale threshold.
- `error_offline`: device is offline or data cannot be polled.

UUID/process-only auxiliary conversations are folded into a real conversation in the same cwd, and do not trigger completion notifications.
