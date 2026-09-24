#!/bin/bash
# tests/TL3-complexity-stage-routing-live-judge.sh
# Tests: skills/_shared/judge-task-complexity.md, bin/workflow/derive-complexity-level, tests/feature-2099-complexity-stage-routing.sh
# Tags: complexity, routing, judge, live-agent, prompt-injection, threshold, TL3, run-e2e, scope:common
# Serial: drives the #2099 suite, which writes into its own pinned CLAUDE_WORKFLOW_DIR
# RUN_TL3-ON lane for #2099. The suite's live-agent cases (PI-5, JT-*) carry their
# own in-function gate and SKIP on an ordinary run; `bin/select-tests.sh` picks this
# file up for the expensive tier by its `TL3-` prefix, and it forbids those cases to skip.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

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

# Live case ids this lane is accountable for — a vanished id must break this lane,
# not quietly reduce coverage. JT-6..10 are per-signal fixtures; JT-11..14 the
# numeric boundary pairs; E2E-1..4 the full judge->store->reader->model chain
# (twice uniform, twice with disagreeing stages). `[a-z]*` matches sub-labels
# (JT-6a) without letting JT-1 also match JT-10's lines.
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

# ---------------------------------------------------------------------------
# T-LIVE-CJ-1 (#2223 scope 4) — live seam: spawn the opus-fixed complexity-judge
# on a simple intent, capture its raw output, normalize it, and confirm routing
# derives a valid level. Past the top RUN_TL3/claude gates this must not skip.
# ---------------------------------------------------------------------------
unset CLAUDECODE
NORMALIZE_CLI="$AGENTS_DIR/bin/workflow/normalize-judge-signals"
DERIVE_CLI="$AGENTS_DIR/bin/workflow/derive-complexity-level"
RUN_TO="$AGENTS_DIR/bin/run-with-timeout.sh"
if [ ! -f "$NORMALIZE_CLI" ] || [ ! -f "$DERIVE_CLI" ]; then
    fail "T-LIVE-CJ-1 — normalize/derive CLI missing; scope 4 not implemented"
else
    CJ_TMP="$(mktemp -d)"
    CJ_INTENT="$CJ_TMP/intent.md"
    printf '# Intent\n\nAdd a single log line to one existing function.\n' > "$CJ_INTENT"
    CJ_RAW="$CJ_TMP/judge-raw.txt"
    CJ_SIGNALS="$CJ_TMP/signals.txt"
    CJ_PROMPT="Judge the complexity signals for the intent in $CJ_INTENT. Emit only the single SIGNALS: line."
    cj_rc=0
    if [ -x "$RUN_TO" ]; then
        bash "$RUN_TO" 180 claude -p --subagent complexity-judge "$CJ_PROMPT" > "$CJ_RAW" 2>/dev/null || cj_rc=$?
    else
        claude -p --subagent complexity-judge "$CJ_PROMPT" > "$CJ_RAW" 2>/dev/null || cj_rc=$?
    fi
    if [ "$cj_rc" -ne 0 ] || [ ! -s "$CJ_RAW" ]; then
        fail "T-LIVE-CJ-1 — complexity-judge spawn produced no output (rc=$cj_rc)"
    else
        node "$NORMALIZE_CLI" --raw-file "$CJ_RAW" --out "$CJ_SIGNALS" >/dev/null 2>&1 || true
        # C3: a single-log-line, one-file intent has no complexity signals, so the
        # judge must emit `SIGNALS: none` -> empty CSV -> level exactly `low`. A
        # `medium`/`high` here means either the judge over-fired or the pipeline
        # fell through to the S0-undecidable fail-open — both are real regressions,
        # so accepting them (the old low|medium|high match) would be too permissive.
        cj_signals="$(tr -d '[:space:]' < "$CJ_SIGNALS" 2>/dev/null)"
        cj_level="$(node "$DERIVE_CLI" --stage detail --signals-file "$CJ_SIGNALS" 2>/dev/null | tr -d '[:space:]')"
        if [ -z "$cj_signals" ] && [ "$cj_level" = "low" ]; then
            pass "T-LIVE-CJ-1 — trivial intent yielded empty signals and level=low"
        else
            fail "T-LIVE-CJ-1 — expected empty signals + level=low (signals='${cj_signals:-empty}' level='${cj_level:-empty}')"
        fi
    fi
    rm -rf "$CJ_TMP"
fi

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
