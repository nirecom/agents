---
name: issue-close
description: DEPRECATED — split into /issue-close-stage (Phase 1, worktree) and /issue-close-finalize (Phase 2, main worktree). Run this to see migration instructions; exits non-zero intentionally.
---

> **DEPRECATED.** `/issue-close` has been split into two skills:
>
> - `/issue-close-stage <N>` — Phase 1. Run **inside the linked worktree**
>   BEFORE the PR is merged. Performs sub-issue gate, posts the pending
>   sentinel, does doc-append + commit, promotes the sentinel, and updates
>   the parent body.
> - `/issue-close-finalize <N>` — Phase 2. Run from the **main worktree**
>   AFTER the PR is merged. Closes the issue and posts the resolved-by +
>   appended sentinels. API-only on the normal path.
>
> The split removes the `ENFORCE_WORKTREE=on`/`off` toggling that was needed
> when `/issue-close` ran doc-append from the main worktree.
>
> Update your CLAUDE.md, scripts, and workflow notes. Replace any reference
> to `/issue-close` with the appropriate Phase 1 or Phase 2 skill.

On invocation: print the deprecation notice above to stderr and exit non-zero.
Do NOT forward to either new skill automatically — the caller must update
their workflow explicitly.

```bash
cat <<'EOF' >&2
DEPRECATED: /issue-close has been split.

  Phase 1 (worktree, before PR merge):  /issue-close-stage <N>
  Phase 2 (main worktree, after merge): /issue-close-finalize <N>

Update CLAUDE.md / scripts / workflow notes to use the appropriate Phase.
EOF
exit 1
```
