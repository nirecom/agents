#!/bin/bash
# tests/feature-sweep-worktrees/validation.sh
# Tests: bin/sweep-worktrees.sh
# Tags: sweep, worktrees, validation, maintenance, bin, scope:common
# Input/env validation + error-path tests: T11, T22..T28.
# Standalone-runnable; sourced helpers live in _lib.sh.

# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T11 — registry fetch failure: `git worktree list --porcelain` fails →
#       scan pass aborts with WARNING on stderr; orphan_dirs_removed == 0.
#       Simulated by injecting a git wrapper that fails the registry fetch.
# ─────────────────────────────────────────────────────────────────────────────

T11_registry_fetch_failure_aborts_scan() {
    local repo="$TMPDIR_BASE/t11-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t11-wbase"
    local orphan="$wbase/broken-task/$repo_name"
    mkdir -p "$orphan"
    printf 'leftover\n' > "$orphan/leftover.txt"
    make_stale "$orphan"
    make_stale "$wbase/broken-task"

    if [ ! -x "$SWEEP" ]; then
        fail "T11 registry_fetch_failure_aborts_scan: $SWEEP not found / not executable"
        return
    fi

    # Inject a git wrapper that fails specifically for `worktree list --porcelain`
    # while passing all other git commands through. This lets the initial
    # `git rev-parse --show-toplevel` succeed, but the orphan-dir pre-pass guard
    # fails → SKIP_ORPHAN_DIR_SCAN=1 → WARNING on stderr.
    local fake_git_dir="$TMPDIR_BASE/t11-fake-git"
    mkdir -p "$fake_git_dir"
    local real_git
    real_git="$(command -v git)"
    cat > "$fake_git_dir/git" <<EOF
#!/bin/sh
args="\$*"
case "\$args" in
  *"worktree list"*) exit 1 ;;
  *) exec "$real_git" "\$@" ;;
esac
EOF
    chmod +x "$fake_git_dir/git"

    local stdout_file="$TMPDIR_BASE/t11.out"
    local stderr_file="$TMPDIR_BASE/t11.err"
    (cd "$repo" && PATH="$fake_git_dir:$PATH" SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check \
            >"$stdout_file" 2>"$stderr_file") || true
    local out err
    out="$(cat "$stdout_file" 2>/dev/null || true)"
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    # orphan_dirs_removed must be 0 (scan aborted before removal).
    local n
    n="$(ci_field "$out" orphan_dirs_removed)"
    case "$err" in
        *[Ww][Aa][Rr][Nn]*|*WARNING*)
            if [ "$n" = "0" ] || [ -z "$n" ]; then
                pass "T11 registry_fetch_failure_aborts_scan (warned + counter==0)"
            else
                fail "T11 registry_fetch_failure_aborts_scan: warned but counter=$n; stdout=$out"
            fi
            ;;
        *)
            fail "T11 registry_fetch_failure_aborts_scan: missing WARNING on stderr; stderr=$err, stdout=$out"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T22 — SWEEP_AGE_DAYS=0 → exit non-zero, validation error on stderr
# ─────────────────────────────────────────────────────────────────────────────

T22_sweep_age_days_zero_rejected() {
    local repo="$TMPDIR_BASE/t22-repo"
    init_repo "$repo"

    if [ ! -x "$SWEEP" ]; then
        fail "T22 sweep_age_days_zero_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t22.out"
    local stderr_file="$TMPDIR_BASE/t22.err"
    local exit_code=0
    (cd "$repo" && SWEEP_SKIP_GH=1 SWEEP_AGE_DAYS=0 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T22 sweep_age_days_zero_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T22 sweep_age_days_zero_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T23 — SWEEP_AGE_DAYS=010 is rejected (bash reads a leading zero as octal).
T23_sweep_age_days_leading_zero_rejected() {
    local repo="$TMPDIR_BASE/t23-repo"
    init_repo "$repo"

    if [ ! -x "$SWEEP" ]; then
        fail "T23 sweep_age_days_leading_zero_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t23.out"
    local stderr_file="$TMPDIR_BASE/t23.err"
    local exit_code=0
    (cd "$repo" && SWEEP_SKIP_GH=1 SWEEP_AGE_DAYS=010 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T23 sweep_age_days_leading_zero_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T23 sweep_age_days_leading_zero_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T24 — SWEEP_AGE_DAYS beyond 15 digits is rejected (64-bit wraparound guard).
T24_sweep_age_days_overflow_rejected() {
    local repo="$TMPDIR_BASE/t24-repo"
    init_repo "$repo"

    if [ ! -x "$SWEEP" ]; then
        fail "T24 sweep_age_days_overflow_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t24.out"
    local stderr_file="$TMPDIR_BASE/t24.err"
    local exit_code=0
    (cd "$repo" && SWEEP_SKIP_GH=1 SWEEP_AGE_DAYS=9999999999999999 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T24 sweep_age_days_overflow_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T24 sweep_age_days_overflow_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T25 — SWEEP_AGE_DAYS one past the exact *86400 safe-max boundary is
# rejected, even though it is only 15 digits (below the old digit-count cap).
T25_sweep_age_days_safe_max_boundary_rejected() {
    local repo="$TMPDIR_BASE/t25-repo"
    init_repo "$repo"

    if [ ! -x "$SWEEP" ]; then
        fail "T25 sweep_age_days_safe_max_boundary_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t25.out"
    local stderr_file="$TMPDIR_BASE/t25.err"
    local exit_code=0
    (cd "$repo" && SWEEP_SKIP_GH=1 SWEEP_AGE_DAYS=106751991167301 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T25 sweep_age_days_safe_max_boundary_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T25 sweep_age_days_safe_max_boundary_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T26 — --min-age-hours 010 is rejected (bash reads a leading zero as octal).
#       Previously this script had ZERO validation on --min-age-hours.
T26_min_age_hours_leading_zero_rejected() {
    local repo="$TMPDIR_BASE/t26-repo"
    init_repo "$repo"

    if [ ! -x "$SWEEP" ]; then
        fail "T26 min_age_hours_leading_zero_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t26.out"
    local stderr_file="$TMPDIR_BASE/t26.err"
    local exit_code=0
    (cd "$repo" && SWEEP_SKIP_GH=1 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check --min-age-hours 010 \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T26 min_age_hours_leading_zero_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T26 min_age_hours_leading_zero_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T27 — --min-age-hours one past the exact *3600 safe-max boundary is rejected.
T27_min_age_hours_overflow_rejected() {
    local repo="$TMPDIR_BASE/t27-repo"
    init_repo "$repo"

    if [ ! -x "$SWEEP" ]; then
        fail "T27 min_age_hours_overflow_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t27.out"
    local stderr_file="$TMPDIR_BASE/t27.err"
    local exit_code=0
    (cd "$repo" && SWEEP_SKIP_GH=1 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check --min-age-hours 2562047788015216 \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T27 min_age_hours_overflow_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T27 min_age_hours_overflow_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# T28 — --min-age-hours abc (non-numeric) is rejected.
T28_min_age_hours_non_numeric_rejected() {
    local repo="$TMPDIR_BASE/t28-repo"
    init_repo "$repo"

    if [ ! -x "$SWEEP" ]; then
        fail "T28 min_age_hours_non_numeric_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t28.out"
    local stderr_file="$TMPDIR_BASE/t28.err"
    local exit_code=0
    (cd "$repo" && SWEEP_SKIP_GH=1 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check --min-age-hours abc \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T28 min_age_hours_non_numeric_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T28 min_age_hours_non_numeric_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T11_registry_fetch_failure_aborts_scan
T22_sweep_age_days_zero_rejected
T23_sweep_age_days_leading_zero_rejected
T24_sweep_age_days_overflow_rejected
T25_sweep_age_days_safe_max_boundary_rejected
T26_min_age_hours_leading_zero_rejected
T27_min_age_hours_overflow_rejected
T28_min_age_hours_non_numeric_rejected

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
