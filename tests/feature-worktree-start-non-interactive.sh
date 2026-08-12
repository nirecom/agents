#!/bin/bash
# tests/feature-worktree-start-non-interactive.sh
# Tests: skills/worktree-start/SKILL.md, skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, prompts, skill, static, TL2, scope:issue-specific
#
# Issue #1910 — /worktree-start must never ask: the interactive/non-interactive
# branch is removed and task-name/branch-type are always auto-derived by
# skills/worktree-start/scripts/derive-worktree-name.sh (intent.md, or
# --headless <label> for fork callers).

# Dispatcher — sub-files under feature-worktree-start-non-interactive/:
#   helpers.sh                 — fixture, run_derive, assertion helpers
#   skill-static.sh            — TC1-TC13: static contract of SKILL.md
#   derive-core.sh             — B1-B7,B15,B20,B23: core derivation, D0 refusal, devices
#   derive-gh.sh               — B8,B9,B9b,B13a,B13b: D4 gh label classifier
#   session-and-idempotency.sh — B11,B12: session resolution + WS-4/WS-6 reuse
#   reuse-safety.sh            — B22: WS-2 reuse-safety refusals
#   slugify-table.sh           — B14,B24: slugify/parsing/D0 basename, closes_issues[0]

#   scan-gate-and-locale.sh    — B16-B18: D3a/D0 scan gates, D3b stamp, LC_ALL
#   d6-fallback-cascade.sh     — B19: D6 rescan/prefix-drop cascade + unscanned last tier
#   private-repo-gate.sh       — B21: private-name half of scan_clean(), cache seam, D0a
#   self-exclusion-origin.sh   — B25: D0a keyed on resolved origin identity
#   env-nonexposure.sh         — B26: list never enters a child env; call-site routing
# B10 (output-shape invariant) runs once per behavioral sub-file as B10/<group>.

# helpers.sh setup_fixture() declares PRIVATE_REPO_NAMES_CACHE_SET/_CACHE; without
# it every run_derive would hit a live `gh repo list` and vary per user.
# private-repo-gate.sh owns the cases that override it.

# TL3 gap: a real /worktree-start run through the Bash tool (no AskUserQuestion),
# and WS-2/WS-4/WS-6 as executed by the model rather than reproduced here — both
# covered by tests/TL3-skill-worktree-start-auto-naming.sh (RUN_TL3-gated).
# With RUN_TL3 off: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration + manual smoke.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$TESTS_DIR/feature-worktree-start-non-interactive"
TOTAL_PASS=0
TOTAL_FAIL=0

d_pass() { echo "PASS: $1"; TOTAL_PASS=$((TOTAL_PASS + 1)); }
d_fail() { echo "FAIL: $1"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); }

# dispatch_status — the suite's exit code, as a value. Kept as a named seam so the
# self-test below asserts the real decision rather than a copy of it.
dispatch_status() { if [ "$TOTAL_FAIL" -eq 0 ]; then echo 0; else echo 1; fi; }

# run_sub <sub-file> <min-expected-PASS>
# PASS/FAIL counting alone goes false-green when a sub-file crashes before
# printing, so two guards: the sub-file's exit status folds into TOTAL_FAIL, and
# a per-file minimum PASS count catches a truncated run that still exits 0.
# Minimums track the current baseline — raise on new cases; only lower while
# naming the retired cases.
run_sub() {
    local sub="$1" min="$2"
    local name; name="$(basename "$sub")"
    local out rc
    # `bash "$sub"; rc=$?` in two statements: capture the status before anything
    # else can clobber $? (and before a parent `set -e` could abort the function).
    out="$(bash "$sub" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    local p f
    p=$(printf '%s\n' "$out" | grep -c '^PASS:' || true)
    f=$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))

    # Only when the sub-file reported no failure of its own — a legitimately
    # failing sub-file also exits non-zero and is already counted above.
    if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
        d_fail "dispatcher/$name: sub-file exited $rc without emitting a single FAIL line (crashed or never ran)"
    fi
    if [ "$p" -lt "$min" ]; then
        d_fail "dispatcher/$name: emitted $p PASS lines, below the expected minimum of $min (coverage shrank or the run was truncated)"
    fi
}

# --- dispatcher self-test: the false-green scenario must be caught -----------
# Exercises run_sub against throwaway sub-files in a nested tally, so the probe
# never contributes to the real totals.
selftest_dispatcher() {
    local tmp; tmp="$(mktemp -d)"
    local crash="$tmp/crashing-sub.sh" thin="$tmp/thin-sub.sh"
    printf '#!/bin/bash\nexit 3\n' > "$crash"
    printf '#!/bin/bash\necho "PASS: only one"\n' > "$thin"

    # Probe 1: non-zero exit, zero PASS/FAIL lines printed.
    local probe1
    probe1="$(
        TOTAL_PASS=0; TOTAL_FAIL=0
        run_sub "$crash" 0 > "$tmp/crash.log" 2>&1
        printf '%s %s\n' "$TOTAL_FAIL" "$(dispatch_status)"
    )"
    local c_fail="${probe1%% *}" c_status="${probe1##* }"
    if [ "$c_fail" -eq 1 ] && [ "$c_status" -eq 1 ] \
        && grep -q 'crashing-sub.sh' "$tmp/crash.log" \
        && grep -q 'exited 3' "$tmp/crash.log"; then
        d_pass "dispatcher/self-test: a sub-file exiting non-zero with no FAIL lines increments TOTAL_FAIL, names the file and its exit code, and turns the suite red"
    else
        d_fail "dispatcher/self-test: crashing sub-file was not caught (TOTAL_FAIL=$c_fail, status=$c_status, log='$(cat "$tmp/crash.log")')"
    fi

    # Probe 2: exits 0 but emits fewer PASS lines than the file is known to carry.
    local probe2
    probe2="$(
        TOTAL_PASS=0; TOTAL_FAIL=0
        run_sub "$thin" 5 > "$tmp/thin.log" 2>&1
        printf '%s %s\n' "$TOTAL_FAIL" "$(dispatch_status)"
    )"
    local t_fail="${probe2%% *}" t_status="${probe2##* }"
    if [ "$t_fail" -eq 1 ] && [ "$t_status" -eq 1 ] && grep -q 'below the expected minimum' "$tmp/thin.log"; then
        d_pass "dispatcher/self-test: a sub-file emitting fewer PASS lines than its minimum turns the suite red"
    else
        d_fail "dispatcher/self-test: shrunken sub-file was not caught (TOTAL_FAIL=$t_fail, status=$t_status, log='$(cat "$tmp/thin.log")')"
    fi

    # Probe 3: the guards must stay silent on a healthy sub-file.
    local probe3
    probe3="$(
        TOTAL_PASS=0; TOTAL_FAIL=0
        run_sub "$thin" 1 > "$tmp/ok.log" 2>&1
        printf '%s %s\n' "$TOTAL_FAIL" "$(dispatch_status)"
    )"
    local o_fail="${probe3%% *}" o_status="${probe3##* }"
    if [ "$o_fail" -eq 0 ] && [ "$o_status" -eq 0 ]; then
        d_pass "dispatcher/self-test: a healthy sub-file at or above its minimum stays green"
    else
        d_fail "dispatcher/self-test: false positive on a healthy sub-file (TOTAL_FAIL=$o_fail, status=$o_status)"
    fi

    rm -rf "$tmp"
}

selftest_dispatcher

#          sub-file                    min PASS (current baseline)
run_sub "$SUB_DIR/skill-static.sh"            14
run_sub "$SUB_DIR/derive-core.sh"             41
run_sub "$SUB_DIR/derive-gh.sh"               12
run_sub "$SUB_DIR/session-and-idempotency.sh" 13
run_sub "$SUB_DIR/reuse-safety.sh"            30
run_sub "$SUB_DIR/slugify-table.sh"           40
run_sub "$SUB_DIR/scan-gate-and-locale.sh"    18
run_sub "$SUB_DIR/d6-fallback-cascade.sh"     15
run_sub "$SUB_DIR/private-repo-gate.sh"       25
run_sub "$SUB_DIR/self-exclusion-origin.sh"   40
run_sub "$SUB_DIR/env-nonexposure.sh"          8

echo ""
echo "Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
exit "$(dispatch_status)"
