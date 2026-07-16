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

Shared detection wrapper: `bin/detect-non-github.sh` — wraps the canonical detector with a context-specific skip message and normalized exit codes (0 = proceed, 1 = skip). Use this wrapper in SKILL.md consumers instead of inlining the case block.

| Exit code | Meaning | Action |
|---|---|---|
| 0 | GitHub remote | proceed with `gh` |
| 1 | non-GitHub remote | set `NON_GITHUB=1`, skip `gh` |
| 2 | unknown / error | fail-open (treat as 0) |

## Protocol

Consumers that have migrated to the shared wrapper use a 1-line call:

`"$AGENTS_CONFIG_DIR/bin/detect-non-github.sh" "<context-label>" || <skip-action>`

Where `<skip-action>` is either `NON_GITHUB=1` (when the skill continues after
skipping gh work) or `exit 0` (when the skill should terminate immediately).

Each consuming skill states **what to skip** when the wrapper exits 1 and **what
still runs** as normal.

## Current consumers

- `skills/workflow-init/SKILL.md` Step WI-2 — inline `is-github-dotcom-remote` (not yet migrated)
- `skills/commit-push/SKILL.md` Phase 1 pre-flight — uses `detect-non-github.sh`
- `skills/issue-close-stage/SKILL.md` Pre-flight — uses `detect-non-github.sh`
- `skills/issue-close-finalize/SKILL.md` Pre-flight — uses dedicated `scripts/pre-flight.sh` (also resolves OWNER_REPO to stdout; not migrated to detect-non-github.sh)
- `skills/issue-create/SKILL.md` Phase 2 (Survey) — inline `is-github-dotcom-remote` (not yet migrated)

Keep this list in sync when adding/removing consumers.
