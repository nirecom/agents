#!/bin/bash
# tests/TL3-complexity-stage-routing-live-judge.sh
# Tests: skills/_shared/judge-task-complexity.md, bin/workflow/derive-complexity-level, tests/feature-2099-complexity-stage-routing.sh
# Tags: complexity, routing, judge, live-agent, prompt-injection, threshold, TL3, run-e2e, scope:common
# Serial: drives the #2099 suite, which writes into its own pinned CLAUDE_WORKFLOW_DIR
# The RUN_TL3-ON lane for #2099. The suite's live-agent cases (PI-5 injection
# resistance, JT-* threshold boundaries) each carry their own in-function gate and
# SKIP on an ordinary run, so security-sensitive and boundary behaviour would be
# covered only when a human remembered to flip the flag. `bin/select-tests.sh`
# picks a file up for the expensive tier by its `TL3-` filename prefix at tests/
# depth 1 — this file is that hook, and it forbids those cases to skip.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Standard TL3 gates (rules/test/claude-e2e.md). Past them nothing may skip: the
# live cases below really do spawn `claude -p`, and this lane exists to run them.
[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

SUITE="$AGENTS_DIR/tests/feature-2099-complexity-stage-routing.sh"
[ -f "$SUITE" ] || { echo "FAIL: the #2099 suite is missing at $SUITE"; exit 1; }

ERRORS=0
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# D2099_REQUIRE_LIVE=1 turns the suite's `gated_skip` from SKIP into FAIL, so a
# gate that is somehow still closed here is reported rather than passed over.
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT
RC=0
if [ -x "$AGENTS_DIR/bin/run-with-timeout.sh" ]; then
    D2099_REQUIRE_LIVE=1 bash "$AGENTS_DIR/bin/run-with-timeout.sh" 3600 \
        bash "$SUITE" > "$OUT_FILE" 2>&1 || RC=$?
else
    D2099_REQUIRE_LIVE=1 bash "$SUITE" > "$OUT_FILE" 2>&1 || RC=$?
fi

# The live case ids this lane is accountable for. A live case that vanished from
# the suite must break this lane rather than quietly reduce its coverage.
# JT-6..JT-10 are the per-signal fixtures (S2/S4/S5/S6 and the zero-signal task);
# JT-11..JT-14 the S1/S6 numeric boundary pairs; E2E-1..E2E-4 the whole
# judge -> write point -> store -> reader -> model chain in one session, twice
# uniformly (E2E-1/E2E-2) and twice on a row whose stages disagree (E2E-3/E2E-4).
# `[a-z]*` matches the sub-labels (JT-6a) while keeping JT-1 off JT-10's lines.
for id in PI-5 JT-1 JT-2 JT-3 JT-4 JT-5 JT-6 JT-7 JT-8 JT-9 JT-10 JT-11 JT-12 JT-13 JT-14 E2E-1 E2E-2 E2E-3 E2E-4; do
    if grep -qE "^(PASS|FAIL): $id[a-z]* " "$OUT_FILE"; then
        pass "$id executed in the RUN_TL3-ON lane"
    else
        fail "$id produced no PASS/FAIL line — the lane's mandatory live coverage did not run"
    fi
    if grep -qE "^SKIP: $id[a-z]*[ :]" "$OUT_FILE"; then
        fail "$id SKIPPED inside the RUN_TL3-ON lane — this lane exists to execute it"
    fi
done

if [ "$RC" -eq 0 ]; then
    pass "the #2099 suite is green with every live gate open"
else
    fail "the #2099 suite exited $RC with the live gates open — see the failing lines below"
    grep -E '^FAIL:' "$OUT_FILE" | sed 's/^/    /' || true
fi

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
