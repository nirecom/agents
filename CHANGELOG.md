## Archived
- [2026](history/2026.md) — 10

### FEATURE: PR #687 (2026-05-31)
Background: refactor(#672): enforce-worktree positive-allow redesign
Changes: enforce-worktree redesigned to positive-allow: linked worktrees can write freely; main worktree writes are blocked without env-var bypass ceremony (#672). gh issue create now requires a linked worktree — /issue-create guides you to /worktree-start if needed (#600). gh pr merge and gh api PATCH from linked worktrees no longer false-positive blocked (#527). /issue-close-finalize and /worktree-end commit docs to main via GitHub REST API — no local main-worktree write needed.

### FEATURE: PR #698 (2026-05-31)
Background: fix(#685): stop symlink-repair loop firing on every shell start
Changes: category: BUGFIX
