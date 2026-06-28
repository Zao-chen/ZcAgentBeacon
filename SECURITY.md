# Security

ZcAgentBeacon is designed for trusted LAN use.

## Defaults

- Companion and server are intended to bind on local network addresses.
- Token authentication is optional and disabled by default.
- Secret masking is applied before raw signals leave the companion, but users should still avoid exposing the service to untrusted networks.

## Hardening

- Set `ZC_AGENTBEACON_TOKEN` on both server and companion.
- Set `ZC_AGENTBEACON_ALLOWED_SERVER` on companions.
- Bind to a specific LAN IP instead of `0.0.0.0`.
- Keep the dashboard behind your home/router firewall.

## Reporting

Please do not open public issues for security vulnerabilities. Contact the maintainer privately, or open a minimal issue asking for a private disclosure channel.
