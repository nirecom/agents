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
To skip the detail stage entirely, run:
  echo "<<WORKFLOW_DETAIL_NOT_NEEDED: <reason>>>"
Use only when outline already provides file-level clarity (typo fix, one-line config tweak, or outline enumerated exact file edits).
Reason must be >=3 non-space chars, not a placeholder, and contain no '>'.
Skipping research does NOT justify skipping this stage.
TEMPLATE
