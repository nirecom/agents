#!/usr/bin/env bash
# tests/bin/feat-2529-glossary-ledger-tag.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger/drift-tag.sh, bin/check-glossary-ledger-grant, hooks/workflow-mark/glossary-accept-handler.js, bin/check-glossary-drift
# Tags: TL1, TL2, concern-ledger, glossary, glossary-drift, ledger-tag, issue-2529, scope:issue-specific, pwsh-not-required
# #2529 T8-1..4 (plan formats) + T8-11: a [glossary-drift …] concern is never rejected; only accept
# bound to a WORKFLOW_GLOSSARY_ACCEPTED grant closes it. Split on the time budget:
# -core-review.sh (review formats), -grant.sh (T8-5..7), -reading.sh (T8-8..15 but T8-11).
# TL3 gap (what this test does NOT catch):
# - a live reviewer/planner emitting the tag and a live user typing the sentinel.
# Closest-to-action mitigation: core-four-formats drives the real workflow-mark.js hook.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
LT_ROOT="$(make_tmp)"
readonly LT_ROOT
trap 'rm -rf "$LT_ROOT"' EXIT
harness_isolate "$LT_ROOT/iso"
mkdir -p "$LT_ROOT/transcripts" "$LT_ROOT/proj"
export CLAUDE_TRANSCRIPT_BASE_DIR="$LT_ROOT/transcripts"
harness_git_init "$LT_ROOT/proj"
export CLAUDE_PROJECT_DIR="$LT_ROOT/proj"
unset CLAUDE_CODE_SESSION_ID
cd "$LT_ROOT" || exit 1

LT_PARTS="$SCRIPT_CHECKOUT_ROOT/tests/bin/feat-2529-glossary-ledger-tag"
. "$LT_PARTS/common.sh"

# T8-1..4: reject refused, accept without a grant refused, accept with a grant
# (seeded, then through the real sentinel) closes it, untagged keeps reject.
case_begin "tagged-concern-plan-formats" "bin/concern-ledger"
LT_CORE_FORMATS="$LT_CORE_PLAN_FORMATS"
. "$LT_PARTS/core-four-formats.sh"
case_end

# T8-11: stages without a ledger (intent, docs) are untouched by the ledger path.
case_begin "ledgerless-stages-unchanged" "bin/check-glossary-drift"
. "$LT_PARTS/no-ledger.sh"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
