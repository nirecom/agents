---
name: worktree-end
description: Safely merge, clean up, and remove a git worktree with gitignored state preservation
---

Inventory and preserve gitignored state, switch Docker bind mounts if needed, then remove
the worktree safely.

## Procedure

1. Verify the target worktree exists:
   ```
   git worktree list --porcelain
   ```

2. Check commit and push status of the worktree branch.

3. Check merge / PR status into main.

4. **Inventory** (NUL-delimited, handles spaces and non-ASCII paths):
   ```
   git -C <worktree> ls-files --others --ignored --exclude-standard -z
   git -C <worktree> ls-files --others --exclude-standard -z
   git -C <worktree> status --porcelain=v1 -z
   ```
   Also read `WORKTREE_NOTES.md` if it exists.

5. **Generate backup manifest** — for each file: path, size, mtime, sha256.
   Do NOT include secret values in the manifest — metadata only.

6. **Docker bind mount impact detection** (both running and stopped containers):
   ```
   docker ps -a --format json
   docker inspect $(docker ps -aq)
   ```
   - Check `.Mounts.Source` for all containers against the worktree path.
   - If a `docker-compose.yml` exists in the worktree, run `docker compose config`
     and check `bind` mounts and `env_file` entries.
   - Normalize paths across formats (WSL `/mnt/<drive>/`, Windows `<DRIVE>:\`, MSYS `/drive/`)
     then match by prefix.
   - Report: "Stopped containers included." "If not detected, also check for dev scripts
     that reference this path directly."

7. **Present DRY RUN summary to the user:**
   - Paths to be deleted / untracked count / ignored count
   - Preservation candidates (from inventory + WORKTREE_NOTES.md)
   - Docker mount impact
   - Commands that will be executed
   - Preservation destination — propose the default, then let the user override:
     - **Default:** `<main_root>/.worktree-backup/<branch>/` (gitignored by `.git/info/exclude`)
     - Alternatives: main checkout (same relative path), user-specified directory, discard

8. After user approval: copy preservation targets to the specified destination.

9. Stop any processes with bind mounts pointing to the worktree, then restart from the
   main path (switch mount source).

10. Remove the worktree:
    ```
    git worktree remove <path>
    ```
    `--force` is **prohibited by default**. Use it only after steps 4–8 are complete
    AND the user gives explicit re-approval.

11. Final report including: backup manifest save location.

## Rules

- Never run `git worktree remove --force` without completing inventory + user re-approval.
- Always propose `.worktree-backup/<branch>/` as the default destination; never silently pick a different path.
- Always check stopped containers, not just running ones, for bind mount conflicts.
- Secret values must not appear in the backup manifest.
