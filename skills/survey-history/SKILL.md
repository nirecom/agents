---
name: survey-history
description: Investigate git history, docs/history.md, and GitHub issue/PR timeline since the relevant issue opened, to surface changes that may invalidate the issue's premises.
model: sonnet
---

Investigate the project's git history and GitHub issue/PR timeline to detect changes
made after the relevant issue was opened that might invalidate its premises.

## Procedure

1. Read `~/.workflow-plans/<session-id>-intent.md`. Extract the issue number N from
   the `## closes_issues` section.
   - If the section is absent, reads `(empty)`, or contains no integer: emit
     `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: no issue number in closes_issues — history check skipped>>"` and stop.

2. Run: `gh issue view <N> --json createdAt --jq .createdAt`
   - On success: record `openedAt` (ISO-8601 date string).
   - On failure (gh unavailable, auth error, etc.): record "gh unavailable — using
     approximate date" and continue; set `openedAt` to 90 days ago as a conservative fallback.

3. Run the following three investigations in parallel:

   a. **Git log since issue opened:**
      `git log --since=<openedAt> --pretty=format:"%h %ad %s" --date=short`

   b. **docs/history.md entries since issue opened:**
      Grep `docs/history.md` for date strings ≥ openedAt (format `YYYY-MM-DD`).
      Read the surrounding context (±5 lines) for each match.

   c. **Merged PRs since issue opened:**
      `gh pr list --state merged --search "merged:>=<openedAt>" --limit 20 --json number,title,mergedAt`
      On gh failure: record "gh pr list unavailable" and continue.

4. **Relevance scoring:**
   Extract keywords from intent.md Background/Motivation and Scope (≥4 characters,
   excluding stop words: the, and, for, with, that, this, from, into, have, been).
   Score each commit/PR subject by keyword match count.
   Keep: score ≥ 1 entries, plus the top 5 by score regardless of threshold.

5. Write `~/.workflow-plans/<session-id>-survey-history.md`:
   ```
   ## Survey history — changes since issue #<N> opened (<openedAt>)

   ## Verified Claims
   - claim: <text from intent.md Background/Scope>
     verdict: holds | contradicted | indeterminate
     evidence: <commit hash / PR# / history entry, or "no matching history found">

   ## Premise impact assessment
   <one paragraph: describe contradictions found, or state "No premise contradictions detected.">
   ```
   If gh was unavailable, note it at the top of the file under a `## Data gaps` section.

## Rules

- Read project source files only — do not modify them. Writing the output artifact
  to `~/.workflow-plans/<session-id>-survey-history.md` is required and allowed.
- Do NOT emit the research-complete sentinel — `make-outline-plan` Step 0 aggregates
  both survey-code and survey-history before emitting it
- Do NOT emit premise-fail or premise-ack sentinels — these are emitted exclusively
  by the `make-outline-plan` orchestrator
- When invoked as a subagent (from agents/survey-history.md), do NOT emit any
  `WORKFLOW_RESEARCH_NOT_NEEDED` sentinel either — the invoking orchestrator handles it
- gh CLI failures are non-fatal: log them in the artifact and continue

## Completion

After completing this skill:
1. Invoke `make-outline-plan` via the Skill tool.

## Skip conditions

- `closes_issues` absent or empty → emit `WORKFLOW_RESEARCH_NOT_NEEDED` (see Step 1)
- docs-only or typo task with no behavioral claims → emit
  `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: docs-only task — history check not applicable>>"`
