# Troubleshooting

## Dashboard shows no conversations

- Confirm companion is running: `http://<device-ip>:42180/health`.
- Confirm raw status is available: `http://<device-ip>:42180/status`.
- Check firewall private/LAN access.
- Set `ZC_AGENTBEACON_DEVICES=<device-ip>:42180` on the server to bypass discovery.

## Conversation is stuck in thinking

The server decides state from raw signals. Upgrade the server first. If it still happens, save the relevant `rawConversations` item and open an issue with secrets removed.

## UUID-like rows appear

These are usually process-manager auxiliary records. The status engine folds process-only UUID rows into the real conversation in the same cwd. If a UUID row remains visible, include `/api/conversations` output in an issue.

## Raspberry Pi screen does not blank or wake

Screen control requires Linux/X11 and `/usr/bin/xset`.

Check:

```sh
echo $DISPLAY
xset q
systemctl status zc-agentbeacon.service
```

Disable screen control with:

```sh
ZC_AGENTBEACON_SCREEN_CONTROL=0
```
