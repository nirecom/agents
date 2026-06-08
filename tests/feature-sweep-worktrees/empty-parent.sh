#!/bin/bash
# tests/feature-sweep-worktrees/empty-parent.sh
# Empty depth-1 parent sweep tests (#809): T15..T21.
# Standalone-runnable; sourced helpers live in _lib.sh.

# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T15 — empty depth-1 parent under WORKTREE_BASE_DIR, backdated, dry-run
#       → empty_parents_candidates>=1
# ─────────────────────────────────────────────────────────────────────────────

T15_empty_parent_dry_run_candidate() {
    local repo="$TMPDIR_BASE/t15-repo"
    init_repo "$repo"
    local wbase="$TMPDIR_BASE/t15-wbase"
    local orphan_parent="$wbase/orphan-task"
    mkdir -p "$orphan_parent"
    make_stale "$orphan_parent"

    if [ ! -x "$SWEEP" ]; then
        fail "T15 empty_parent_dry_run_candidate: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T15 empty_parent_dry_run_candidate: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" empty_parents_candidates)"
    if [ "${n:-0}" -ge 1 ] 2>/dev/null && [ -d "$orphan_parent" ]; then
        pass "T15 empty_parent_dry_run_candidate (empty_parents_candidates>=1, dir preserved)"
    else
        fail "T15 empty_parent_dry_run_candidate: empty_parents_candidates=${n:-?}, exists=$([ -d "$orphan_parent" ] && echo y || echo n), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T16 — empty depth-1 parent, --apply → dir removed, empty_parents_removed=1
# ─────────────────────────────────────────────────────────────────────────────

T16_empty_parent_apply_removed() {
    local repo="$TMPDIR_BASE/t16-repo"
    init_repo "$repo"
    local wbase="$TMPDIR_BASE/t16-wbase"
    local orphan_parent="$wbase/orphan-task-16"
    mkdir -p "$orphan_parent"
    make_stale "$orphan_parent"

    if [ ! -x "$SWEEP" ]; then
        fail "T16 empty_parent_apply_removed: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T16 empty_parent_apply_removed: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" empty_parents_removed)"
    if [ "${n:-0}" = "1" ] && [ ! -d "$orphan_parent" ]; then
        pass "T16 empty_parent_apply_removed (empty_parents_removed=1, dir gone)"
    else
        fail "T16 empty_parent_apply_removed: empty_parents_removed=${n:-?}, exists=$([ -d "$orphan_parent" ] && echo y || echo n), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T17 — non-empty depth-1 parent → empty_parents_skipped_nonempty>=1,
#       parent dir still exists
# ─────────────────────────────────────────────────────────────────────────────

T17_nonempty_parent_skipped() {
    local repo="$TMPDIR_BASE/t17-repo"
    init_repo "$repo"
    local wbase="$TMPDIR_BASE/t17-wbase"
    local nonempty_parent="$wbase/nonempty-task"
    mkdir -p "$nonempty_parent/somechild"
    make_stale "$nonempty_parent/somechild"
    make_stale "$nonempty_parent"

    if [ ! -x "$SWEEP" ]; then
        fail "T17 nonempty_parent_skipped: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T17 nonempty_parent_skipped: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" empty_parents_skipped_nonempty)"
    if [ "${n:-0}" -ge 1 ] 2>/dev/null && [ -d "$nonempty_parent" ]; then
        pass "T17 nonempty_parent_skipped (empty_parents_skipped_nonempty>=1, parent preserved)"
    else
        fail "T17 nonempty_parent_skipped: empty_parents_skipped_nonempty=${n:-?}, exists=$([ -d "$nonempty_parent" ] && echo y || echo n), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T18 — fresh empty parent (mtime=now) → empty_parents_skipped_young>=1,
#       dir still exists
# ─────────────────────────────────────────────────────────────────────────────

T18_fresh_empty_parent_skipped_young() {
    local repo="$TMPDIR_BASE/t18-repo"
    init_repo "$repo"
    local wbase="$TMPDIR_BASE/t18-wbase"
    local fresh_parent="$wbase/fresh-task"
    mkdir -p "$fresh_parent"
    touch "$fresh_parent" 2>/dev/null || true

    if [ ! -x "$SWEEP" ]; then
        fail "T18 fresh_empty_parent_skipped_young: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T18 fresh_empty_parent_skipped_young: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" empty_parents_skipped_young)"
    if [ "${n:-0}" -ge 1 ] 2>/dev/null && [ -d "$fresh_parent" ]; then
        pass "T18 fresh_empty_parent_skipped_young (empty_parents_skipped_young>=1, dir preserved)"
    else
        fail "T18 fresh_empty_parent_skipped_young: empty_parents_skipped_young=${n:-?}, exists=$([ -d "$fresh_parent" ] && echo y || echo n), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T19 — same-repo registered-worktree guard: depth-1 parent has a registered
#       linked worktree inside; physical leaf removed so parent appears empty.
#       empty_parents_skipped_registered>=1, parent kept.
# ─────────────────────────────────────────────────────────────────────────────

T19_same_repo_registered_worktree_guards_parent() {
    local repo="$TMPDIR_BASE/t19-repo"
    init_repo "$repo"
    local wbase="$TMPDIR_BASE/t19-wbase"
    local repo_name
    repo_name="$(basename "$repo")"
    local task_parent="$wbase/reg-task"
    local leaf="$task_parent/$repo_name"
    mkdir -p "$task_parent"
    # Register a linked worktree at leaf path.
    add_worktree "$repo" "$leaf" "feature/reg-t19"
    # Remove the physical leaf directory so the parent appears empty,
    # but the worktree registry still references it.
    rm -rf "$leaf" 2>/dev/null || chmod -R u+rwX "$leaf" 2>/dev/null && rm -rf "$leaf"
    make_stale "$task_parent"

    if [ ! -x "$SWEEP" ]; then
        fail "T19 same_repo_registered_worktree_guards_parent: $SWEEP not found / not executable"
        return
    fi

    local out exit_code json_line
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    # `git branch -D` echoes to stdout; extract only the JSON line for parsing.
    json_line="$(printf '%s\n' "$out" | grep -E '^\{.*\}$' | tail -1)"

    if [ "$exit_code" -ne 0 ]; then
        fail "T19 same_repo_registered_worktree_guards_parent: exit=$exit_code, out=$out"
        return
    fi

    local cands skipped
    cands="$(ci_field "$json_line" empty_parents_candidates)"
    skipped="$(ci_field "$json_line" empty_parents_skipped_registered)"

    if [ "${cands:-0}" = "0" ] && [ "${skipped:-0}" -ge 1 ] 2>/dev/null && [ -d "$task_parent" ]; then
        pass "T19 same_repo_registered_worktree_guards_parent (skipped_registered>=1, parent kept)"
    else
        fail "T19 same_repo_registered_worktree_guards_parent: empty_parents_candidates=${cands:-?} empty_parents_skipped_registered=${skipped:-?} exists=$([ -d "$task_parent" ] && echo y || echo n), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T20 — cross-repo registered-worktree guard: register a worktree of repoB
#       inside a depth-1 parent; sweep runs from repoA's context.
#       Cross-repo discovery must protect the parent.
# ─────────────────────────────────────────────────────────────────────────────

T20_cross_repo_registered_worktree_guards_parent() {
    local repoA="$TMPDIR_BASE/t20-repoA"
    local repoB="$TMPDIR_BASE/t20-repoB"
    init_repo "$repoA"
    init_repo "$repoB"
    local wbase="$TMPDIR_BASE/t20-wbase"
    local task_parent="$wbase/cross-task"
    local leaf="$task_parent/repoB-leaf"
    mkdir -p "$task_parent"
    # Register a linked worktree of repoB at leaf path.
    add_worktree "$repoB" "$leaf" "feature/cross-t20"
    # Remove leaf so parent appears empty.
    rm -rf "$leaf" 2>/dev/null || chmod -R u+rwX "$leaf" 2>/dev/null && rm -rf "$leaf"
    # Anchor leaf: a second repoB worktree under wbase that survives, so the
    # cross-repo scan can discover repoB via this leaf's git-common-dir and then
    # query repoB's registry (which still references the removed leaf above).
    local anchor_parent="$wbase/anchor-task"
    local anchor_leaf="$anchor_parent/repoB-anchor"
    mkdir -p "$anchor_parent"
    add_worktree "$repoB" "$anchor_leaf" "feature/cross-t20-anchor"
    make_stale "$task_parent"

    if [ ! -x "$SWEEP" ]; then
        fail "T20 cross_repo_registered_worktree_guards_parent: $SWEEP not found / not executable"
        return
    fi

    # Run sweep from repoA context, but MAIN_ROOT explicitly set to repoA.
    # The script must discover repoB's worktree registry via cross-repo scan
    # under WORKTREE_BASE_DIR.
    local out exit_code json_line
    out="$(cd "$repoA" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" SWEEP_AGE_DAYS=1 \
        MAIN_ROOT="$repoA" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?
    json_line="$(printf '%s\n' "$out" | grep -E '^\{.*\}$' | tail -1)"

    if [ "$exit_code" -ne 0 ]; then
        fail "T20 cross_repo_registered_worktree_guards_parent: exit=$exit_code, out=$out"
        return
    fi

    local cands skipped
    cands="$(ci_field "$json_line" empty_parents_candidates)"
    skipped="$(ci_field "$json_line" empty_parents_skipped_registered)"

    if [ "${cands:-0}" = "0" ] && [ "${skipped:-0}" -ge 1 ] 2>/dev/null && [ -d "$task_parent" ]; then
        pass "T20 cross_repo_registered_worktree_guards_parent (skipped_registered>=1, parent kept)"
    else
        fail "T20 cross_repo_registered_worktree_guards_parent: empty_parents_candidates=${cands:-?} empty_parents_skipped_registered=${skipped:-?} exists=$([ -d "$task_parent" ] && echo y || echo n), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T21 — corrupt registered worktree: depth-2 has a .git file → Gate 0b safety
#       net catches it. empty_parents_skipped_registered>=1.
# ─────────────────────────────────────────────────────────────────────────────

T21_corrupt_registered_dot_git_safety_net() {
    local repo="$TMPDIR_BASE/t21-repo"
    init_repo "$repo"
    local wbase="$TMPDIR_BASE/t21-wbase"
    local task_parent="$wbase/corrupt-task"
    local leaf="$task_parent/leaf"
    mkdir -p "$leaf"
    printf 'gitdir: /nonexistent\n' > "$leaf/.git"
    make_stale "$leaf"
    make_stale "$task_parent"

    if [ ! -x "$SWEEP" ]; then
        fail "T21 corrupt_registered_dot_git_safety_net: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && SWEEP_SKIP_GH=1 WORKTREE_BASE_DIR="$wbase" SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T21 corrupt_registered_dot_git_safety_net: exit=$exit_code, out=$out"
        return
    fi

    local skipped
    skipped="$(ci_field "$out" empty_parents_skipped_registered)"

    if [ "${skipped:-0}" -ge 1 ] 2>/dev/null && [ -d "$task_parent" ]; then
        pass "T21 corrupt_registered_dot_git_safety_net (skipped_registered>=1, parent kept)"
    else
        fail "T21 corrupt_registered_dot_git_safety_net: empty_parents_skipped_registered=${skipped:-?} exists=$([ -d "$task_parent" ] && echo y || echo n), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T15_empty_parent_dry_run_candidate
T16_empty_parent_apply_removed
T17_nonempty_parent_skipped
T18_fresh_empty_parent_skipped_young
T19_same_repo_registered_worktree_guards_parent
T20_cross_repo_registered_worktree_guards_parent
T21_corrupt_registered_dot_git_safety_net

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
