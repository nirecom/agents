#!/usr/bin/env bash
# tests/bin/bin-concern-ledger-input-validation.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, input-validation, path-traversal, injection, quoting, table-driven, scope:common, pwsh-not-required
#
# Session ID, format and producer are interpolated into ledger paths, so the path
# builders are an injection surface. Two opposite failures, separated (CPR-SC):
# traversal (writing somewhere it should not) and a lost round (writing nowhere
# while reporting success). TL2: the real CLI over a throwaway sandbox.
set -uo pipefail

# TL3 gap (mitigation category: skill-orchestration): the values real skills pass
# (session ID from state, format from a SKILL.md literal) are not exercised here.
# Mitigation: the producer names are a closed set pinned by case 6.

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$AGENTS_ROOT/bin/concern-ledger"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"

PASS=0
FAIL=0

# Known-gap assertions (cases 3/4/5). Sourced after FAIL exists, which the
# helpers increment on an XPASS. See tests/lib/xfail.sh for the contract.
# shellcheck source=./lib/xfail.sh
. "$AGENTS_ROOT/tests/lib/xfail.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

# assert_eq with a guard: an expectation that could not be computed is itself a
# failure, so '' == '' can never pass while the implementation is absent.
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — the expected value could not be computed (empty)"
        FAIL=$((FAIL + 1))
        return
    fi
    assert_eq "$name" "$want" "$got"
}

# ---------------------------------------------------------------------------
# Fixture isolation (rules/test/fixture-isolation.md).
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"

# A neutral CWD that is also the canary directory: anything a metacharacter
# manages to execute has to leave its droppings somewhere, and this is the
# likeliest place.
CWD="$TMPDIR_BASE/cwd"
mkdir -p "$CWD"
cd "$CWD" || exit 1

REPORT="$TMPDIR_BASE/report.txt"
{
    printf '# Report\n\n## Review: PERFORMED\n\n## Concern Delta\n'
    printf -- '- [HIGH] - | a/b.sh#fn | correctness | the concern that must not be lost\n'
    printf '\n'
} > "$REPORT"

CONCERN_TEXT="the concern that must not be lost"

# ---------------------------------------------------------------------------
# Sandbox. Each probe gets its own root so a traversal from one case cannot be
# mistaken for a file another case wrote.
#   <root>/plans   — the --plans-dir handed to the CLI
#   <root>/wf      — CLAUDE_WORKFLOW_DIR; control files land in <sid>.control (#2434)
#   <root>/        — where a single '..' lands
# ---------------------------------------------------------------------------
BOX_SEQ=0
BOX=""
PLANS=""
WF=""
new_box() {
    BOX_SEQ=$((BOX_SEQ + 1))
    BOX="$TMPDIR_BASE/box-$BOX_SEQ"
    PLANS="$BOX/plans"
    WF="$BOX/wf"
    export CLAUDE_WORKFLOW_DIR="$WF"
    mkdir -p "$PLANS" "$WF"
}

# stage_with <session-id> <format> <producer> — run the real CLI, echo its rc.
stage_with() {
    local rc=0
    bash "$CLI" stage --plans-dir "$PLANS" --session-id "$1" --format "$2" \
        --round 1 --producer "$3" --from-report "$REPORT" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# landed — where the round's bytes ended up, described rather than named:
# 'in-control-dir', 'outside', or 'nowhere'. A count, not a path, so a case
# cannot pass by matching a filename it also constructed.
landed() {
    local n_in n_out
    n_in="$(find "$WF" -mindepth 2 -type f -path "$WF/*.control/*" -name '*delta*' 2>/dev/null | wc -l | tr -d ' ')"
    n_out="$(find "$BOX" -type f -name '*delta*' -not -path "$WF/*.control/*" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$n_out" -gt 0 ]; then printf 'outside'; return; fi
    if [ "$n_in" -gt 0 ]; then printf 'in-control-dir'; return; fi
    printf 'nowhere'
}

# holds_concern — 'yes' when some staged file under the box carries the concern.
holds_concern() {
    if grep -rlF -- "$CONCERN_TEXT" "$BOX" >/dev/null 2>&1; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# canaries — anything a metacharacter executed would have created.
canaries() {
    local n
    n="$(find "$CWD" "$TMPDIR_BASE" -maxdepth 2 -name 'PWNED*' 2>/dev/null | wc -l | tr -d ' ')"
    printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# Implementation presence. A FAILURE, never a silent skip.
# ---------------------------------------------------------------------------
for _f in "$CLI" "$LIB"; do
    if [ ! -f "$_f" ]; then
        echo "SKIP-BLOCKED: ${_f#"$AGENTS_ROOT/"} not implemented yet"
        fail "implementation missing: ${_f#"$AGENTS_ROOT/"} (every case below fails for this reason)"
    fi
done

# ---------------------------------------------------------------------------
# Cases. Split into a sibling folder per rules/coding/file-split.md Pattern A;
# each file is sourced, not executed, so it shares the fixture and helpers
# above. Order is the case numbering: 1-2, 3, then 4-6.
# ---------------------------------------------------------------------------
SUITE_DIR="$AGENTS_ROOT/tests/bin/bin-concern-ledger-input-validation"

# shellcheck source=./bin-concern-ledger-input-validation/domain-and-metachars.sh
. "$SUITE_DIR/domain-and-metachars.sh"
# shellcheck source=./bin-concern-ledger-input-validation/traversal.sh
. "$SUITE_DIR/traversal.sh"
# shellcheck source=./bin-concern-ledger-input-validation/format-and-producer.sh
. "$SUITE_DIR/format-and-producer.sh"

xfail_summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
