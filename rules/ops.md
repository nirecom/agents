# Operational Safety

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
