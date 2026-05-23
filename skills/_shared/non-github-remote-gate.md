# Non-GitHub Remote Gate — Shared Protocol

Canonical docs for the GitHub-remote detection gate. Each consuming SKILL.md
inlines the snippet below — this file is reference, not auto-loaded.

## Why

Skills that invoke `gh` (issues, PRs, sub-issues, Projects v2) only work on
GitHub remotes. The gate short-circuits gracefully on non-GitHub origins
(GitLab, Forgejo, plain SSH) instead of failing on `gh` invocation. Treats
unknown (rc=2) as fail-open to preserve existing behavior under transient
detection failures.

Canonical detector: `bin/is-github-dotcom-remote`.

| Exit code | Meaning | Action |
|---|---|---|
| 0 | GitHub remote | proceed with `gh` |
| 1 | non-GitHub remote | set `NON_GITHUB=1`, skip `gh` |
| 2 | unknown / error | fail-open (treat as 0) |

## Protocol (inlined into each consuming SKILL.md)

```bash
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; rc=$?
NON_GITHUB=$([ "$rc" = "1" ] && echo 1 || echo 0)  # rc=2 → fail-open
[ "$NON_GITHUB" = "1" ] && echo "[GITHUB_ISSUES disabled: non-GitHub remote, skipping <skill-name> issue routing]"
```

Each consuming skill states **what to skip** when `NON_GITHUB=1` and **what
still runs** as normal — the gate itself does not abort the skill.

## Current consumers

- `skills/workflow-init/SKILL.md` Step 0.5
- `skills/commit-push/SKILL.md` Phase 1 pre-flight + PR step
- `skills/issue-close-stage/SKILL.md` Pre-flight
- `skills/issue-close-finalize/SKILL.md` Pre-flight
- `skills/issue-create/SKILL.md` Phase 2 (Survey)

Keep this list in sync when adding/removing consumers.
