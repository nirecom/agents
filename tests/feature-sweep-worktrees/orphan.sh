#!/bin/bash
# tests/feature-sweep-worktrees/orphan.sh
# Orphan-dir-sweep tests: T8, T8b, T8c, T9, T9b, T9c, T10, T11.
#
# Orphan-dir-sweep gates:
#   1. dir not in `git worktree list --porcelain`
#   2. no .git entry (file or directory) inside
#   3. mtime older than --min-age-hours
#   4. dir name matches the main repo's basename
#   5. WORKTREE_NOTES.md `Main repo:` line matches current MAIN_ROOT
# Setup: WORKTREE_BASE_DIR=<base>; orphan dir at <base>/<task>/<repo-name>.
#
# Standalone-runnable; sourced helpers live in _lib.sh.

# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T8 — orphan dir satisfying all gates → --apply removes it;
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
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T8_orphan_dir_removed_when_all_gates_pass
T8b_orphan_dir_removed_when_extra_files_but_ownership_proven
T8c_orphan_dir_skipped_when_completely_empty
T9_orphan_dir_skipped_when_has_git
T9b_orphan_dir_skipped_when_main_repo_mismatch
T9c_orphan_dir_skipped_when_legacy_notes_missing_main_repo
T10_orphan_dir_skipped_when_too_young

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
