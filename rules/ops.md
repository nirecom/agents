# Operational Safety

## System-State-Changing Operations

The following categories require **explicit user approval** before execution.
The `hooks/enforce-system-ops.js` PreToolUse hook enforces this automatically.
Escalate via Rule 2 of `rules/user-escalation.md`.

| Category | Blocked commands |
|---|---|
| A — Package install | `winget install/uninstall/upgrade`, `choco install`, `scoop install`, `brew install/uninstall`, `apt/apt-get install/remove/upgrade`, `npm -g`, `pnpm -g`, `yarn global add`, `pip install` (non-user), `pipx install` |
| B — Power | `Restart-Computer`, `Stop-Computer`, `shutdown /r\|/h\|/s`, `reboot`, `halt`, `poweroff` |
| C — Service | `Stop-Service`, `Set-Service`, `Remove-Service`, `sc.exe stop\|delete\|config`, `systemctl stop\|disable\|mask`, `service <name> stop` |
| D — User/group | `New-LocalUser`, `Remove-LocalUser`, `Add/Remove-LocalGroupMember`, `net user /add\|/delete`, `net localgroup /add`, `useradd`, `userdel`, `usermod -G`, `groupadd`, `groupdel` |
| E — System config | `reg delete HKLM\|HKCR`, `Remove-Item HKLM:`, `bcdedit /set\|delete\|create`, `Set-ExecutionPolicy`, `Disable/Enable-WindowsOptionalFeature`, `Add/Remove-WindowsCapability` |
| F — Disk/FS | `format`, `diskpart`, `mkfs.*`, `dd if/of=/dev/*`, `wsl --unregister` |

**Bypass for installer scripts:** set `SYSTEM_OPS_APPROVED=1` in the environment that launches
Claude Code. Inline prefix (`SYSTEM_OPS_APPROVED=1 cmd`) does NOT bypass the hook.
See `rules/installer.md` for the full list of covered commands and bypass details.

## Risky Operations Decision Path

The following are all treated with the same decision path:

- `docker volume rm` / `docker compose down -v`
- `DROP TABLE` / destructive schema migration / volume recreation
- `Remove-Item -Recurse -Force` (PowerShell)
- `rm -rf` (POSIX)
- `git clean -fdx` (deletes all untracked + ignored files)
- `git worktree remove --force` (force-deletes an unclean worktree)

Before proposing any of the above:

1. **Always enumerate recovery options first** and let the user choose:
   - Example (DB): password reset via `POSTGRES_HOST_AUTH_METHOD=trust`, direct DB manipulation
     via `docker exec`, dump → restore to another node, restore from snapshot
   - Example (worktree): complete the inventory + backup manifest from the `/worktree-end` skill first
2. Propose deletion as a **last resort** only after all recovery options are confirmed infeasible.
3. When proposing deletion, state the reason (why recovery is impossible) and the blast radius.

Project-specific recovery commands belong in the project's `docs/ops.md` as runbooks — not in this rule.

## Key and Secret Generation

For generating URL-safe passwords and secret keys, use `/create-key`.
