#!/bin/bash
# tests/feature-2064-enforce-worktree-js-innercommandiswrite.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/lib/bash-write-targets/exotic-exec.js, hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/dispatch-provenance.js, hooks/enforce-worktree/write-detector.js, hooks/enforce-worktree/bash-write-scope/segment-checks.js
# Tags: worktree, enforce, hook, write-detector, dispatch-provenance, newline-injection, command-substitution, exotic-exec, heredoc, classifier, table-driven, scope:issue-specific
#
# #2064 — innerCommandIsWrite loses dispatch provenance. isNewlineInjectedWriteIR
# feeds it a stripped/folded fragment, not physical lines: DQ spans are blanked
# (the dispatcher path token becomes `bash ""`, so the known-dispatch exception is
# unreachable) and a TRUNCATED `cat <<'EOF'` opener survives with no body, which
# isSafeHeredocOnly cannot clear. The fix threads {dispatchCleared:true} from the
# intact top-level ir into the fragment re-parse.
set -u

# Entrypoint only (rules/coding/file-split.md Pattern A): shared setup, EVAL_JS
# assembly and the result tally. Cases live in the sibling folder of the same name.

# TL3 gap (what this test does NOT catch):
# - a real Claude Code session where enforce-worktree.js runs as a PreToolUse hook
#   and the user's actual /issue-create dispatch is allowed or blocked
# - hook registration / payload plumbing end-to-end through the real host process
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_NODE_DIR="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_NODE_DIR="$AGENTS_DIR"
fi
export AGENTS_NODE_DIR

PASS=0
FAIL=0
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

# Portable timeout wrapper (macOS has no `timeout`). `secs` is captured BEFORE the
# shift so the perl fallback alarms on the timeout rather than on argv[0], and the
# post-shift "$@" is the whole command line rather than a truncated one.
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

SUITE_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-2064-enforce-worktree-js-innercommandiswrite"

# Single node evaluator, assembled from five chunks that share one lexical scope
# and must stay in this order. argv: <predicate> <fixture-id>. Fixtures are
# literal in-file (no JSON dependency). A not-yet-existing module or export prints
# MODULE-MISSING / EXPORT-MISSING, so an unimplemented fix yields a diagnostic
# FAIL rather than an abort.
# shellcheck source=./feature-2064-enforce-worktree-js-innercommandiswrite/fixtures-core.js.sh
. "$SUITE_DIR/fixtures-core.js.sh"
# shellcheck source=./feature-2064-enforce-worktree-js-innercommandiswrite/fixtures-extended.js.sh
. "$SUITE_DIR/fixtures-extended.js.sh"
# shellcheck source=./feature-2064-enforce-worktree-js-innercommandiswrite/fixtures-regression.js.sh
. "$SUITE_DIR/fixtures-regression.js.sh"
# shellcheck source=./feature-2064-enforce-worktree-js-innercommandiswrite/fixtures-round4.js.sh
. "$SUITE_DIR/fixtures-round4.js.sh"
# shellcheck source=./feature-2064-enforce-worktree-js-innercommandiswrite/predicates.js.sh
. "$SUITE_DIR/predicates.js.sh"

EVAL_JS="$JS_FIXTURES_CORE
$JS_FIXTURES_EXT
$JS_FIXTURES_REGRESSION
$JS_FIXTURES_ROUND4
$JS_PREDICATES"

ev() { run_with_timeout 30 node -e "$EVAL_JS" -- "$1" "$2" 2>&1 | tail -1; }

table() {
    while IFS='|' read -r name pred id want; do
        [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="$(echo "$name" | sed 's/^ *//; s/ *$//')"
        pred="${pred//[[:space:]]/}"
        id="${id//[[:space:]]/}"; want="${want//[[:space:]]/}"
        assert_eq "$name ($pred:$id)" "$want" "$(ev "$pred" "$id")"
    done
}

# shellcheck source=./feature-2064-enforce-worktree-js-innercommandiswrite/cases-direct.sh
. "$SUITE_DIR/cases-direct.sh"
# shellcheck source=./feature-2064-enforce-worktree-js-innercommandiswrite/cases-newline-injection.sh
. "$SUITE_DIR/cases-newline-injection.sh"
# shellcheck source=./feature-2064-enforce-worktree-js-innercommandiswrite/cases-shape-variants.sh
. "$SUITE_DIR/cases-shape-variants.sh"
# shellcheck source=./feature-2064-enforce-worktree-js-innercommandiswrite/cases-provenance-scope.sh
. "$SUITE_DIR/cases-provenance-scope.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
