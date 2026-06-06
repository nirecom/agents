#!/bin/bash
# Emit the NEEDS_RESEARCH re-prompt template for make-detail-plan.
# Usage: called by orchestrator to build re-prompt body.
set -euo pipefail
cat <<'TEMPLATE'
Research complete.
Findings: <verbatim research output>

Original task: <original task prompt>
Pending reviewer concerns (if any — empty on initial-draft turn): <forward verbatim or "(none)">

Incorporate findings under "## Research Findings (from this session)" and cite with [research: tag].
Now produce the full plan.
TEMPLATE
