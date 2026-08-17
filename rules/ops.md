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

## Diverged Main Worktree Recovery

When the main worktree branch has diverged from its remote (ahead AND behind), pick in this order:

1. `git merge --no-edit origin/<branch>` — **sanctioned** (allowlisted): non-destructive, preserves local commits as a merge commit; Claude runs it directly.
2. `git rebase origin/<branch>` — **user escalation required** (`rules/user-escalation.md`): rewrites local history; safe only when no other device holds the same local commits.
3. `git reset --hard origin/<branch>` — **user escalation required** (Rule 2 of `rules/user-escalation.md`, decision path per `settings.json` deny layer): discards all local commits AND staged/unstaged tracked changes.

Pre-flight for `git reset --hard`: run `git status --porcelain` and save any non-empty output (`git stash push` or a commit) first.
Preserve local commits with a backup branch (`git branch backup-<date>`) before discarding.

## Key and Secret Generation

For generating URL-safe passwords and secret keys, use `/create-key`.
