#!/bin/bash
# tests/bin/feature-sweep-worktrees/orphan.sh
# Orphan-dir-sweep tests: T8, T8b, T8c, T9, T9b, T9c, T9d, T9e, T9f, T10, T11.
# Orphan-dir-sweep gates:
#   1. dir not in `git worktree list --porcelain`
#   2. no .git directory or symlink inside (a gitlink file goes to the CLI with --expect-main-root)
#   3. mtime older than --min-age-hours
#   4. dir name matches the main repo's basename
#   5. WORKTREE_NOTES.md `Main repo:` line matches current TARGET_MAIN_ROOT
# Setup: WORKTREE_BASE_DIR=<base>; orphan dir at <base>/<task>/<repo-name>. Standalone-runnable.

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
    # Gate 5 (cross-repo): notes' `Main repo:` line matches current TARGET_MAIN_ROOT
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
# T9 — orphan dir whose .git is a (dangling) SYMLINK → gate 2 skips it;
#      matching notes keep gates 3-5 from masking the skip, so the
#      orphan_dirs_skipped_has_git counter is what proves gate 2 fired.
#      A .git DIRECTORY is T9e; a .git FILE (gitlink) is T9d / T9f.
# ─────────────────────────────────────────────────────────────────────────────

T9_orphan_dir_skipped_when_has_git() {
    local repo="$TMPDIR_BASE/t9-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t9-wbase"
    local orphan="$wbase/has-git-task/$repo_name"
    mkdir -p "$orphan"
    # Git for Windows copies instead of linking unless asked for a native symlink.
    MSYS=winsymlinks:nativestrict ln -s "$TMPDIR_BASE/t9-nonexistent" "$orphan/.git" 2>/dev/null
    if [[ ! -L "$orphan/.git" ]]; then
        echo "SKIP: T9 orphan_dir_skipped_when_has_git: this host cannot create a symlink"
        return
    fi
    local repo_fwd
    repo_fwd="$(node -e "console.log(process.argv[1].replace(/\\\\/g,'/'))" -- "$repo" 2>/dev/null)"
    printf '# Worktree Notes\nMain repo: %s\n' "$repo_fwd" > "$orphan/WORKTREE_NOTES.md"
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
    local n has_git
    n="$(ci_field "$out" orphan_dirs_removed)"
    has_git="$(ci_field "$out" orphan_dirs_skipped_has_git)"
    if [[ "$n" == "0" && "$has_git" == "1" ]]; then
        pass "T9 orphan_dir_skipped_when_has_git (removed==0, skipped_has_git==1, dir kept)"
    else
        fail "T9 orphan_dir_skipped_when_has_git: removed=$n skipped_has_git=$has_git, raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T9f (#2875) — a gitlink FILE whose ownership cannot be proven (its gitdir
#       points at no repository, so it is not an unregistered leftover) passes
#       gates 2-5 with matching notes, but the CLI refuses it under
#       --expect-main-root: removed==0, skipped_failed==1, dir kept.
# ─────────────────────────────────────────────────────────────────────────────

T9f_unproven_gitlink_left_in_place() {
    local repo="$TMPDIR_BASE/t9f-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t9f-wbase"
    local orphan="$wbase/unproven-task/$repo_name"
    mkdir -p "$orphan"
    local absent_fwd repo_fwd
    absent_fwd="$(node -e "console.log(process.argv[1].replace(/\\\\/g,'/'))" -- "$TMPDIR_BASE/t9f-absent/.git/worktrees/x" 2>/dev/null)"
    printf 'gitdir: %s\n' "$absent_fwd" > "$orphan/.git"
    repo_fwd="$(node -e "console.log(process.argv[1].replace(/\\\\/g,'/'))" -- "$repo" 2>/dev/null)"
    printf '# Worktree Notes\nMain repo: %s\n' "$repo_fwd" > "$orphan/WORKTREE_NOTES.md"
    make_stale "$orphan"
    make_stale "$wbase/unproven-task"

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T9f unproven_gitlink_left_in_place: exit=$exit_code, out=$out"
        return
    fi
    local removed failed has_git
    removed="$(ci_field "$out" orphan_dirs_removed)"
    failed="$(ci_field "$out" orphan_dirs_skipped_failed)"
    has_git="$(ci_field "$out" orphan_dirs_skipped_has_git)"
    if [[ -f "$orphan/.git" && "$removed" == "0" && "$failed" == "1" && "$has_git" == "0" ]]; then
        pass "T9f unproven_gitlink_left_in_place (removed==0, skipped_failed==1, dir kept)"
    else
        fail "T9f unproven_gitlink_left_in_place: removed=$removed skipped_failed=$failed skipped_has_git=$has_git dir_kept=$([[ -f "$orphan/.git" ]] && echo yes || echo no), raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T9b (Gate 5) — orphan dir's WORKTREE_NOTES.md has a `Main repo:` line
#                that does NOT match the current TARGET_MAIN_ROOT → SKIPPED;
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
# T9d (#2875 / #322) — a WE-11 leftover: the dir keeps its `.git` gitlink but
#       git no longer lists it (admin dir pruned). Gate (2) no longer skips a
#       gitlink; the CLI gets --expect-main-root and removes the proven leftover.
# ─────────────────────────────────────────────────────────────────────────────

T9d_gitlink_leftover_collected() {
    local repo="$TMPDIR_BASE/t9d-repo"
    init_repo "$repo"
    git -C "$repo" config core.hooksPath /dev/null
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t9d-wbase"
    local orphan="$wbase/leftover-task/$repo_name"
    mkdir -p "$wbase/leftover-task"
    add_worktree "$repo" "$orphan" "feature/t9d"
    # WE-11 failure: the dir survives while `git worktree prune` drops its admin dir.
    mv "$orphan" "$orphan.hidden"
    git -C "$repo" worktree prune
    mv "$orphan.hidden" "$orphan"
    if [[ ! -f "$orphan/.git" ]]; then
        fail "T9d gitlink_leftover_collected: fixture lost its gitlink"
        return
    fi
    local repo_fwd
    repo_fwd="$(node -e "console.log(process.argv[1].replace(/\\\\/g,'/'))" -- "$repo" 2>/dev/null)"
    printf '# Worktree Notes\nMain repo: %s\n' "$repo_fwd" > "$orphan/WORKTREE_NOTES.md"
    make_stale "$orphan"
    make_stale "$wbase/leftover-task"

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T9d gitlink_leftover_collected: exit=$exit_code, out=$out"
        return
    fi
    local removed
    removed="$(ci_field "$out" orphan_dirs_removed)"
    if [[ "$removed" == "1" && ! -d "$orphan" ]]; then
        pass "T9d gitlink_leftover_collected (removed==1, dir gone)"
    else
        fail "T9d gitlink_leftover_collected: removed=$removed dir_exists=$([[ -d "$orphan" ]] && echo yes || echo no), raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T9e (#2875) — a candidate whose `.git` is a DIRECTORY is its own repo, not a
#       leftover: gate (2) still skips it even with a matching `Main repo:`.
# ─────────────────────────────────────────────────────────────────────────────

T9e_git_directory_still_skipped() {
    local repo="$TMPDIR_BASE/t9e-repo"
    init_repo "$repo"
    local repo_name
    repo_name="$(basename "$repo")"
    local wbase="$TMPDIR_BASE/t9e-wbase"
    local orphan="$wbase/repo-task/$repo_name"
    mkdir -p "$orphan"
    git init -q "$orphan"
    git -C "$orphan" config core.hooksPath /dev/null
    local repo_fwd
    repo_fwd="$(node -e "console.log(process.argv[1].replace(/\\\\/g,'/'))" -- "$repo" 2>/dev/null)"
    printf '# Worktree Notes\nMain repo: %s\n' "$repo_fwd" > "$orphan/WORKTREE_NOTES.md"
    make_stale "$orphan"
    make_stale "$wbase/repo-task"

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "T9e git_directory_still_skipped: exit=$exit_code, out=$out"
        return
    fi
    local removed has_git
    removed="$(ci_field "$out" orphan_dirs_removed)"
    has_git="$(ci_field "$out" orphan_dirs_skipped_has_git)"
    if [[ -d "$orphan/.git" && "$removed" == "0" && "$has_git" == "1" ]]; then
        pass "T9e git_directory_still_skipped (removed==0, skipped_has_git==1)"
    else
        fail "T9e git_directory_still_skipped: removed=$removed skipped_has_git=$has_git, raw=$out"
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
T9d_gitlink_leftover_collected
T9e_git_directory_still_skipped
T9f_unproven_gitlink_left_in_place
T10_orphan_dir_skipped_when_too_young

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
