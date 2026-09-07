#!/usr/bin/env bash
# tests/feature-2134-command-ir-equivalence.sh
# Tests: hooks/lib/command-ir.js, hooks/lib/command-parser.js, hooks/enforce-worktree/shared-cmd-utils.js, hooks/lib/bash-write-patterns.js, hooks/lib/bash-write-targets.js, docs/architecture/claude-code/shell-command-parsing.md
# Tags: hook, command-ir, equivalence, snapshot, TL1, scope:issue-specific
#
# #2134 Step 1 equivalence-test dispatcher. Step 2 only swaps command-ir.js's
# internal parser for a recursive-descent one and keeps the public contract unchanged, so
# the contract staying inert can only be shown mechanically via a snapshot diff over a fixed
# input set (detail.md Delivery plan #1).

set -uo pipefail

# TL3 gap (what this suite does NOT catch):
# - Whether a hook process that consumes the IR still reaches the same verdict end-to-end
#   (stdin JSON -> hook -> deny/allow): every case here calls the modules in-process.
# - Whether the Step 2 parser swap changes the felt behavior of the hooks that fire in a real session.
# Closest-to-action mitigation: run the existing hook-level test suites (tests/unit-command-ir.sh,
# tests/feature-1293-canary2-ir.sh, tests/feature-2120-workflow-gate-block-heredoc-heredoc/)
# fully green at Step 2, per detail.md S2-9.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$DIR/feature-2134-command-ir-equivalence"
AGENTS_DIR="$(cd "$DIR/.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

# Fixture isolation (rules/test/fixture-isolation.md): pure function calls only, so
# CLAUDE_WORKFLOW_DIR / WORKFLOW_PLANS_DIR pinning is unnecessary, but drop the parent session's id.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

RUNNER="$AGENTS_DIR/bin/run-with-timeout.sh"
OWNERSHIP_DOC="$AGENTS_DIR/docs/architecture/claude-code/shell-command-parsing.md"

# Blocking cases. The Step 1 completion criterion is that all of these are
# "green against the current implementation".
BLOCKING_CASES="snapshot.sh shape-contract.sh consumer-contract.sh"

# Conditional cases. The ownership map and the analysisOf contract are both
# Step 2 deliverables, so red is correct until they land and doesn't count
# toward the run's exit code. Placing the doc auto-promotes this to blocking
# -- a manual "lift the pending state" step would let a forgotten lift become
# a permanent coverage hole (CPR-UNV: give the exception a boundary).
# shape-contract-analysis.sh (formerly shape-contract.sh's s12-s14): mixing it
# into BLOCKING_CASES with the Step-1-pinned s01-s11 would hide a real Step-1
# regression behind an expected Step-2 red (review finding #3), so it rides
# the same pending mechanism as ownership-doc.sh.
CONDITIONAL_CASES="ownership-doc.sh shape-contract-analysis.sh"

RUN=0; GREEN=0; RED=0; SKIPPED=0; PENDING=0

run_case() { # <file> <blocking:yes|no>
    local f="$1" blocking="$2" rc=0
    [ -f "$CASE_DIR/$f" ] || {
        echo "FAIL: dispatcher -- case file is missing: feature-2134-command-ir-equivalence/$f"
        RED=$((RED + 1)); RUN=$((RUN + 1)); return
    }
    RUN=$((RUN + 1))
    echo "--- $f ---"
    bash "$RUNNER" 300 bash "$CASE_DIR/$f"
    rc=$?
    if [ "$rc" -eq 77 ]; then
        echo "SKIP: $f (rc=77)"; SKIPPED=$((SKIPPED + 1))
    elif [ "$rc" -eq 0 ]; then
        echo "GREEN: $f"; GREEN=$((GREEN + 1))
    elif [ "$blocking" = "no" ]; then
        echo "PENDING: $f (rc=$rc) -- expected until docs/architecture/claude-code/shell-command-parsing.md lands in Step 2"
        PENDING=$((PENDING + 1))
    else
        echo "RED: $f (rc=$rc)"; RED=$((RED + 1))
    fi
    echo ""
}

for f in $BLOCKING_CASES; do run_case "$f" yes; done

for f in $CONDITIONAL_CASES; do
    if [ -f "$OWNERSHIP_DOC" ]; then run_case "$f" yes; else run_case "$f" no; fi
done

# Budget for the number of cases run. Guards against a dropped case file or
# an early loop exit reading as "green because 0 cases ran" (run_case counts
# a missing file toward RUN too, so this budget measures only "did the loop
# run to completion").
CASES_EXPECTED=5
if [ "$RUN" != "$CASES_EXPECTED" ]; then
    echo "FAIL: case budget: ran=$RUN expected=$CASES_EXPECTED"
    RED=$((RED + 1))
fi

echo "Total: $GREEN green, $RED red, $PENDING pending, $SKIPPED skipped (of $RUN cases)"
[ "$RED" -eq 0 ]
