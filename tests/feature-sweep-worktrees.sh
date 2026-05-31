#!/bin/bash
# tests/feature-sweep-worktrees.sh
# Tests: bin/sweep-worktrees.sh
# Tags: sweep-worktrees
#
# Tests for bin/sweep-worktrees.sh — the zombie-sweep mechanism that replaces
# the Phase 1 deferred-cleanup model.
#
# Contract under test:
#   bin/sweep-worktrees.sh [--dry-run|--apply] [--ci-mode] [--skip-gh-check]
#
# A "candidate" for sweep is a linked worktree whose:
#   - branch has a merged PR (gh pr view says merged), OR can be force-skipped
#     via --skip-gh-check / SWEEP_SKIP_GH=1
#   - worktree directory is clean (no uncommitted changes)
#   - mtime is older than some threshold (e.g. 24h; tests use `touch -d`)
#
# Outputs:
#   --dry-run    → human-readable list (count + per-candidate line)
#   --ci-mode    → JSON with keys: scanned, candidates, worktree_removed,
#                  branch_deleted, orphan_dirs_removed, skipped_eperm,
#                  skipped_unmerged, errors
#
# Note: `marker_cleaned` was removed in #503 along with the
# pending-branch-delete- marker mechanism. `orphan_dirs_removed` replaces
# it: counts directories under <WORKTREE_BASE_DIR>/<task>/<repo> that pass
# all four gates (not in git worktree list, no .git, old enough, name matches
# main repo) and were removed by --apply.
#
# Source bin/sweep-worktrees.sh does NOT exist yet — all tests are RED
# until the implementation step lands. Test-first.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$AGENTS_DIR/bin/sweep-worktrees.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Create a bare-ish source repo at $1 with one commit on main.
init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
}

# Add a linked worktree at $2 on branch $3 from source repo $1.
add_worktree() {
    local repo="$1" wpath="$2" branch="$3"
    (cd "$repo" && git worktree add -q -b "$branch" "$wpath" 2>/dev/null)
}

# Backdate the worktree directory mtime to look "stale" (older than threshold).
make_stale() {
    local p="$1"
    # 30 days ago
    if command -v touch >/dev/null 2>&1; then
        touch -d "30 days ago" "$p" 2>/dev/null || touch -t 202401010000 "$p" 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T1 — no linked worktrees → zero candidates
# ─────────────────────────────────────────────────────────────────────────────

T1_no_worktrees_zero_candidates() {
    local repo="$TMPDIR_BASE/t1-repo"
    init_repo "$repo"
    if [ ! -x "$SWEEP" ]; then
        fail "T1 no_worktrees_zero_candidates: $SWEEP not found / not executable"
        return
    fi
    local out exit_code
    out="$(cd "$repo" && run_with_timeout bash "$SWEEP" --dry-run 2>&1)"
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

# ─────────────────────────────────────────────────────────────────────────────
# T2 — linked worktree on branch with NO merged PR → not a candidate
# ─────────────────────────────────────────────────────────────────────────────

T2_unmerged_branch_not_candidate() {
    local repo="$TMPDIR_BASE/t2-repo"
    local wpath="$TMPDIR_BASE/t2-wt"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/unmerged"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T2 unmerged_branch_not_candidate: $SWEEP not found / not executable"
        return
    fi
    local out exit_code
    # Real gh CLI on an offline / unauthenticated temp repo will report
    # "no PR" — implementation must treat that as "not merged" → skip.
    out="$(cd "$repo" && run_with_timeout bash "$SWEEP" --dry-run 2>&1)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T2 unmerged_branch_not_candidate: exit=$exit_code, out=$out"
        return
    fi
    case "$out" in
        *"feature/unmerged"*)
            # If the worktree appears, it must be marked as skipped, not a candidate.
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

# ─────────────────────────────────────────────────────────────────────────────
# T3 — merged-PR + clean + stale → listed as candidate (skip-gh)
# ─────────────────────────────────────────────────────────────────────────────

T3_merged_clean_stale_is_candidate() {
    local repo="$TMPDIR_BASE/t3-repo"
    local wpath="$TMPDIR_BASE/t3-wt"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/swept"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T3 merged_clean_stale_is_candidate: $SWEEP not found / not executable"
        return
    fi
    local out exit_code
    # SWEEP_SKIP_GH=1 bypasses the GitHub merged-check: treat all branches as merged.
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 run_with_timeout bash "$SWEEP" --dry-run --skip-gh-check 2>&1)"
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

# ─────────────────────────────────────────────────────────────────────────────
# T4 — same as T3 but with --apply → worktree removed from `git worktree list`
# ─────────────────────────────────────────────────────────────────────────────

T4_apply_removes_worktree() {
    local repo="$TMPDIR_BASE/t4-repo"
    local wpath="$TMPDIR_BASE/t4-wt"
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
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 run_with_timeout bash "$SWEEP" --apply --skip-gh-check 2>&1)"
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

# ─────────────────────────────────────────────────────────────────────────────
# T5 — EPERM on a worktree dir → non-fatal, warning, worktree remains
# ─────────────────────────────────────────────────────────────────────────────

T5_eperm_non_fatal() {
    local repo="$TMPDIR_BASE/t5-repo"
    local wpath="$TMPDIR_BASE/t5-wt"
    init_repo "$repo"
    add_worktree "$repo" "$wpath" "feature/eperm"
    make_stale "$wpath"
    if [ ! -x "$SWEEP" ]; then
        fail "T5 eperm_non_fatal: $SWEEP not found / not executable"
        return
    fi
    chmod 000 "$wpath" 2>/dev/null || true
    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 run_with_timeout bash "$SWEEP" --apply --skip-gh-check 2>&1)"
    exit_code=$?
    chmod -R u+rwX "$wpath" 2>/dev/null || true
    if [ "$exit_code" -ne 0 ]; then
        fail "T5 eperm_non_fatal: exit=$exit_code (expected 0), out=$out"
        return
    fi
    # On systems where chmod 000 doesn't restrict the current user (e.g. Windows
    # via Git Bash, root), git worktree remove may still succeed. Accept either:
    #   (a) worktree remains AND there is a warning, OR
    #   (b) it was removed cleanly (chmod ineffective)
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

# ─────────────────────────────────────────────────────────────────────────────
# T6 — stale .worktree-backup/<branch>/ dir → detected (dry-run), removed (apply)
# ─────────────────────────────────────────────────────────────────────────────

T6_stale_backup_detected_and_removed() {
    local repo="$TMPDIR_BASE/t6-repo"
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
    out_dry="$(cd "$repo" && SWEEP_SKIP_GH=1 run_with_timeout bash "$SWEEP" --dry-run --skip-gh-check 2>&1)"
    case "$out_dry" in
        *"feature%2Fold"*|*".worktree-backup"*|*"backup"*)
            : ;;
        *)
            fail "T6 stale_backup_detected_and_removed: dry-run did not mention backup: $out_dry"
            return ;;
    esac
    local out_apply exit_code
    out_apply="$(cd "$repo" && SWEEP_SKIP_GH=1 run_with_timeout bash "$SWEEP" --apply --skip-gh-check 2>&1)"
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

# ─────────────────────────────────────────────────────────────────────────────
# T7 — --apply --ci-mode → stdout is JSON with all required keys
# ─────────────────────────────────────────────────────────────────────────────

T7_ci_mode_json_shape() {
    local repo="$TMPDIR_BASE/t7-repo"
    init_repo "$repo"
    if [ ! -x "$SWEEP" ]; then
        fail "T7 ci_mode_json_shape: $SWEEP not found / not executable"
        return
    fi
    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
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
                const required = ['scanned','candidates','worktree_removed','branch_deleted','orphan_dirs_removed','orphan_dirs_skipped_has_git','orphan_dirs_skipped_young','orphan_dirs_skipped_registered','orphan_dirs_skipped_failed','orphan_dirs_skipped_has_files','orphan_dirs_skipped_repo_mismatch','skipped_eperm','skipped_unmerged','errors'];
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

# ─────────────────────────────────────────────────────────────────────────────
# Orphan-dir-sweep helper. The four gates:
#   1. dir not in `git worktree list --porcelain`
#   2. no .git entry (file or directory) inside
#   3. mtime older than --min-age-hours
#   4. dir name matches the main repo's basename
# Setup: WORKTREE_BASE_DIR=<base>; orphan dir at <base>/<task>/<repo-name>.
# ─────────────────────────────────────────────────────────────────────────────

ci_field() {
    # $1: JSON, $2: key → prints integer value or empty
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            try {
                const d = JSON.parse(b);
                if (process.argv[1] in d) console.log(d[process.argv[1]]);
            } catch (e) { /* swallow */ }
        });
    " -- "$2" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# T8 — orphan dir satisfying all 4 gates → --apply removes it;
#      orphan_dirs_removed counter == 1.
# ─────────────────────────────────────────────────────────────────────────────

T8_orphan_dir_removed_when_all_gates_pass() {
    local repo="$TMPDIR_BASE/t8-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t8-wbase"
    local orphan="$wbase/orphan-task/$repo_name"
    mkdir -p "$orphan"
    # Gate 4 (contents) accepts: WORKTREE_NOTES.md only — no other files/dirs.
    # Gate 5 (cross-repo): notes' `Main repo:` line matches current MAIN_ROOT
    # (forward-slash-normalized form of the source repo path).
    local repo_fwd
    repo_fwd="$(node -e "console.log(process.argv[1].replace(/\\\\/g,'/'))" -- "$repo" 2>/dev/null)"
    printf '# Worktree Notes\nMain repo: %s\n' "$repo_fwd" > "$orphan/WORKTREE_NOTES.md"
    make_stale "$orphan"
    make_stale "$wbase/orphan-task"

    if [ ! -x "$SWEEP" ]; then
        fail "T8 orphan_dir_removed_when_all_gates_pass: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T8 orphan_dir_removed_when_all_gates_pass: exit=$exit_code, out=$out"
        return
    fi

    if [ -d "$orphan" ]; then
        fail "T8 orphan_dir_removed_when_all_gates_pass: dir still present after --apply"
        return
    fi
    local n
    n="$(ci_field "$out" orphan_dirs_removed)"
    if [ "$n" = "1" ]; then
        pass "T8 orphan_dir_removed_when_all_gates_pass (counter==1)"
    else
        fail "T8 orphan_dir_removed_when_all_gates_pass: orphan_dirs_removed=$n, raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T9 — orphan dir contains a .git FILE → gate 2 fails → skipped;
#      directory still exists after --apply; orphan_dirs_removed == 0.
# ─────────────────────────────────────────────────────────────────────────────

T9_orphan_dir_skipped_when_has_git() {
    local repo="$TMPDIR_BASE/t9-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t9-wbase"
    local orphan="$wbase/has-git-task/$repo_name"
    mkdir -p "$orphan"
    printf 'gitdir: /nonexistent\n' > "$orphan/.git"
    make_stale "$orphan"
    make_stale "$wbase/has-git-task"

    if [ ! -x "$SWEEP" ]; then
        fail "T9 orphan_dir_skipped_when_has_git: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T9 orphan_dir_skipped_when_has_git: exit=$exit_code, out=$out"
        return
    fi
    if [ ! -d "$orphan" ]; then
        fail "T9 orphan_dir_skipped_when_has_git: dir was removed despite .git presence"
        return
    fi
    local n
    n="$(ci_field "$out" orphan_dirs_removed)"
    if [ "$n" = "0" ]; then
        pass "T9 orphan_dir_skipped_when_has_git (counter==0, dir kept)"
    else
        fail "T9 orphan_dir_skipped_when_has_git: orphan_dirs_removed=$n, raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T8b — orphan dir with extra files + valid WORKTREE_NOTES.md (Main repo: match)
#       → Gate 4 removed; Gate 5 ownership proof is sufficient → REMOVED.
#       Full checkouts left by partial `git worktree remove` (no .git, all repo
#       files) are safe to delete when ownership is proven via WORKTREE_NOTES.md.
# ─────────────────────────────────────────────────────────────────────────────

T8b_orphan_dir_removed_when_extra_files_but_ownership_proven() {
    local repo="$TMPDIR_BASE/t8b-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t8b-wbase"
    local orphan="$wbase/extra-task/$repo_name"
    mkdir -p "$orphan"
    local repo_fwd
    repo_fwd="$(node -e "console.log(process.argv[1].replace(/\\\\/g,'/'))" -- "$repo" 2>/dev/null)"
    printf '# Worktree Notes\nMain repo: %s\n' "$repo_fwd" > "$orphan/WORKTREE_NOTES.md"
    # Extra file simulating full checkout left by partial git worktree remove.
    printf 'extra\n' > "$orphan/leftover.txt"
    make_stale "$orphan"
    make_stale "$wbase/extra-task"

    if [ ! -x "$SWEEP" ]; then
        fail "T8b orphan_dir_removed_when_extra_files_but_ownership_proven: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T8b orphan_dir_removed_when_extra_files_but_ownership_proven: exit=$exit_code, out=$out"
        return
    fi
    local n
    n="$(ci_field "$out" orphan_dirs_removed)"
    if [ "$n" = "1" ] && [ ! -d "$orphan" ]; then
        pass "T8b orphan_dir_removed_when_extra_files_but_ownership_proven (removed==1, dir gone)"
    else
        fail "T8b orphan_dir_removed_when_extra_files_but_ownership_proven: removed=$n dir_exists=$([[ -d "$orphan" ]] && echo yes || echo no), raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T8c — orphan dir completely empty (no WORKTREE_NOTES.md, no other files)
#       → Gate 5 SKIPS (no `Main repo:` ownership proof available);
#          increments repo_mismatch counter. Empty dirs without notes are
#          NOT eligible for cleanup — only dirs with a matching `Main repo:`
#          field qualify.
# ─────────────────────────────────────────────────────────────────────────────

T8c_orphan_dir_skipped_when_completely_empty() {
    local repo="$TMPDIR_BASE/t8c-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t8c-wbase"
    local orphan="$wbase/empty-task/$repo_name"
    mkdir -p "$orphan"
    make_stale "$orphan"
    make_stale "$wbase/empty-task"

    if [ ! -x "$SWEEP" ]; then
        fail "T8c orphan_dir_skipped_when_completely_empty: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T8c orphan_dir_skipped_when_completely_empty: exit=$exit_code, out=$out"
        return
    fi
    if [ ! -d "$orphan" ]; then
        fail "T8c orphan_dir_skipped_when_completely_empty: dir was removed but should be skipped"
        return
    fi
    local removed mismatch
    removed="$(ci_field "$out" orphan_dirs_removed)"
    mismatch="$(ci_field "$out" orphan_dirs_skipped_repo_mismatch)"
    if [ "$removed" = "0" ] && [ "$mismatch" = "1" ]; then
        pass "T8c orphan_dir_skipped_when_completely_empty (removed=0, repo_mismatch=1)"
    else
        fail "T8c orphan_dir_skipped_when_completely_empty: removed=$removed, repo_mismatch=$mismatch, raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T9b (Gate 5) — orphan dir's WORKTREE_NOTES.md has a `Main repo:` line
#                that does NOT match the current MAIN_ROOT → SKIPPED;
#                counter orphan_dirs_skipped_repo_mismatch == 1.
# ─────────────────────────────────────────────────────────────────────────────

T9b_orphan_dir_skipped_when_main_repo_mismatch() {
    local repo="$TMPDIR_BASE/t9b-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t9b-wbase"
    local orphan="$wbase/mismatch-task/$repo_name"
    mkdir -p "$orphan"
    # `Main repo:` points to a different path — Gate 5 must reject.
    printf '# Worktree Notes\nMain repo: /some/other/main/repo\n' > "$orphan/WORKTREE_NOTES.md"
    make_stale "$orphan"
    make_stale "$wbase/mismatch-task"

    if [ ! -x "$SWEEP" ]; then
        fail "T9b orphan_dir_skipped_when_main_repo_mismatch: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T9b orphan_dir_skipped_when_main_repo_mismatch: exit=$exit_code, out=$out"
        return
    fi
    if [ ! -d "$orphan" ]; then
        fail "T9b orphan_dir_skipped_when_main_repo_mismatch: dir removed despite repo mismatch"
        return
    fi
    local n n2
    n="$(ci_field "$out" orphan_dirs_removed)"
    n2="$(ci_field "$out" orphan_dirs_skipped_repo_mismatch)"
    if [ "$n" = "0" ] && [ "$n2" = "1" ]; then
        pass "T9b orphan_dir_skipped_when_main_repo_mismatch (removed==0, skipped_repo_mismatch==1)"
    else
        fail "T9b orphan_dir_skipped_when_main_repo_mismatch: removed=$n skipped_repo_mismatch=$n2, raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T9c (legacy notes) — orphan dir's WORKTREE_NOTES.md has NO `Main repo:`
#                      line → Gate 5 SKIPS (basename alone is not unique
#                      ownership proof; legacy notes do NOT fall through to
#                      basename match). Increments repo_mismatch counter.
# ─────────────────────────────────────────────────────────────────────────────

T9c_orphan_dir_skipped_when_legacy_notes_missing_main_repo() {
    local repo="$TMPDIR_BASE/t9c-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t9c-wbase"
    local orphan="$wbase/legacy-task/$repo_name"
    mkdir -p "$orphan"
    # Legacy notes — no `Main repo:` line. Even though basename matches,
    # Gate 5 now requires the `Main repo:` field as ownership proof.
    printf '# Worktree Notes\nBranch: feature/legacy\n' > "$orphan/WORKTREE_NOTES.md"
    make_stale "$orphan"
    make_stale "$wbase/legacy-task"

    if [ ! -x "$SWEEP" ]; then
        fail "T9c orphan_dir_skipped_when_legacy_notes_missing_main_repo: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T9c orphan_dir_skipped_when_legacy_notes_missing_main_repo: exit=$exit_code, out=$out"
        return
    fi
    if [ ! -d "$orphan" ]; then
        fail "T9c orphan_dir_skipped_when_legacy_notes_missing_main_repo: dir was removed but should be skipped"
        return
    fi
    local removed mismatch
    removed="$(ci_field "$out" orphan_dirs_removed)"
    mismatch="$(ci_field "$out" orphan_dirs_skipped_repo_mismatch)"
    if [ "$removed" = "0" ] && [ "$mismatch" = "1" ]; then
        pass "T9c orphan_dir_skipped_when_legacy_notes_missing_main_repo (removed=0, repo_mismatch=1)"
    else
        fail "T9c orphan_dir_skipped_when_legacy_notes_missing_main_repo: removed=$removed, repo_mismatch=$mismatch, raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T10 — orphan dir younger than --min-age-hours → gate 3 fails →
#       skipped; dir still exists.
# ─────────────────────────────────────────────────────────────────────────────

T10_orphan_dir_skipped_when_too_young() {
    local repo="$TMPDIR_BASE/t10-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t10-wbase"
    local orphan="$wbase/young-task/$repo_name"
    mkdir -p "$orphan"
    printf 'fresh\n' > "$orphan/leftover.txt"
    # Explicitly bump mtime to now (default is "now", but be defensive).
    touch "$orphan" 2>/dev/null || true
    touch "$wbase/young-task" 2>/dev/null || true

    if [ ! -x "$SWEEP" ]; then
        fail "T10 orphan_dir_skipped_when_too_young: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    # --min-age-hours 1 → freshly-created dir must be skipped.
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check --min-age-hours 1 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T10 orphan_dir_skipped_when_too_young: exit=$exit_code, out=$out"
        return
    fi
    if [ ! -d "$orphan" ]; then
        fail "T10 orphan_dir_skipped_when_too_young: dir was removed despite being too young"
        return
    fi
    local n
    n="$(ci_field "$out" orphan_dirs_removed)"
    if [ "$n" = "0" ]; then
        pass "T10 orphan_dir_skipped_when_too_young (counter==0, dir kept)"
    else
        fail "T10 orphan_dir_skipped_when_too_young: orphan_dirs_removed=$n, raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T11 — registry fetch failure: `git worktree list --porcelain` fails →
#       scan pass aborts with WARNING on stderr; orphan_dirs_removed == 0.
#       Simulated by pointing GIT_DIR at a nonexistent path.
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
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

T1_no_worktrees_zero_candidates
T2_unmerged_branch_not_candidate
T3_merged_clean_stale_is_candidate
T4_apply_removes_worktree
T5_eperm_non_fatal
T6_stale_backup_detected_and_removed
T7_ci_mode_json_shape
T8_orphan_dir_removed_when_all_gates_pass
T8b_orphan_dir_removed_when_extra_files_but_ownership_proven
T8c_orphan_dir_skipped_when_completely_empty
T9_orphan_dir_skipped_when_has_git
T9b_orphan_dir_skipped_when_main_repo_mismatch
T9c_orphan_dir_skipped_when_legacy_notes_missing_main_repo
T10_orphan_dir_skipped_when_too_young
T11_registry_fetch_failure_aborts_scan
T12_is_pr_merged_stub_true_detected_as_candidate
T13_is_pr_merged_stub_false_not_candidate
T14_is_pr_merged_gh_error_warns_and_skips

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
