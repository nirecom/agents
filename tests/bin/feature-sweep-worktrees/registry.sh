#!/bin/bash
# Tests: bin/sweep-worktrees.sh
# Tags: sweep, worktree, maintenance, bin, git, scope:common

# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

. "$AGENTS_DIR/tests/lib/harness.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T1 — no linked worktrees → zero candidates
# ─────────────────────────────────────────────────────────────────────────────

case_begin "no-worktrees-zero-candidates" "bin/sweep-worktrees.sh"
T1_no_worktrees_zero_candidates() {
    local repo="$TMPDIR_BASE/t1-repo"
    local wbase="$TMPDIR_BASE/t1-wbase"
    mkdir -p "$wbase"
    init_repo "$repo"
    if [ ! -x "$SWEEP" ]; then
        fail "T1 no_worktrees_zero_candidates: $SWEEP not found / not executable"
        return
    fi
    local out exit_code
    out="$(cd "$repo" && WORKTREE_BASE_DIR="$wbase" run_with_timeout 120 bash "$SWEEP" --dry-run 2>&1)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T1 no_worktrees_zero_candidates: exit=$exit_code, out=$out"
        return
    fi
    case "$out" in
        *"0 candidates"*|*"candidates: 0"*|*"no candidates"*)
            pass "T1 no_worktrees_zero_candidates" ;;
        *)
            fail "T1 no_worktrees_zero_candidates: missing zero-candidates phrase in: $out" ;;
    esac
}
T1_no_worktrees_zero_candidates
case_end

# ─────────────────────────────────────────────────────────────────────────────
# T2 — linked worktree on branch with NO merged PR → not a candidate
# ─────────────────────────────────────────────────────────────────────────────

case_begin "unmerged-branch-not-candidate" "bin/sweep-worktrees.sh"
T2_unmerged_branch_not_candidate() {
    local repo="$TMPDIR_BASE/t2-repo"
    local wpath="$TMPDIR_BASE/t2-wt"
    local wbase="$TMPDIR_BASE/t2-wbase"
    mkdir -p "$wbase"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/unmerged"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T2 unmerged_branch_not_candidate: $SWEEP not found / not executable"
        return
    fi
    local out exit_code
    out="$(cd "$repo" && WORKTREE_BASE_DIR="$wbase" run_with_timeout 120 bash "$SWEEP" --dry-run 2>&1)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T2 unmerged_branch_not_candidate: exit=$exit_code, out=$out"
        return
    fi
    case "$out" in
        *"feature/unmerged"*)
            case "$out" in
                *"skipped"*"feature/unmerged"*|*"feature/unmerged"*"skipped"*|*"feature/unmerged"*"unmerged"*)
                    pass "T2 unmerged_branch_not_candidate (listed as skipped)" ;;
                *)
                    fail "T2 unmerged_branch_not_candidate: worktree listed as candidate: $out" ;;
            esac
            ;;
        *)
            pass "T2 unmerged_branch_not_candidate (not listed)" ;;
    esac
}
T2_unmerged_branch_not_candidate
case_end

# ─────────────────────────────────────────────────────────────────────────────
# T3 — merged-PR + clean + stale → listed as candidate (skip-gh)
# ─────────────────────────────────────────────────────────────────────────────

case_begin "merged-clean-stale-is-candidate" "bin/sweep-worktrees.sh"
T3_merged_clean_stale_is_candidate() {
    local repo="$TMPDIR_BASE/t3-repo"
    local wpath="$TMPDIR_BASE/t3-wt"
    local wbase="$TMPDIR_BASE/t3-wbase"
    mkdir -p "$wbase"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/swept"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T3 merged_clean_stale_is_candidate: $SWEEP not found / not executable"
        return
    fi
    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" run_with_timeout 120 bash "$SWEEP" --dry-run --skip-gh-check 2>&1)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T3 merged_clean_stale_is_candidate: exit=$exit_code, out=$out"
        return
    fi
    case "$out" in
        *"feature/swept"*)
            pass "T3 merged_clean_stale_is_candidate" ;;
        *)
            fail "T3 merged_clean_stale_is_candidate: worktree not listed in: $out" ;;
    esac
}
T3_merged_clean_stale_is_candidate
case_end

# ─────────────────────────────────────────────────────────────────────────────
# T4 — same as T3 but with --apply → worktree removed from `git worktree list`
# ─────────────────────────────────────────────────────────────────────────────

case_begin "apply-removes-worktree" "bin/sweep-worktrees.sh"
T4_apply_removes_worktree() {
    local repo="$TMPDIR_BASE/t4-repo"
    local wpath="$TMPDIR_BASE/t4-wt"
    local wbase="$TMPDIR_BASE/t4-wbase"
    mkdir -p "$wbase"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/swept4"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T4 apply_removes_worktree: $SWEEP not found / not executable"
        return
    fi
    local before
    before="$(cd "$repo" && git worktree list 2>/dev/null)"
    case "$before" in
        *"feature/swept4"*) : ;;
        *)
            fail "T4 apply_removes_worktree: precondition failed — worktree not registered: $before"
            return ;;
    esac
    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" run_with_timeout 120 bash "$SWEEP" --apply --skip-gh-check 2>&1)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T4 apply_removes_worktree: exit=$exit_code, out=$out"
        return
    fi
    local after
    after="$(cd "$repo" && git worktree list 2>/dev/null)"
    case "$after" in
        *"feature/swept4"*)
            fail "T4 apply_removes_worktree: worktree still registered after --apply: $after" ;;
        *)
            pass "T4 apply_removes_worktree" ;;
    esac
}
T4_apply_removes_worktree
case_end

# ─────────────────────────────────────────────────────────────────────────────
# T5 — EPERM on a worktree dir → non-fatal, warning, worktree remains
# ─────────────────────────────────────────────────────────────────────────────

case_begin "eperm-non-fatal" "bin/sweep-worktrees.sh"
T5_eperm_non_fatal() {
    local repo="$TMPDIR_BASE/t5-repo"
    local wpath="$TMPDIR_BASE/t5-wt"
    local wbase="$TMPDIR_BASE/t5-wbase"
    mkdir -p "$wbase"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/eperm"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T5 eperm_non_fatal: $SWEEP not found / not executable"
        return
    fi
    chmod 000 "$wpath" 2>/dev/null || true
    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" run_with_timeout 120 bash "$SWEEP" --apply --skip-gh-check 2>&1)"
    exit_code=$?
    chmod -R u+rwX "$wpath" 2>/dev/null || true
    if [ "$exit_code" -ne 0 ]; then
        fail "T5 eperm_non_fatal: exit=$exit_code (expected 0), out=$out"
        return
    fi
    local after
    after="$(cd "$repo" && git worktree list 2>/dev/null)"
    case "$after" in
        *"feature/eperm"*)
            case "$out" in
                *[Ww][Aa][Rr][Nn]*|*EPERM*|*[Pp]ermission*|*skipped_eperm*)
                    pass "T5 eperm_non_fatal (remained + warned)" ;;
                *)
                    fail "T5 eperm_non_fatal: worktree remained but no warning in: $out" ;;
            esac
            ;;
        *)
            pass "T5 eperm_non_fatal (chmod ineffective; removed cleanly)" ;;
    esac
}
T5_eperm_non_fatal
case_end

# ─────────────────────────────────────────────────────────────────────────────
# T6 — stale .worktree-backup/<branch>/ dir → detected (dry-run), removed (apply)
# ─────────────────────────────────────────────────────────────────────────────

case_begin "stale-backup-detected-and-removed" "bin/sweep-worktrees.sh"
T6_stale_backup_detected_and_removed() {
    local repo="$TMPDIR_BASE/t6-repo"
    local wbase="$TMPDIR_BASE/t6-wbase"
    mkdir -p "$wbase"
    init_repo "$repo"
    local backup_dir="$repo/.worktree-backup/feature%2Fold"
    mkdir -p "$backup_dir"
    printf 'stale backup\n' > "$backup_dir/marker.txt"
    make_stale "$backup_dir"
    make_stale "$repo/.worktree-backup"
    if [ ! -x "$SWEEP" ]; then
        fail "T6 stale_backup_detected_and_removed: $SWEEP not found / not executable"
        return
    fi
    local out_dry
    out_dry="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" run_with_timeout 120 bash "$SWEEP" --dry-run --skip-gh-check 2>&1)"
    case "$out_dry" in
        *"feature%2Fold"*|*".worktree-backup"*|*"backup"*)
            : ;;
        *)
            fail "T6 stale_backup_detected_and_removed: dry-run did not mention backup: $out_dry"
            return ;;
    esac
    local out_apply exit_code
    out_apply="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" run_with_timeout 120 bash "$SWEEP" --apply --skip-gh-check 2>&1)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T6 stale_backup_detected_and_removed: --apply exit=$exit_code, out=$out_apply"
        return
    fi
    if [ -d "$backup_dir" ]; then
        fail "T6 stale_backup_detected_and_removed: backup dir still present after --apply"
    else
        pass "T6 stale_backup_detected_and_removed"
    fi
}
T6_stale_backup_detected_and_removed
case_end

# ─────────────────────────────────────────────────────────────────────────────
# T7 — --apply --ci-mode → stdout is JSON with all required keys
# ─────────────────────────────────────────────────────────────────────────────

case_begin "ci-mode-json-shape" "bin/sweep-worktrees.sh"
T7_ci_mode_json_shape() {
    local repo="$TMPDIR_BASE/t7-repo"
    local wbase="$TMPDIR_BASE/t7-wbase"
    mkdir -p "$wbase"
    init_repo "$repo"
    if [ ! -x "$SWEEP" ]; then
        fail "T7 ci_mode_json_shape: $SWEEP not found / not executable"
        return
    fi
    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" run_with_timeout 120 bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T7 ci_mode_json_shape: exit=$exit_code, out=$out"
        return
    fi
    local check
    check="$(printf '%s' "$out" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            try {
                const d = JSON.parse(b);
                const required = ['scanned','candidates','worktree_removed','branch_deleted','orphan_dirs_removed','orphan_dirs_skipped_has_git','orphan_dirs_skipped_young','orphan_dirs_skipped_registered','orphan_dirs_skipped_failed','orphan_dirs_skipped_has_files','orphan_dirs_skipped_repo_mismatch','skipped_eperm','skipped_unmerged','errors','empty_parents_candidates','empty_parents_removed','empty_parents_skipped_young','empty_parents_skipped_nonempty','empty_parents_skipped_registered'];
                const missing = required.filter(k => !(k in d));
                if (missing.length === 0) console.log('OK');
                else console.log('MISSING:' + missing.join(','));
            } catch (e) {
                console.log('PARSE_ERROR:' + e.message);
            }
        });
    " 2>/dev/null)"
    case "$check" in
        OK) pass "T7 ci_mode_json_shape" ;;
        *)  fail "T7 ci_mode_json_shape: $check; raw: $out" ;;
    esac
}
T7_ci_mode_json_shape
case_end

# ─────────────────────────────────────────────────────────────────────────────
# T29 — dirty (tracked modification) + merged + stale → skipped_dirty without --force
# ─────────────────────────────────────────────────────────────────────────────

case_begin "dirty-tracked-skipped-without-force" "bin/sweep-worktrees.sh"
T29_dirty_tracked_skipped_without_force() {
    local repo="$TMPDIR_BASE/t29-repo"
    local wpath="$TMPDIR_BASE/t29-wt"
    local wbase="$TMPDIR_BASE/t29-wbase"
    mkdir -p "$wbase"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/dirty29"
    echo "original" > "$wpath/dirty.txt"
    git -C "$wpath" add dirty.txt
    echo "modified" > "$wpath/dirty.txt"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T29 dirty_tracked_skipped_without_force: $SWEEP not found / not executable"
        return
    fi
    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" run_with_timeout 120 bash "$SWEEP" --apply --skip-gh-check --ci-mode 2>&1)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T29 dirty_tracked_skipped_without_force: exit=$exit_code, out=$out"
        return
    fi
    local after skipped
    after="$(cd "$repo" && git worktree list 2>/dev/null)"
    skipped="$(ci_field "$out" skipped_dirty)"
    case "$after" in
        *"feature/dirty29"*)
            if [ "${skipped:-0}" -ge 1 ] 2>/dev/null; then
                pass "T29 dirty_tracked_skipped_without_force (remained, skipped_dirty=$skipped)"
            else
                fail "T29 dirty_tracked_skipped_without_force: remained but skipped_dirty=$skipped in: $out"
            fi
            ;;
        *)
            fail "T29 dirty_tracked_skipped_without_force: dirty worktree was removed without --force" ;;
    esac
}
T29_dirty_tracked_skipped_without_force
case_end

# ─────────────────────────────────────────────────────────────────────────────
# T30 — dirty (tracked modification) + merged + stale + --force → removed
# ─────────────────────────────────────────────────────────────────────────────

case_begin "dirty-tracked-removed-with-force" "bin/sweep-worktrees.sh"
T30_dirty_tracked_removed_with_force() {
    local repo="$TMPDIR_BASE/t30-repo"
    local wpath="$TMPDIR_BASE/t30-wt"
    local wbase="$TMPDIR_BASE/t30-wbase"
    mkdir -p "$wbase"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/dirty30"
    echo "original" > "$wpath/dirty.txt"
    git -C "$wpath" add dirty.txt
    echo "modified" > "$wpath/dirty.txt"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T30 dirty_tracked_removed_with_force: $SWEEP not found / not executable"
        return
    fi
    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" run_with_timeout 120 bash "$SWEEP" --apply --force --skip-gh-check 2>&1)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T30 dirty_tracked_removed_with_force: exit=$exit_code, out=$out"
        return
    fi
    local after
    after="$(cd "$repo" && git worktree list 2>/dev/null)"
    case "$after" in
        *"feature/dirty30"*)
            fail "T30 dirty_tracked_removed_with_force: worktree still registered after --apply --force: $after" ;;
        *)
            pass "T30 dirty_tracked_removed_with_force" ;;
    esac
}
T30_dirty_tracked_removed_with_force
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
