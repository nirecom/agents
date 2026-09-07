#!/usr/bin/env bash
# n13-duration-ledger-default-home.sh — with RUN_ALL_CACHE_DIR unset the ledger lands under $HOME.
# Tests: bin/lib/run-all-parallelism.sh, bin/lib/run-all-durations.sh, tests/run-all.sh
# Tags: tests, bin, parallel, ledger, home, TL2, scope:issue-specific
# WHY: every other ledger case pins RUN_ALL_CACHE_DIR, so the default branch of
# run_all_cache_dir — $HOME/.claude/run-all — is the one path the suite never exercises, and it
# is the path every real developer run takes. It is exercised here against an explicit throwaway
# HOME, never the developer's own: the real ~/.claude/run-all is counted before and after and
# must be untouched.
# TL3 gap: a host where $HOME is unset entirely, leaving the "." fallback — mitigated at
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n13-duration-ledger-default-home"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"

dur_missing() {
    [ -f "$DUR_LIB" ] && return 1
    fx_fail "$1 (implementation missing: $DUR_LIB_REL)"
    return 0
}

SEG_RE='^dur\.[0-9]+\.[A-Za-z0-9]{16}\.[0-9]{8}T[0-9]{6}-[0-9]{1,10}\.log$'

REAL_HOME="${HOME:-/nonexistent}"
REAL_DUR="$REAL_HOME/.claude/run-all/durations"

# count_files <dir> — plain files directly in <dir>, 0 when it does not exist.
count_files() {
    local f n=0
    for f in "$1"/*; do
        [ -f "$f" ] && n=$((n + 1))
    done 2>/dev/null
    printf '%s\n' "$n"
}

REAL_BEFORE="$(count_files "$REAL_DUR")"

FAKE_HOME="$FX_TMP_ROOT/fake-home"
FAKE_DUR="$FAKE_HOME/.claude/run-all/durations"
mkdir -p "$FAKE_HOME"

H="$(fx_new_root)"
fx_add_dummy "$H" h1 --sleep 1
fx_add_dummy "$H" h2 --sleep 2
H_OUT="$FX_TMP_ROOT/h.out"; H_ERR="$FX_TMP_ROOT/h.err"

# fx_exec always pins RUN_ALL_CACHE_DIR, which is exactly the variable under test, so the
# runner is invoked directly here. `-u` must precede every NAME=VALUE: env stops parsing
# options at the first assignment.
H_RC=0
run_with_timeout 90 env -u RUN_ALL_CACHE_DIR $(fx_control_args) \
    "HOME=$FAKE_HOME" "TESTS_DIR=$(fx_tests_dir "$H")" \
    bash "$(fx_runner "$H")" -j 2 --all >"$H_OUT" 2>"$H_ERR" || H_RC=$?

H_EXEC="$(fx_contract_field "$H_OUT" EXECUTED)"
FAKE_SEGS="$(count_files "$FAKE_DUR")"
FAKE_NAMES=""
FAKE_LINES=0
for f in "$FAKE_DUR"/*; do
    [ -f "$f" ] || continue
    FAKE_NAMES="$FAKE_NAMES$(basename "$f")
"
    FAKE_LINES=$((FAKE_LINES + $(grep -c '' "$f" 2>/dev/null || echo 0)))
done
FAKE_CLASS="$(printf '%s' "$FAKE_NAMES" | grep -cE "$SEG_RE" || true)"
FIXTURE_DUR=absent
[ -e "$(fx_ledger_dir)" ] && FIXTURE_DUR=present
REAL_AFTER="$(count_files "$REAL_DUR")"

# ===========================================================================
# N43 — the default path is $HOME/.claude/run-all/durations
# ===========================================================================
if [ "$H_RC" -eq 0 ] && [ "$H_EXEC" = "2" ]; then
    fx_pass "N43a. the fixture is real: the run exited 0 with EXECUTED=2 and no cache dir pinned"
else
    fx_fail "N43a. the fixture is not usable — want exit 0 and EXECUTED=2, got exit $H_RC EXECUTED=${H_EXEC:-absent}"
    fx_show_tail "$H_ERR" 8
fi

if dur_missing "N43. an unpinned run writes its ledger beneath \$HOME/.claude/run-all"; then :
elif [ "$H_EXEC" = "2" ] && [ "$FAKE_SEGS" = "1" ] && [ "$FAKE_CLASS" = "1" ] && \
     [ "$FAKE_LINES" = "2" ]; then
    fx_pass "N43. with RUN_ALL_CACHE_DIR unset the run left 1 correctly named segment holding 2 records under the explicit HOME"
else
    fx_fail "N43. want 1 class-matching segment with 2 records under \$HOME/.claude/run-all/durations, got segments=$FAKE_SEGS class-matching=$FAKE_CLASS records=$FAKE_LINES"
fi

# ===========================================================================
# N44 — nothing reached the fixture cache dir or the developer's real one
# ===========================================================================
# Without this row N43 would also pass for a run that wrote to BOTH locations.
if [ "$FIXTURE_DUR" = "absent" ] && [ "$REAL_AFTER" = "$REAL_BEFORE" ]; then
    fx_pass "N44. the unset variable was honoured: no durations/ under the fixture cache dir and the real ~/.claude/run-all still holds $REAL_BEFORE segment(s)"
else
    fx_fail "N44. want no fixture durations/ and the real ledger unchanged at $REAL_BEFORE, got fixture=$FIXTURE_DUR real-before=$REAL_BEFORE real-after=$REAL_AFTER"
fi

fx_finish
