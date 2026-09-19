# Non-GitHub Remote Gate — Shared Protocol

Canonical docs for the GitHub-remote detection gate. Each consuming SKILL.md
inlines the snippet below — this file is reference, not auto-loaded.

## Why

Skills that invoke `gh` (issues, PRs, sub-issues, Projects v2) only work on
GitHub remotes. The gate short-circuits gracefully on non-GitHub origins
(GitLab, Forgejo, plain SSH) instead of failing on `gh` invocation. Treats
unknown (rc=2) as fail-open to preserve existing behavior under transient
detection failures.

Canonical detector: `bin/is-github-dotcom-remote`. Since #2307 it classifies the
host through the shared `detectForgeType()` in `hooks/lib/parse-remote-url.js`
(SSOT), via the sibling `bin/is-github-dotcom-remote.js`. The wrapper stays a pure
URL classifier — it never consults `AGENTS_CONFIG_DIR`.

Shared detection wrapper: `bin/detect-non-github.sh` — wraps the canonical detector with a context-specific skip message and normalized exit codes (0 = proceed, 1 = skip). Use this wrapper in SKILL.md consumers instead of inlining the case block.

| Exit code | Meaning | Action |
|---|---|---|
| 0 | GitHub remote | proceed with `gh` |
| 1 | non-GitHub remote | set `NON_GITHUB=1`, skip `gh` |
| 2 | unknown / error | fail-open (treat as 0) |

## Forge routing (#2307)

`hooks/lib/forge-router.js` is the SSOT for forge resolution. It splits two
independent axes and routes each to a descriptor; an unresolvable axis lands on a
no-op stub, never on the GitHub handler (the no-fallback security invariant).

| Axis | Resolver | Members | Fail-safe |
|---|---|---|---|
| Codehost (repo hosting) | `resolveCodehostDescriptor(remoteUrl)` | github (gh), gitlab/unknown (stub) | stub: `isPrivateRepo` false, `hasOpenPrForBranch` true |
| Tracker (issues/MRs) | `resolveTrackerDescriptor(env, codehostType)` | github (gh), gitlab (glab), jira/unknown (stub) | stub: `isForgeScanTarget` false |

Tracker axis: `FORGE_TRACKER` (from `.env`, read via `readTrackerConfig`) selects
the tracker explicitly; unset/empty follows the codehost; an explicit but
unregistered value resolves to the unknown/stub tracker, never the codehost.
`detect-non-github.sh` still keys off the codehost host only — a non-GitHub
codehost skips `gh`, independent of which tracker is configured.

## Protocol

Consumers that have migrated to the shared wrapper use a 1-line call:

`bash "$AGENTS_CONFIG_DIR/bin/detect-non-github.sh" "<context-label>" || <skip-action>`

Where `<skip-action>` is either `NON_GITHUB=1` (when the skill continues after
skipping gh work) or `exit 0` (when the skill should terminate immediately).

Each consuming skill states **what to skip** when the wrapper exits 1 and **what
still runs** as normal.

## Current consumers

- `skills/workflow-init/SKILL.md` Step WI-2 — inline `is-github-dotcom-remote` (not yet migrated)
- `skills/commit-push/SKILL.md` Phase 1 pre-flight — uses `detect-non-github.sh`
- `skills/issue-close-stage/SKILL.md` Pre-flight — uses `detect-non-github.sh`
- `skills/issue-close-finalize/SKILL.md` Pre-flight — uses dedicated `scripts/pre-flight.sh`; derives the gate from the same origin parse that yields OWNER_REPO (`bin/github-issues/lib/origin-repo.sh`), so it calls neither wrapper
- `skills/issue-create/SKILL.md` Phase 2 (Survey) — inline `is-github-dotcom-remote` (not yet migrated)

Keep this list in sync when adding/removing consumers.
