#!/bin/bash
# tests/feature-sweep-worktrees/gh-stub.sh
# is_pr_merged behavior tests against stubbed gh CLI: T12, T13, T14.
# Standalone-runnable; sourced helpers live in _lib.sh.

# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T12 — is_pr_merged: stub gh returns "true" using correct -H form
#        → worktree is detected as a candidate (regression test for the fix).
#        RED against the current broken code (uses --search "head:..." + --arg);
#        turns GREEN after the fix (uses -H "$branch").
# ─────────────────────────────────────────────────────────────────────────────

T12_is_pr_merged_stub_true_detected_as_candidate() {
    local repo="$TMPDIR_BASE/t12-repo"
    local wpath="$TMPDIR_BASE/t12-wt"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/merged-12"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T12 is_pr_merged_stub_true_detected_as_candidate: $SWEEP not found / not executable"
        return
    fi

    # Create a stub gh that:
    #   1. Records the arguments it receives to a file.
    #   2. Returns "true" (indicating a merged PR) with exit 0.
    local stubdir="$TMPDIR_BASE/t12-stubgh"
    mkdir -p "$stubdir"
    local argsfile="$stubdir/gh-args"
    cat > "$stubdir/gh" <<EOF
#!/bin/bash
# stub gh for T12: record args and return "true"
printf '%s\n' "\$*" >> "$argsfile"
echo "true"
exit 0
EOF
    chmod +x "$stubdir/gh"

    local stdout_file="$TMPDIR_BASE/t12.out"
    local stderr_file="$TMPDIR_BASE/t12.err"
    (cd "$repo" && PATH="$stubdir:$PATH" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode \
            >"$stdout_file" 2>"$stderr_file") || true
    local out err
    out="$(cat "$stdout_file" 2>/dev/null || true)"
    err="$(cat "$stderr_file" 2>/dev/null || true)"
    local recorded_args
    recorded_args="$(cat "$argsfile" 2>/dev/null || true)"

    # Verify the stub was called with -H (not --arg which is the broken form).
    local used_dash_H used_arg_flag
    case "$recorded_args" in
        *" -H "*|*"-H "*)  used_dash_H=1 ;;
        *)                 used_dash_H=0 ;;
    esac
    case "$recorded_args" in
        *"--arg "*)  used_arg_flag=1 ;;
        *)           used_arg_flag=0 ;;
    esac

    # Verify the worktree is detected as a candidate (candidates >= 1).
    # --apply outputs "Deleted branch ..." to stdout before the JSON line;
    # extract only the JSON object line so ci_field can parse it.
    local json_line n_candidates
    json_line="$(printf '%s\n' "$out" | grep -E '^\{' | tail -1)"
    n_candidates="$(ci_field "$json_line" candidates)"

    if [ "$used_dash_H" = "1" ] && [ "$used_arg_flag" = "0" ] && [ "${n_candidates:-0}" -ge 1 ] 2>/dev/null; then
        pass "T12 is_pr_merged_stub_true_detected_as_candidate (used -H, no --arg, candidates>=1)"
    else
        fail "T12 is_pr_merged_stub_true_detected_as_candidate: used_dash_H=$used_dash_H used_arg_flag=$used_arg_flag candidates=${n_candidates:-?}; recorded_args=[$recorded_args]; stdout=$out; stderr=$err"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T13 — is_pr_merged: stub gh returns "false" → worktree is NOT a candidate;
#        skipped_unmerged counter incremented.
# ─────────────────────────────────────────────────────────────────────────────

T13_is_pr_merged_stub_false_not_candidate() {
    local repo="$TMPDIR_BASE/t13-repo"
    local wpath="$TMPDIR_BASE/t13-wt"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/unmerged-13"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T13 is_pr_merged_stub_false_not_candidate: $SWEEP not found / not executable"
        return
    fi

    # Stub gh returns "false" (no merged PR found).
    local stubdir="$TMPDIR_BASE/t13-stubgh"
    mkdir -p "$stubdir"
    cat > "$stubdir/gh" <<'EOF'
#!/bin/bash
# stub gh for T13: no merged PR
echo "false"
exit 0
EOF
    chmod +x "$stubdir/gh"

    local stdout_file="$TMPDIR_BASE/t13.out"
    local stderr_file="$TMPDIR_BASE/t13.err"
    (cd "$repo" && PATH="$stubdir:$PATH" \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
            >"$stdout_file" 2>"$stderr_file") || true
    local out err
    out="$(cat "$stdout_file" 2>/dev/null || true)"
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    local n_unmerged n_candidates
    n_unmerged="$(ci_field "$out" skipped_unmerged)"
    n_candidates="$(ci_field "$out" candidates)"

    if [ "${n_unmerged:-0}" -ge 1 ] 2>/dev/null && { [ "${n_candidates:-0}" -eq 0 ] 2>/dev/null || [ -z "$n_candidates" ]; }; then
        pass "T13 is_pr_merged_stub_false_not_candidate (skipped_unmerged>=1, candidates==0)"
    else
        fail "T13 is_pr_merged_stub_false_not_candidate: skipped_unmerged=${n_unmerged:-?} candidates=${n_candidates:-?}; stdout=$out; stderr=$err"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T14 — is_pr_merged: stub gh exits non-zero → WARN emitted on stderr;
#        worktree is skipped (skipped_unmerged incremented).
# ─────────────────────────────────────────────────────────────────────────────

T14_is_pr_merged_gh_error_warns_and_skips() {
    local repo="$TMPDIR_BASE/t14-repo"
    local wpath="$TMPDIR_BASE/t14-wt"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/error-14"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T14 is_pr_merged_gh_error_warns_and_skips: $SWEEP not found / not executable"
        return
    fi

    # Stub gh exits non-zero (simulates gh CLI failure).
    local stubdir="$TMPDIR_BASE/t14-stubgh"
    mkdir -p "$stubdir"
    cat > "$stubdir/gh" <<'EOF'
#!/bin/bash
# stub gh for T14: simulate gh CLI failure
echo "error: failed to connect" >&2
exit 1
EOF
    chmod +x "$stubdir/gh"

    local stdout_file="$TMPDIR_BASE/t14.out"
    local stderr_file="$TMPDIR_BASE/t14.err"
    (cd "$repo" && PATH="$stubdir:$PATH" \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
            >"$stdout_file" 2>"$stderr_file") || true
    local out err
    out="$(cat "$stdout_file" 2>/dev/null || true)"
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    # WARN must appear in stderr.
    local has_warn=0
    case "$err" in
        *[Ww][Aa][Rr][Nn]*) has_warn=1 ;;
    esac

    # The worktree must be skipped (skipped_unmerged >= 1).
    local n_unmerged
    n_unmerged="$(ci_field "$out" skipped_unmerged)"

    if [ "$has_warn" = "1" ] && [ "${n_unmerged:-0}" -ge 1 ] 2>/dev/null; then
        pass "T14 is_pr_merged_gh_error_warns_and_skips (WARN on stderr, skipped_unmerged>=1)"
    else
        fail "T14 is_pr_merged_gh_error_warns_and_skips: has_warn=$has_warn skipped_unmerged=${n_unmerged:-?}; stderr=[$err]; stdout=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T12_is_pr_merged_stub_true_detected_as_candidate
T13_is_pr_merged_stub_false_not_candidate
T14_is_pr_merged_gh_error_warns_and_skips

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
