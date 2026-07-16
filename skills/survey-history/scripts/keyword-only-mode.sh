#!/usr/bin/env bash
# Keyword-only mode procedure for survey-history (no issue number available).
set -euo pipefail
cat <<'TEMPLATE'
    Output header MUST include: `**DEGRADED MODE** — no issue context; results are best-effort`
    - Skip Step SH-2 (gh issue view) — no issue = no reliable issue data.
    - Skip `gh pr list` — no issue context means PR filter is unreliable.
    - Use `--since='1 year ago'` for git log scope (avoids unbounded history scan).
    - Source keywords from context.md `## Keywords` section if present;
      otherwise extract from `## User initial prompt` inline (≥4 chars, stop-words excluded).
      When initial keyword search returns zero results, extract 3–5 symptom-level tokens from `## User initial prompt` or issue body text (behaviors, affected outputs/artifacts, feature area — including artifact/file names that represent the affected feature) and retry once.
    - Run Step SH-4a and SH-4b only (git log + history docs); skip Step SH-4c (gh pr list).
    - All claims produced in this mode get `verdict: indeterminate`
      (never `holds` or `contradicted` — insufficient evidence without issue context).
    - Rationale: without issue context, gh pr list has no filter; git log needs a date cap;
      verdicts require traceable evidence.
TEMPLATE
