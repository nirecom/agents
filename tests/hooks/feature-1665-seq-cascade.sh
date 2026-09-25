#!/bin/bash
# tests/feature-1665-seq-cascade.sh
# Tests: hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/effective-state.js, hooks/workflow-state/effective-state/write-code-resume.js, hooks/workflow-state/lifecycle.js, hooks/lib/stop-exemption-policy.js
# Tags: workflow-state, updated-seq, causal-order, write-code-resume, cascade, stop-guard, scope:issue-specific, pwsh-not-required, TL1, TL2
#
# #1665 commit 3 — the causal-ordering axis (`updated_seq`) and the write-code
# resume cascade built on top of it.
#
# WHY seq and not wall-clock: `at` / `updated_at` is not a usable ordering axis.
# A measured stream carried 83 events across only 19 distinct `at` values, with a
# single batch stamping 29 events identically. Only `seq` totally orders the
# stream, so "was this step settled before or after the failing run_tests?" is a
# seq question.
#
# Dispatcher only — cases live in tests/feature-1665-seq-cascade/.
#
# TL3 gap (what this test does NOT catch):
# - Whether the Stop hook and the workflow gate are actually REGISTERED in the
#   real settings.json event wiring (cases i/g invoke the hook scripts directly).
# - Real Claude Code session-id propagation into the hook process.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1665-seq-cascade"

CASES="a-updated-seq b-entry-shape-parity c-projectstate-callers d-reserved-annotation e-cascade f-inherited-null-seq g-scope-propagation h-no-writeback i-c4-exemption j-matrix-consumer"

TOTAL_FAIL=0
NODE_MISSING=0

for c in $CASES; do
    echo "== $c =="
    bash "$DIR/$c.sh"
    rc=$?
    case "$rc" in
        0) ;;
        77) NODE_MISSING=1; echo "  (node unavailable)";;
        *) TOTAL_FAIL=$((TOTAL_FAIL + 1));;
    esac
done

if [ "$NODE_MISSING" -eq 1 ] && [ "$TOTAL_FAIL" -eq 0 ]; then
    echo "SKIP: node not available"
    exit 77
fi

if [ "$TOTAL_FAIL" -ne 0 ]; then
    echo "RESULT: $TOTAL_FAIL case file(s) failed"
    exit 1
fi

echo "RESULT: all cases passed"
exit 0
