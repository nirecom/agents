---
name: survey-history
description: Investigate git history, docs/history.md, and GitHub issue/PR timeline since the relevant issue opened, to surface changes that may invalidate the issue's premises.
model: sonnet
---

Investigate the project's git history and GitHub issue/PR timeline to detect changes
made after the relevant issue was opened that might invalidate its premises.

## Procedure

### Step 0 — Resolve <PLANS_DIR>

Before any tool call below that references <PLANS_DIR>, run the following Bash command exactly once:

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
printf 'PLANS_DIR=%s\n' "$PLANS_DIR"
```

Capture the printed absolute path and substitute it for every <PLANS_DIR>
placeholder in the remainder of this SKILL.md. Subagent prompts must receive
the resolved absolute path as a literal string (subagents cannot expand $VAR).
Reuse across all subsequent steps in this skill invocation — do not re-resolve.

When invoked as a parallel Agent subagent by workflow-init, the orchestrator
passes `artifact_path` and `context_path` as resolved absolute strings — use
those instead of running Step 0.

Canonical documentation: skills/_shared/resolve-plans-dir.md.

1. **Input and issue number resolution:**
   Input precedence (read whichever exists first):
     (a) `<PLANS_DIR>/<session-id>-intent.md` — preferred (post-clarify-intent calls)
     (b) `<PLANS_DIR>/<session-id>-context.md` — fallback (pre-clarify-intent calls
         from workflow-init)
   Issue number N:
   - From intent.md: extract from `## closes_issues` section (existing behavior).
   - From context.md: read `issue-number` from `## Session metadata`.
   - If N is `(none)`, absent, or non-integer → proceed in **keyword-only mode** (Step 2.5).

2.5 **Keyword-only mode** (no issue number available):
    Output header MUST include: `**DEGRADED MODE** — no issue context; results are best-effort`
    - Skip Step 2 (gh issue view) — no issue = no reliable issue data.
    - Skip `gh pr list` — no issue context means PR filter is unreliable.
    - Use `--since='1 year ago'` for git log scope (avoids unbounded history scan).
    - Source keywords from context.md `## Keywords` section if present;
      otherwise extract from `## User initial prompt` inline (≥4 chars, stop-words excluded).
    - Run Step 3a and 3b only (git log + history docs); skip Step 3c (gh pr list).
    - All claims produced in this mode get `verdict: indeterminate`
      (never `holds` or `contradicted` — insufficient evidence without issue context).
    - Rationale: without issue context, gh pr list has no filter; git log needs a date cap;
      verdicts require traceable evidence.
    After writing the artifact (Step 5), stop. Do NOT invoke make-outline-plan.

2. Run: `gh issue view <N> --json createdAt --jq .createdAt`
   - On success: record `openedAt` (ISO-8601 date string).
   - On failure (gh unavailable, auth error, etc.): record "gh unavailable — using
     approximate date" and continue; set `openedAt` to 90 days ago as a conservative fallback.

3. Run the following three investigations in parallel:

   a. **Git log since issue opened:**
      `git log --since=<openedAt> --pretty=format:"%h %ad %s" --date=short`

   b. **History docs entries since issue opened** (follow progressive disclosure per `rules/file-investigation.md`):
      - Grep `docs/history.md` for date strings ≥ openedAt (format `YYYY-MM-DD`).
        Read the surrounding context (±5 lines) for each match.
      - If `docs/history/index.md` exists, grep it for the same date range to find archived
        entries. For each matching archive file listed in the index, read the relevant
        section of that file (e.g. `docs/history/2025-*.md`) to retrieve the full entry.

   c. **Merged PRs since issue opened:**
      `gh pr list --state merged --search "merged:>=<openedAt>" --limit 20 --json number,title,mergedAt`
      On gh failure: record "gh pr list unavailable" and continue.

4. **Relevance scoring:**
   Extract keywords from intent.md Background/Motivation and Scope (≥4 characters,
   excluding stop words: the, and, for, with, that, this, from, into, have, been).
   Score each commit/PR subject by keyword match count.
   Keep: score ≥ 1 entries, plus the top 5 by score regardless of threshold.

5. Write `<PLANS_DIR>/<session-id>-survey-history.md`:
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
  to `<PLANS_DIR>/<session-id>-survey-history.md` is required and allowed.
- Do NOT emit the research-complete sentinel — `make-outline-plan` Step 0 aggregates
  both survey-code and survey-history before emitting it
- Do NOT emit premise-fail or premise-ack sentinels — these are emitted exclusively
  by the `make-outline-plan` orchestrator
- When invoked as a subagent, do NOT emit `WORKFLOW_RESEARCH_NOT_NEEDED` — the orchestrator handles it
- gh CLI failures are non-fatal: log them in the artifact and continue

## Completion

After completing this skill:
1. Invoke `make-outline-plan` via the Skill tool.
   Note: when invoked as a parallel Agent subagent by workflow-init, skip this step —
   Do NOT invoke make-outline-plan. workflow-init orchestrates the next stage.

## Skip conditions

- `closes_issues` absent or empty and no context.md → emit `WORKFLOW_RESEARCH_NOT_NEEDED`
- No issue number available → use keyword-only mode (Step 2.5); do NOT skip entirely
- docs-only or typo task with no behavioral claims → emit
  `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: docs-only task — history check not applicable>>"`
