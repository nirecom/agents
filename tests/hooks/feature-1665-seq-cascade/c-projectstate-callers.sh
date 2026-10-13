#!/bin/bash
# tests/hooks/feature-1665-seq-cascade/c-projectstate-callers.sh
# Tests: hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io.js
# Tags: workflow-state, updated-seq, call-site-inventory, drift-detection, scope:issue-specific, pwsh-not-required, TL1
# C — projectState() call-site inventory pin (TL1 drift detector): C1-C4 grep,
# C5/C6 lexical scanner (projectstate-callsites.js), C7 mutation battery.
# TL3 gap: dynamic calls, values beyond a one-hop declaration, persistence
# round-trips; mitigation: feature-1733-state-event-stream/projection-contract.sh.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CASE_TAG=c
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

SCANNER="$SCRIPT_CHECKOUT_ROOT_N/tests/hooks/feature-1665-seq-cascade/projectstate-callsites.js"

cd "$SCRIPT_CHECKOUT_ROOT" || { fail "C: cannot enter repo"; finish; exit; }

# Per-file call counts, excluding the definition line itself.
GOT="$(grep -rn "projectState(" hooks bin --include=*.js 2>/dev/null \
    | grep -v "function projectState(" \
    | grep -v "projectState: projection.projectState" \
    | cut -d: -f1 | sort | uniq -c | awk '{print $2 ":" $1}' | sort)"

WANT="hooks/workflow-state/state-io/core.js:1
hooks/workflow-state/state-io/events.js:3
hooks/workflow-state/state-io/migrations/v2-to-v3.js:1
hooks/workflow-state/state-io/migrations/v3-to-v4.js:1
hooks/workflow-state/state-io/migrations/v4-to-v5.js:1
hooks/workflow-state/state-io/projection.js:1"

# Every .js under hooks/ or bin/ that so much as mentions the symbol -- the
# scanner's input set must be a SUPERSET of grep's, or C5 could agree vacuously.
SRC_FILES="$(grep -rl "projectState" hooks bin --include=*.js 2>/dev/null | sort)"

cd "$TMPROOT" || true

if [ "$GOT" = "$WANT" ]; then
    pass "C1 projectState() call-site inventory unchanged"
else
    fail "C1 projectState() call-site inventory drifted -- want:
$WANT
got:
$GOT"
fi

TOTAL="$(printf '%s\n' "$GOT" | awk -F: '{s+=$2} END {print s+0}')"
assert_eq "C2 total non-definition call sites" "8" "$TOTAL"

REEXPORT="$(grep -c "projectState: projection.projectState" "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io.js")"
assert_eq "C3 state-io.js re-exports projectState exactly once" "1" "$REEXPORT"

# No caller may hand the PROJECTOR a filtered / sliced stream. Only the text
# after `projectState(` is inspected, so a defensive `.slice()` on a different
# argument of the same line (events.js:168 passes a copy of the stream to the
# BUILDER) is correctly not counted.
FILTERED="$(grep -rn "projectState(" "$SCRIPT_CHECKOUT_ROOT/hooks" "$SCRIPT_CHECKOUT_ROOT/bin" --include=*.js 2>/dev/null \
    | grep -v "function projectState(" \
    | sed 's/.*projectState(//' \
    | grep -cE "\.filter\(|\.slice\(")"
assert_eq "C4 no call site folds a filtered/sliced subsequence" "0" "$FILTERED"

# --- C5/C6: the same inventory, recomputed lexically -------------------------
# scan <file...> -- run the scanner; stdout in SCAN_OUT, exit code in SCAN_RC.
SCAN_OUT=""; SCAN_RC=0
scan() {
    SCAN_RC=0
    SCAN_OUT="$("$RWT" 120 node "$SCANNER" "$@" 2>&1)" || SCAN_RC=$?
}

SCAN_ARGS=""
for f in $SRC_FILES; do SCAN_ARGS="$SCAN_ARGS $SCRIPT_CHECKOUT_ROOT_N/$f"; done
# shellcheck disable=SC2086
scan $SCAN_ARGS

if [ "$SCAN_RC" -ne 0 ]; then
    fail "C5 scanner failed to run (rc=$SCAN_RC): $SCAN_OUT"
    fail "C6 scanner total unavailable (C5 did not run)"
else
    SCAN_INV="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="COUNT"{print $2 ":" $3}' \
        | sed "s#^$SCRIPT_CHECKOUT_ROOT_N/##" | sort)"
    assert_eq "C5 scanner inventory agrees with the grep inventory" "$WANT" "$SCAN_INV"

    SCAN_TOTAL="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="TOTAL"{print $2}')"
    SCAN_FILT="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="FILTERED"{print $2}')"
    assert_eq "C6a scanner total non-definition call sites" "8" "$SCAN_TOTAL"
    assert_eq "C6b scanner sees no folded subsequence at any call site" "0" "$SCAN_FILT"
fi

# --- C7: mutation battery (table-driven) -------------------------------------
# Each row plants ONE mutation into a throwaway fixture and asserts the scanner's
# verdict. Rows marked `grep-blind` in the name are exactly the mutations that
# C1/C4 cannot see; they are the reason the scanner exists.
FIXDIR="$TMPROOT/mut"
mkdir -p "$FIXDIR"
MUT_N=0

while IFS='|' read -r name src want_calls want_filtered; do
    case "$name" in ''|'#'*) continue;; esac
    name="$(printf '%s' "$name" | sed 's/^ *//; s/ *$//')"
    want_calls="$(printf '%s' "$want_calls" | tr -d ' ')"
    want_filtered="$(printf '%s' "$want_filtered" | tr -d ' ')"
    MUT_N=$((MUT_N + 1))
    fx="$FIXDIR/m$MUT_N.js"
    printf '%b\n' "$src" > "$fx"
    scan "$(nrm "$fx")"
    if [ "$SCAN_RC" -ne 0 ]; then
        fail "C7 $name -- scanner rc=$SCAN_RC: $SCAN_OUT"
        continue
    fi
    got_calls="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="TOTAL"{print $2}')"
    got_filtered="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="FILTERED"{print $2}')"
    assert_eq "C7 $name calls" "$want_calls" "$got_calls"
    assert_eq "C7 $name filtered" "$want_filtered" "$got_filtered"
done <<'TABLE'
plain-call                 | const projection = require("./p");\nprojection.projectState(events);                    | 1 | 0
alias-call-grep-blind      | const p = projection.projectState;\np(events);                                          | 1 | 0
alias-filtered-grep-blind  | const p = projection.projectState;\np(events.filter(Boolean));                          | 1 | 1
destructured-alias         | const { projectState: pj } = require("./p");\npj(events);                                | 1 | 0
reassigned-alias           | let q;\nq = projection.projectState;\nq(events.slice(1));                                | 1 | 1
multiline-filtered-grep-blind | projectState(\n    events.filter(Boolean)\n);                                          | 1 | 1
prefiltered-var-grep-blind | const sub = events.slice(0, 3);\nprojectState(sub);                                      | 1 | 1
prefiltered-var-clean      | const sub = events;\nprojectState(sub);                                                   | 1 | 0
builder-slice-second-arg   | projectState(state, build(events.slice()));                                              | 1 | 0
comment-decoy              | // projectState(events.filter(f))\nprojectState(events);                                  | 1 | 0
string-decoy               | const s = "projectState(x.filter(y))";\nprojectState(events);                            | 1 | 0
definition-is-not-a-call   | function projectState(state) {\n    return state;\n}                                      | 0 | 0
TABLE

assert_eq "C7 mutation table executed every row" "12" "$MUT_N"

finish
