---
paths:
  - ".on-demand-only/never-match"
---
<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->

# Operational Safety

## System-State-Changing Operations

The following categories require **explicit user approval** (Rule 2 of
`rules/user-escalation.md`). The `hooks/enforce-system-ops.js` PreToolUse hook enforces
this automatically — see the hook source for the exact command set per category.

| Category | Scope |
|---|---|
| A | Package install / uninstall / upgrade (system-wide) |
| B | Power (shutdown / restart / halt) |
| C | Service stop / disable / mask |
| D | Local user / group management |
| E | Registry (HKLM/HKCR) / boot config / system features |
| F | Disk / filesystem (format, partition, mkfs, raw `dd`, wsl unregister) |

## Key and Secret Generation

For generating URL-safe passwords and secret keys, use `/create-key`.
