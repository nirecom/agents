#!/bin/bash
# tests/feature-sweep-plans/validation.sh
# Tests: bin/sweep-plans.sh
# Tags: sweep, plans, workflow-plans, maintenance, bin, validation, scope:common
#
# SWEEP_AGE_DAYS input validation tests (split out of the flat
# feature-sweep-plans.sh per rules/coding/file-split.md Pattern A hard-limit).
# Sourced helpers come from _lib.sh. Runnable standalone:
#   bash tests/feature-sweep-plans/validation.sh

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T9 — SWEEP_AGE_DAYS=0 → exit non-zero (exit 2), error on stderr
# ─────────────────────────────────────────────────────────────────────────────

T9_sweep_age_days_zero_rejected() {
    local plans_dir="$TMPDIR_BASE/t9-plans"
    mkdir -p "$plans_dir"

    if [ ! -f "$SWEEP" ]; then
        fail "T9 sweep_age_days_zero_rejected: $SWEEP not found"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t9.out"
    local stderr_file="$TMPDIR_BASE/t9.err"
    WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=0 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file"
    local exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T9 sweep_age_days_zero_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T9 sweep_age_days_zero_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T10 — SWEEP_AGE_DAYS=abc → exit non-zero, error on stderr
# ─────────────────────────────────────────────────────────────────────────────

T10_sweep_age_days_non_numeric_rejected() {
    local plans_dir="$TMPDIR_BASE/t10-plans"
    mkdir -p "$plans_dir"

    if [ ! -f "$SWEEP" ]; then
        fail "T10 sweep_age_days_non_numeric_rejected: $SWEEP not found"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t10.out"
    local stderr_file="$TMPDIR_BASE/t10.err"
    WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=abc \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file"
    local exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T10 sweep_age_days_non_numeric_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T10 sweep_age_days_non_numeric_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T11 — SWEEP_AGE_DAYS=010 is rejected (bash reads a leading zero as octal;
# 010 would otherwise silently mean 8, not 10).
T11_sweep_age_days_leading_zero_rejected() {
    local plans_dir="$TMPDIR_BASE/t11-plans"
    mkdir -p "$plans_dir"

    if [ ! -f "$SWEEP" ]; then
        fail "T11 sweep_age_days_leading_zero_rejected: $SWEEP not found"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t11.out"
    local stderr_file="$TMPDIR_BASE/t11.err"
    WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=010 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file"
    local exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T11 sweep_age_days_leading_zero_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T11 sweep_age_days_leading_zero_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T12 — SWEEP_AGE_DAYS beyond 15 digits is rejected (guards against 64-bit
# arithmetic wraparound turning a huge value into a small/negative one).
T12_sweep_age_days_overflow_rejected() {
    local plans_dir="$TMPDIR_BASE/t12-plans"
    mkdir -p "$plans_dir"

    if [ ! -f "$SWEEP" ]; then
        fail "T12 sweep_age_days_overflow_rejected: $SWEEP not found"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t12.out"
    local stderr_file="$TMPDIR_BASE/t12.err"
    WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=9999999999999999 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file"
    local exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T12 sweep_age_days_overflow_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T12 sweep_age_days_overflow_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T13 — SWEEP_AGE_DAYS one past the exact *86400 safe-max boundary is
# rejected, even though it is only 15 digits (below the old digit-count cap).
T13_sweep_age_days_safe_max_boundary_rejected() {
    local plans_dir="$TMPDIR_BASE/t13-plans"
    mkdir -p "$plans_dir"

    if [ ! -f "$SWEEP" ]; then
        fail "T13 sweep_age_days_safe_max_boundary_rejected: $SWEEP not found"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t13.out"
    local stderr_file="$TMPDIR_BASE/t13.err"
    WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=106751991167301 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file"
    local exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T13 sweep_age_days_safe_max_boundary_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T13 sweep_age_days_safe_max_boundary_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T9_sweep_age_days_zero_rejected
T10_sweep_age_days_non_numeric_rejected
T11_sweep_age_days_leading_zero_rejected
T12_sweep_age_days_overflow_rejected
T13_sweep_age_days_safe_max_boundary_rejected

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
