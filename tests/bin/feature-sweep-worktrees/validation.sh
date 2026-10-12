#!/bin/bash
# tests/bin/feature-sweep-worktrees/validation.sh
# Tests: bin/sweep-worktrees.sh
# Tags: sweep, worktrees, validation, maintenance, bin, scope:common
# Input/env validation + error-path tests: T11, T22..T28, T32..T36.
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

# T29 — #2589: from the linked worktree of a `--separate-git-dir` repo, git's
# porcelain names the git dir (branch main) first and nothing names the real
# main worktree. The sweep must stop with an error — never adopt the linked
# checkout as TARGET_MAIN_ROOT and offer the main entry as a removal candidate.
T29_separate_git_dir_linked_fails_closed() {
    local base="$TMPDIR_BASE/t29"
    local main="$base/main" wbase="$base/wbase"
    local linked="$wbase/feat-t29/main"
    mkdir -p "$base"
    git init -q -b main --separate-git-dir "$base/gitdir" "$main"
    git -C "$main" config core.hooksPath /dev/null
    git -C "$main" -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init
    git -C "$main" worktree add -q -b feat-t29 "$linked" 2>/dev/null

    local stdout_file="$base/t29.out" stderr_file="$base/t29.err" exit_code=0
    (cd "$linked" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check --min-age-hours 0 \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local out err
    out="$(cat "$stdout_file" 2>/dev/null || true)"
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    case "$out" in
        *"candidate worktree="*)
            fail "T29 separate_git_dir_linked_fails_closed: main entry offered as a removal candidate; stdout=[$out]"
            return
            ;;
    esac
    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T29 separate_git_dir_linked_fails_closed (exit=$exit_code, no candidate)"
    else
        fail "T29 separate_git_dir_linked_fails_closed: expected error exit; exit=$exit_code stderr=[$err] stdout=[$out]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T32..T36 — a rejected numeric input aborts before any removal. Each case runs
#   --apply against a stale, clean, merged (--skip-gh-check) worktree that the
#   sweep removes when inputs are valid (T36 proves it), then asserts non-zero
#   exit, stderr naming the input, and that the worktree and branch survive.
# ─────────────────────────────────────────────────────────────────────────────

_REJECT_SEQ=0

_make_removable_candidate() {
    _REJECT_SEQ=$((_REJECT_SEQ + 1))
    FX_REPO="$TMPDIR_BASE/rej${_REJECT_SEQ}-repo"
    FX_WT="$TMPDIR_BASE/rej${_REJECT_SEQ}-wt"
    FX_WBASE="$TMPDIR_BASE/rej${_REJECT_SEQ}-wbase"
    FX_BRANCH="feature/rej${_REJECT_SEQ}"
    mkdir -p "$FX_WBASE"
    init_repo "$FX_REPO"
    git -C "$FX_REPO" config core.hooksPath /dev/null
    add_worktree "$FX_REPO" "$FX_WT" "$FX_BRANCH"
    make_stale "$FX_WT"
}

_candidate_survives() {
    [ -d "$FX_WT" ] &&
        git -C "$FX_REPO" rev-parse --verify --quiet "refs/heads/$FX_BRANCH" >/dev/null &&
        [[ "$(git -C "$FX_REPO" worktree list 2>/dev/null)" == *"$FX_BRANCH"* ]]
}

# $1: SWEEP_AGE_DAYS env value; rest: flags. Sets RUN_EXIT / RUN_ERR.
_run_sweep_on_candidate() {
    local age_days="$1"
    shift
    local err_file="$TMPDIR_BASE/rej${_REJECT_SEQ}.err"
    RUN_EXIT=0
    (cd "$FX_REPO" && SWEEP_SKIP_GH=1 SWEEP_AGE_DAYS="$age_days" WORKTREE_BASE_DIR="$FX_WBASE" \
        run_with_timeout bash "$SWEEP" --skip-gh-check "$@" \
        >/dev/null 2>"$err_file") || RUN_EXIT=$?
    RUN_ERR="$(cat "$err_file" 2>/dev/null || true)"
}

# $1: label, $2/$3: accepted input names in stderr, $4: SWEEP_AGE_DAYS, rest: flags.
_expect_rejected_without_removal() {
    local label="$1" name_a="$2" name_b="$3" age_days="$4"
    shift 4
    if [ ! -x "$SWEEP" ]; then
        fail "$label: $SWEEP not found / not executable"
        return
    fi
    _make_removable_candidate
    _run_sweep_on_candidate "$age_days" --apply "$@"
    if [ "$RUN_EXIT" -eq 0 ]; then
        fail "$label: exit=0, expected non-zero; stderr=[$RUN_ERR]"
    elif [[ "$RUN_ERR" != *"$name_a"* && "$RUN_ERR" != *"$name_b"* ]]; then
        fail "$label: stderr does not name $name_a; stderr=[$RUN_ERR]"
    elif ! _candidate_survives; then
        fail "$label: candidate worktree or branch removed despite rejection"
    else
        pass "$label (exit=$RUN_EXIT)"
    fi
}

T32_sweep_age_days_env_rejected_without_removal() {
    local v
    for v in 08 0 -1 abc 99999999999999999999 106751991167301; do
        _expect_rejected_without_removal "T32 sweep_age_days_env_rejected_without_removal[$v]" \
            SWEEP_AGE_DAYS SWEEP_AGE_DAYS "$v"
    done
}

T33_sweep_age_days_flag_rejected_without_removal() {
    local v
    for v in 08 99999999999999999999; do
        _expect_rejected_without_removal "T33 sweep_age_days_flag_rejected_without_removal[$v]" \
            --sweep-age-days SWEEP_AGE_DAYS 30 --sweep-age-days "$v"
    done
}

T34_min_age_hours_rejected_without_removal() {
    local v
    for v in 08 -1 abc 99999999999999999999 2562047788015216; do
        _expect_rejected_without_removal "T34 min_age_hours_rejected_without_removal[$v]" \
            --min-age-hours --min-age-hours 30 --min-age-hours "$v"
    done
}

# T35 — --min-age-hours 0 is valid ("no age gate"); --dry-run removes nothing.
T35_min_age_hours_zero_accepted() {
    if [ ! -x "$SWEEP" ]; then
        fail "T35 min_age_hours_zero_accepted: $SWEEP not found / not executable"
        return
    fi
    _make_removable_candidate
    _run_sweep_on_candidate 30 --dry-run --min-age-hours 0
    if [ "$RUN_EXIT" -eq 0 ] && _candidate_survives; then
        pass "T35 min_age_hours_zero_accepted"
    else
        fail "T35 min_age_hours_zero_accepted: exit=$RUN_EXIT, stderr=[$RUN_ERR]"
    fi
}

# T36 — control: with valid inputs the T32..T34 fixture IS removed by --apply,
#       so their "candidate survives" assertion is not vacuous.
T36_valid_inputs_remove_candidate_control() {
    if [ ! -x "$SWEEP" ]; then
        fail "T36 valid_inputs_remove_candidate_control: $SWEEP not found / not executable"
        return
    fi
    _make_removable_candidate
    _run_sweep_on_candidate 30 --apply --sweep-age-days 30 --min-age-hours 24
    if [ "$RUN_EXIT" -eq 0 ] && [ ! -d "$FX_WT" ] &&
        ! git -C "$FX_REPO" rev-parse --verify --quiet "refs/heads/$FX_BRANCH" >/dev/null; then
        pass "T36 valid_inputs_remove_candidate_control"
    else
        fail "T36 valid_inputs_remove_candidate_control: exit=$RUN_EXIT, wt_exists=$([ -d "$FX_WT" ] && echo 1 || echo 0), stderr=[$RUN_ERR]"
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
T29_separate_git_dir_linked_fails_closed
T32_sweep_age_days_env_rejected_without_removal
T33_sweep_age_days_flag_rejected_without_removal
T34_min_age_hours_rejected_without_removal
T35_min_age_hours_zero_accepted
T36_valid_inputs_remove_candidate_control

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
