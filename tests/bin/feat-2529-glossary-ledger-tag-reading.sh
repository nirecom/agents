#!/usr/bin/env bash
# tests/bin/feat-2529-glossary-ledger-tag-reading.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger/drift-tag.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/finalize.sh, hooks/workflow-state/glossary-check/scope.js, skills/_shared/glossary-drift-check.md
# Tags: TL1, TL2, concern-ledger, glossary, glossary-drift, ledger-tag, issue-2529, scope:issue-specific, pwsh-not-required
# #2529 T8-8..15 except T8-11: how the tag is read — list-drift, untagged mentions, grammar,
# the format-to-stage map, parsers, prompt directives, after ESCALATE. Split from
# feat-2529-glossary-ledger-tag.sh (which keeps T8-11) on the time budget.
# TL3 gap (what this test does NOT catch):
# - a live reviewer/planner emitting the tag.
# Closest-to-action mitigation: static-directives pins the prompt text that asks for it.
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

# T8-8: list-drift names the open/reopened tagged concerns, nothing else.
case_begin "list-drift-lists-open-tagged" "bin/concern-ledger"
. "$LT_PARTS/list-drift.sh"
case_end

# T8-9: text that only mentions the words is not tagged.
case_begin "untagged-mention-keeps-reject" "bin/lib/concern-ledger/drift-tag.sh"
. "$LT_PARTS/residual.sh"
case_end

# T8-10: the tag grammar table.
case_begin "tag-grammar" "bin/lib/concern-ledger/drift-tag.sh"
. "$LT_PARTS/tag-grammar.sh"
case_end

# T8-12: one format-to-stage map, and the grant reader honors it.
case_begin "format-stage-names" "hooks/workflow-state/glossary-check/scope.js"
. "$LT_PARTS/format-names.sh"
case_end

# T8-13: the tag survives each parser wherever it sits in the text.
case_begin "tag-survives-parsers" "bin/lib/concern-ledger/parse.sh"
. "$LT_PARTS/parse-position.sh"
case_end

# T8-14: the prompt directives that make planners and reviewers use the tag.
case_begin "prompt-directives" "skills/_shared/glossary-drift-check.md"
. "$LT_PARTS/static-directives.sh"
case_end

# T8-15: after ESCALATE removes the ledger, the tag still rides the JSON.
case_begin "tag-after-escalate" "bin/lib/concern-ledger/finalize.sh"
. "$LT_PARTS/after-escalate.sh"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
