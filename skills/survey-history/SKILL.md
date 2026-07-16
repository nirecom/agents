---
name: survey-history
description: Investigate git history, docs/history.md, and GitHub issue/PR timeline since the relevant issue opened, to surface changes that may invalidate the issue's premises.
model: sonnet
user-invocable: false
---

Investigate the project's git history and GitHub issue/PR timeline to detect changes
made after the relevant issue was opened that might invalidate its premises.

## Procedure

Apply `skills/_shared/resolve-plans-dir.md` once at the start of Procedure;
substitute the resolved absolute path for every `<PLANS_DIR>` placeholder
below. Reuse across all subsequent steps — do not re-resolve.

When invoked as a parallel Agent subagent by workflow-init, the orchestrator
passes `artifact_path` and `context_path` as resolved absolute strings — use
those instead.

SH-1. **Input and issue number resolution:**
   Input precedence (read whichever exists first):
     (a) `<PLANS_DIR>/<session-id>-intent.md` — preferred (post-clarify-intent calls)
     (b) `<PLANS_DIR>/<session-id>-context.md` — fallback (pre-clarify-intent calls
         from workflow-init)
   Issue number N:
   - From intent.md: extract from `## Issues` section (canonical parser: `hooks/lib/parse-closes-issues.js`).
   - From context.md: read `issue-number` from `## Session metadata`.
   - If N is `(none)`, absent, or non-integer → proceed in **keyword-only mode** (Step SH-3).

SH-2. Run: `gh issue view <N> --json createdAt --jq .createdAt`
   - On success: record `openedAt` (ISO-8601 date string).
   - On failure (gh unavailable, auth error, etc.): record "gh unavailable — using
     approximate date" and continue; set `openedAt` to 90 days ago as a conservative fallback.

SH-3. **Keyword-only mode** (no issue number available): run `bash "$AGENTS_CONFIG_DIR/skills/survey-history/scripts/keyword-only-mode.sh"` and follow the procedure it outputs.
    After writing the artifact (Step SH-6), stop. Do NOT invoke make-outline-plan.

SH-4. Run the following three investigations in parallel:

   a. **Git log since issue opened:**
      `git log --since=<openedAt> --pretty=format:"%h %ad %s" --date=short`

   b. Run `bash "$AGENTS_CONFIG_DIR/skills/survey-history/scripts/history-docs-search.sh" --since <openedAt>` and follow the procedure it outputs.

   c. **Merged PRs since issue opened:**
      `gh pr list --state merged --search "merged:>=<openedAt>" --limit 20 --json number,title,mergedAt`
      On gh failure: record "gh pr list unavailable" and continue.

SH-5. **Relevance scoring:**
   Extract keywords from intent.md Background/Motivation and Scope (≥4 characters,
   excluding stop words: the, and, for, with, that, this, from, into, have, been).
   Score each commit/PR subject by keyword match count.
   Keep: score ≥ 1 entries, plus the top 5 by score regardless of threshold.

SH-6. Run `bash "$AGENTS_CONFIG_DIR/skills/survey-history/scripts/artifact-template.sh"` to get the output format,
   then write `<PLANS_DIR>/<session-id>-survey-history.md` following that format.
   The `## Candidate class members` section lists sibling members identified
   from git history and history.md (per `rules/core-principles.md` CPR-4 Elevate
   Perspective). Each member is two lines: (a) name + description + commit/history-entry reference;
   (b) `proposed triage:` value and 1-line rationale grounded in historical evidence.
   Triage values: `proposed triage: MUST` (symmetric change required for class
   consistency), `proposed triage: OPTIONAL` (related but independently fixable),
   `proposed triage: NA` (orthogonal sibling, no fix needed). When uncertain,
   propose `OPTIONAL`. If no candidates are detected, write `- (none detected)`.
   This section is required even in DEGRADED MODE or keyword-only mode.

   If gh was unavailable, note it at the top of the file under a `## Data gaps` section.

## Rules

- Read project source files only — do not modify them. Writing the output artifact
  to `<PLANS_DIR>/<session-id>-survey-history.md` is required and allowed.
- Do NOT emit the research-complete sentinel — `make-outline-plan` MOP-0 aggregates
  both survey-code and survey-history before emitting it
- Do NOT emit premise-fail or premise-ack sentinels — these are emitted exclusively
  by the `make-outline-plan` orchestrator
- When invoked as a subagent, do NOT emit `WORKFLOW_RESEARCH_NOT_NEEDED` — the orchestrator handles it
- gh CLI failures are non-fatal: log them in the artifact and continue

## Completion

## Skip conditions

- `closes_issues` absent or empty and no context.md → emit `WORKFLOW_RESEARCH_NOT_NEEDED`
- No issue number available → use keyword-only mode (Step SH-3); do NOT skip entirely
- docs-only or typo task with no behavioral claims → emit
  `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: docs-only task — history check not applicable>>"`
