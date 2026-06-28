# Architecture

ZcAgentBeacon has three runtime parts:

1. Companion runs on each Codex or Claude Code workstation.
2. Hub runs on Raspberry Pi or a LAN host.
3. Dashboard is Flutter Web served by the Hub.

The companion reads local agent state and returns raw signals. It does not decide whether a conversation is thinking, running a tool, completed, or interrupted. The Hub owns all state inference so behavior updates usually require only a Hub/dashboard upgrade.

## Data Flow

```text
.codex/state_5.sqlite
.codex/sessions/**/rollout-*.jsonl
.codex/process_manager/chat_processes.json
~/.claude/projects/<project>/<session-id>.jsonl
        |
        v
companion /status rawConversations
        |
        v
Hub status engine + history + discovery
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

Claude Code support is implemented as a read-only transcript adapter. Claude's official docs describe `~/.claude/projects/<project>/<session-id>.jsonl` as an internal format, so format changes should be handled inside `zc_agentbeacon_core` without changing the companion or Hub API.
