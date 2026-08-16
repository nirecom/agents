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

## Risky Operations Decision Path

The following are all treated with the same decision path:

- `docker volume rm` / `docker compose down -v`
- `DROP TABLE` / destructive schema migration / volume recreation
- `Remove-Item -Recurse -Force` (PowerShell)
- `rm -rf` (POSIX)
- `git clean -fdx` (deletes all untracked + ignored files)
- `git worktree remove --force` (force-deletes an unclean worktree)
- `git reset --hard origin/<branch>` (diverged main worktree recovery — discards all local commits AND staged/unstaged tracked changes; irreversible without a prior backup branch)

Before proposing any of the above:

1. **Always enumerate recovery options first** and let the user choose:
   - Example (DB): password reset via `POSTGRES_HOST_AUTH_METHOD=trust`, direct DB manipulation
     via `docker exec`, dump → restore to another node, restore from snapshot
   - Example (worktree): complete the inventory + backup manifest from the `/worktree-end` skill first
2. Propose deletion as a **last resort** only after all recovery options are confirmed infeasible.
3. When proposing deletion, state the reason (why recovery is impossible) and the blast radius.

Project-specific recovery commands belong in the project's `docs/ops.md` as runbooks — not in this rule.

## Diverged Main Worktree Recovery

When the main worktree branch has diverged from its remote (ahead AND behind), pick in this order:

1. `git merge --no-edit origin/<branch>` — **sanctioned** (allowlisted): non-destructive, preserves local commits as a merge commit; Claude runs it directly.
2. `git rebase origin/<branch>` — **user escalation required** (`rules/user-escalation.md`): rewrites local history; safe only when no other device holds the same local commits.
3. `git reset --hard origin/<branch>` — **user escalation required** (decision path above): discards all local commits AND staged/unstaged tracked changes.

Pre-flight for `git reset --hard`: run `git status --porcelain` and save any non-empty output (`git stash push` or a commit) first.
Preserve local commits with a backup branch (`git branch backup-<date>`) before discarding.

## Key and Secret Generation

For generating URL-safe passwords and secret keys, use `/create-key`.
