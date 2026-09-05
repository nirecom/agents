#!/usr/bin/env bash
# Tests: hooks/workflow-state/record-step-verdict.js, hooks/workflow-mark.js, hooks/block-subagent-sentinels.js, bin/workflow/lib/next-step/advance-shared.js, hooks/lib/workflow-driver-commands.js
# Tags: tl2, workflow, door-parity, runner, scope:issue-specific, pwsh-not-required

# #2102 door parity: write_tests and research move from the sentinel echo to the
# forward CLI call, so the two doors must agree on evidence, idempotency, provenance,
# the subagent backstop and advance scope. One invariant per sibling (file-split
# Pattern A); this entrypoint dispatches and aggregates only.

set -uo pipefail

SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2102-door-parity"
CASES="evidence-cwd idempotency provenance subagent-guard advance-scope"

RC_ALL=0
FAILED=""
for c in $CASES; do
  echo "########## $c ##########"
  if bash "$SUBDIR/$c.sh"; then :; else
    rc=$?
    if [ "$rc" -eq 77 ]; then echo "SKIPPED: $c"; else RC_ALL=1; FAILED="$FAILED $c"; fi
  fi
  echo ""
done

echo "########## feature-2102-door-parity summary ##########"
if [ "$RC_ALL" -eq 0 ]; then
  echo "All door-parity invariants passed."
else
  echo "Failed invariants:$FAILED"
fi
exit "$RC_ALL"
