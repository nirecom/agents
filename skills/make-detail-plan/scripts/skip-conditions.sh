#!/bin/bash
# Skip Conditions for make-detail-plan — evaluates whether the discussion loop
# and/or the detail stage itself should be skipped.
set -euo pipefail
cat <<'TEMPLATE'
## Skip Conditions (discussion loop)
Skip the planner/reviewer loop when BOTH:
- The task is a single-file change
- No design decision is needed
Then skip judge-task-complexity and draft the plan directly.

## Skipping This Stage (no detail plan)

PRIMARY signal: when a skip_judgment record (all 3 conditions true) was recorded
at make-outline-plan MOP-C1 or clarify-intent CI-C1b, gate-plan-skip-sentinel.js
auto-approves the DETAIL_NOT_NEEDED sentinel and next-step marks detail as skipped,
so this stage does not launch.

FALLBACK (no pre-flight record): when outline.md provides file-level clarity, the
<<WORKFLOW_DETAIL_NOT_NEEDED: {reason}>> sentinel may be used manually.
  - Reason must be >=3 non-space chars, not a placeholder, and contain no '>'.
  - Use only when outline enumerated exact file edits (typo fix, one-line config tweak).
  - Research is NOT a valid skip reason for this stage.
TEMPLATE
