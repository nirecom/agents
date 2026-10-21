#!/usr/bin/env bash
# tests/bin/feat-2529-glossary-ledger-tag-grant.sh
# Tests: bin/check-glossary-ledger-grant, bin/lib/concern-ledger/drift-tag.sh, bin/concern-ledger
# Tags: TL1, TL2, concern-ledger, glossary, glossary-drift, ledger-tag, issue-2529, scope:issue-specific, pwsh-not-required
# #2529 T8-5..7: a grant opens exactly the concern it names, every accept failure fails
# closed, and the tag rule has one owner. Split from feat-2529-glossary-ledger-tag.sh on the time budget.
# TL3 gap (what this test does NOT catch):
# - a live user typing the WORKFLOW_GLOSSARY_ACCEPTED sentinel.
# Closest-to-action mitigation: grant-binding seeds the annotation the real handler writes.
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

# T8-5: a grant opens exactly the concern whose norm AND discrim it names, on its stage.
case_begin "grant-binds-norm-discrim-stage" "bin/check-glossary-ledger-grant"
. "$LT_PARTS/grant-binding.sh"
case_end

# T8-6: every failure on the accept path refuses (rc 4) and writes nothing.
case_begin "accept-fails-closed" "bin/lib/concern-ledger/drift-tag.sh"
. "$LT_PARTS/fail-closed.sh"
case_end

# T8-7 (static half; the load half lives in fix-2025-safe-state-path.sh).
case_begin "tag-rule-has-one-owner" "bin/lib/concern-ledger/drift-tag.sh"
. "$LT_PARTS/single-rule.sh"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
