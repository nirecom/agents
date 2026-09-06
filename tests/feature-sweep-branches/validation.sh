#!/bin/bash
# tests/feature-sweep-branches/validation.sh
# Tests: bin/sweep-branches.sh
# Tags: sweep, branch, maintenance, bin, validation, scope:common
#
# SWEEP_AGE_DAYS / --min-age-hours input validation tests (split out of
# core.sh per rules/coding/file-split.md Pattern A hard-limit).
# Sourced helpers come from _lib.sh. Runnable standalone:
#   bash tests/feature-sweep-branches/validation.sh

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T17 — SWEEP_AGE_DAYS=0 env var → exit non-zero, validation error on stderr
# ─────────────────────────────────────────────────────────────────────────────

T17_sweep_age_days_zero_rejected() {
    local repo="$TMPDIR_BASE/t17-repo"
    local stubdir="$TMPDIR_BASE/t17-stub"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    if [ ! -x "$SWEEP" ]; then
        fail "T17 sweep_age_days_zero_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t17.out"
    local stderr_file="$TMPDIR_BASE/t17.err"
    local exit_code=0
    (cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" SWEEP_AGE_DAYS=0 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T17 sweep_age_days_zero_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T17 sweep_age_days_zero_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T18 — SWEEP_AGE_DAYS=010 is rejected (bash reads a leading zero as octal).
T18_sweep_age_days_leading_zero_rejected() {
    local repo="$TMPDIR_BASE/t18-repo"
    local stubdir="$TMPDIR_BASE/t18-stub"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    if [ ! -x "$SWEEP" ]; then
        fail "T18 sweep_age_days_leading_zero_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t18.out"
    local stderr_file="$TMPDIR_BASE/t18.err"
    local exit_code=0
    (cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" SWEEP_AGE_DAYS=010 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T18 sweep_age_days_leading_zero_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T18 sweep_age_days_leading_zero_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T19 — SWEEP_AGE_DAYS beyond 15 digits is rejected (64-bit wraparound guard).
T19_sweep_age_days_overflow_rejected() {
    local repo="$TMPDIR_BASE/t19-repo"
    local stubdir="$TMPDIR_BASE/t19-stub"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    if [ ! -x "$SWEEP" ]; then
        fail "T19 sweep_age_days_overflow_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t19.out"
    local stderr_file="$TMPDIR_BASE/t19.err"
    local exit_code=0
    (cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" SWEEP_AGE_DAYS=9999999999999999 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T19 sweep_age_days_overflow_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T19 sweep_age_days_overflow_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T20 — SWEEP_AGE_DAYS one past the exact *86400 safe-max boundary is
# rejected, even though it is only 15 digits (below the old digit-count cap).
T20_sweep_age_days_safe_max_boundary_rejected() {
    local repo="$TMPDIR_BASE/t20-repo"
    local stubdir="$TMPDIR_BASE/t20-stub"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    if [ ! -x "$SWEEP" ]; then
        fail "T20 sweep_age_days_safe_max_boundary_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t20.out"
    local stderr_file="$TMPDIR_BASE/t20.err"
    local exit_code=0
    (cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" SWEEP_AGE_DAYS=106751991167301 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T20 sweep_age_days_safe_max_boundary_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T20 sweep_age_days_safe_max_boundary_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T21 — --min-age-hours 010 is rejected (bash reads a leading zero as octal).
T21_min_age_hours_leading_zero_rejected() {
    local repo="$TMPDIR_BASE/t21-repo"
    local stubdir="$TMPDIR_BASE/t21-stub"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    if [ ! -x "$SWEEP" ]; then
        fail "T21 min_age_hours_leading_zero_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t21.out"
    local stderr_file="$TMPDIR_BASE/t21.err"
    local exit_code=0
    (cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --min-age-hours 010 \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T21 min_age_hours_leading_zero_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T21 min_age_hours_leading_zero_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T22 — --min-age-hours one past the exact *3600 safe-max boundary is rejected.
T22_min_age_hours_overflow_rejected() {
    local repo="$TMPDIR_BASE/t22-repo"
    local stubdir="$TMPDIR_BASE/t22-stub"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    if [ ! -x "$SWEEP" ]; then
        fail "T22 min_age_hours_overflow_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t22.out"
    local stderr_file="$TMPDIR_BASE/t22.err"
    local exit_code=0
    (cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --min-age-hours 2562047788015216 \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T22 min_age_hours_overflow_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T22 min_age_hours_overflow_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T17_sweep_age_days_zero_rejected
T18_sweep_age_days_leading_zero_rejected
T19_sweep_age_days_overflow_rejected
T20_sweep_age_days_safe_max_boundary_rejected
T21_min_age_hours_leading_zero_rejected
T22_min_age_hours_overflow_rejected

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
