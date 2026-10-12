#!/bin/bash
# tests/bin/feature-sweep-plans/validation.sh
# Tests: bin/sweep-plans.sh
# Tags: sweep, plans, workflow-plans, maintenance, bin, validation, scope:common, table-driven
#
# SWEEP_AGE_DAYS input validation tests (split out of the flat
# feature-sweep-plans.sh per rules/coding/file-split.md Pattern A hard-limit).
# Sourced helpers come from _lib.sh. Runnable standalone:
#   bash tests/bin/feature-sweep-plans/validation.sh

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

# T14 — --sweep-age-days 010 (the flag, not the env) goes through the same
# sweep_validate_uint check: exit 2 with the leading-zero ERROR line.
T14_sweep_age_days_flag_leading_zero_rejected() {
    local plans_dir="$TMPDIR_BASE/t14-plans"
    mkdir -p "$plans_dir"

    if [ ! -f "$SWEEP" ]; then
        fail "T14 sweep_age_days_flag_leading_zero_rejected: $SWEEP not found"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t14.out"
    local stderr_file="$TMPDIR_BASE/t14.err"
    WORKFLOW_PLANS_DIR="$plans_dir" \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --sweep-age-days 010 \
        >"$stdout_file" 2>"$stderr_file"
    local exit_code=$?
    local err
    err="$(tr -d '\r' < "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -eq 2 ] && printf '%s' "$err" | grep -qF "must not have a leading zero"; then
        pass "T14 sweep_age_days_flag_leading_zero_rejected (exit=$exit_code)"
    else
        fail "T14 sweep_age_days_flag_leading_zero_rejected: exit=$exit_code (want 2, msg~'must not have a leading zero'), stderr=[$err]"
    fi
}

# _plant_deletable <plans_dir> — one old non-plan raw that a valid flagless run removes; prints its path.
_plant_deletable() {
    local f="$1/20260101-140000-detail-codex-round-1-raw.md"
    mkdir -p "$1"
    printf 'raw\n' > "$f"
    backdate "$f"
    printf '%s' "$f"
}

# _run_age <source> <value> <plans_dir> <stderr_file> — flagless (deleting) run; prints the exit code.
# source=env sets SWEEP_AGE_DAYS; source=flag clears the env and passes --sweep-age-days.
_run_age() {
    local rc=0
    if [ "$1" = "env" ]; then
        WORKFLOW_PLANS_DIR="$3" SWEEP_AGE_DAYS="$2" \
            run_with_timeout bash "$SWEEP" --ci-mode >/dev/null 2>"$4" || rc=$?
    else
        WORKFLOW_PLANS_DIR="$3" run_with_timeout env -u SWEEP_AGE_DAYS \
            bash "$SWEEP" --ci-mode --sweep-age-days "$2" >/dev/null 2>"$4" || rc=$?
    fi
    printf '%s' "$rc"
}

# T15 — a rejected age value (env or flag) exits 2 before deleting anything:
# the planted old non-plan file survives a flagless run.
T15_rejected_age_deletes_nothing() {
    local src val label n=0 plans_dir planted rc err
    while IFS='|' read -r src val label; do
        [ -n "$src" ] || continue
        n=$((n + 1))
        plans_dir="$TMPDIR_BASE/t15-plans-$n"
        planted="$(_plant_deletable "$plans_dir")"
        rc="$(_run_age "$src" "$val" "$plans_dir" "$TMPDIR_BASE/t15-$n.err")"
        err="$(tr -d '\r' < "$TMPDIR_BASE/t15-$n.err" 2>/dev/null || true)"
        if [ "$rc" = "2" ] && printf '%s' "$err" | grep -q '^ERROR: SWEEP_AGE_DAYS ' && [ -f "$planted" ]; then
            pass "T15 $src $label ($val): exit 2, planted non-plan kept"
        else
            fail "T15 $src $label ($val): exit=$rc (want 2), planted_present=$([ -f "$planted" ] && echo y || echo n), stderr=[$err]"
        fi
    done <<'ROWS'
env|0|zero
env|abc|non-numeric
env|010|leading-zero
env|9999999999999999|overflow
env|106751991167301|safe-max+1
flag|0|zero
flag|abc|non-numeric
flag|010|leading-zero
flag|9999999999999999|overflow
flag|106751991167301|safe-max+1
ROWS
}

# T16 — control for T15: a valid value through the same path removes the planted file,
# so T15's survival is caused by the rejection, not by an undeletable fixture.
T16_valid_age_deletes_planted() {
    local src n=0 plans_dir planted rc
    for src in env flag; do
        n=$((n + 1))
        plans_dir="$TMPDIR_BASE/t16-plans-$n"
        planted="$(_plant_deletable "$plans_dir")"
        rc="$(_run_age "$src" 30 "$plans_dir" "$TMPDIR_BASE/t16-$n.err")"
        if [ "$rc" = "0" ] && [ ! -e "$planted" ]; then
            pass "T16 $src valid (30): exit 0, planted non-plan removed"
        else
            fail "T16 $src valid (30): exit=$rc (want 0), planted_present=$([ -f "$planted" ] && echo y || echo n), stderr=[$(cat "$TMPDIR_BASE/t16-$n.err" 2>/dev/null)]"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T9_sweep_age_days_zero_rejected
T10_sweep_age_days_non_numeric_rejected
T11_sweep_age_days_leading_zero_rejected
T12_sweep_age_days_overflow_rejected
T13_sweep_age_days_safe_max_boundary_rejected
T14_sweep_age_days_flag_leading_zero_rejected
T15_rejected_age_deletes_nothing
T16_valid_age_deletes_planted

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
