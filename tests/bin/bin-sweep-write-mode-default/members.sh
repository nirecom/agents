# ─────────────────────────────────────────────────────────────────────────────
# B1. Every member script accepts --dry-run (table-driven over the class).
# ─────────────────────────────────────────────────────────────────────────────

B1_all_scripts_accept_dry_run() {
    local script out rc
    while IFS='|' read -r name relpath; do
        [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        relpath="${relpath//[[:space:]]/}"
        script="$SCRIPT_CHECKOUT_ROOT/$relpath"
        if [ ! -f "$script" ]; then
            fail "B1 $name: $relpath not found"
            continue
        fi
        out="$(run_with_timeout bash "$script" --dry-run --help 2>&1)"
        rc=$?
        if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qi 'unknown \(flag\|argument\|option\)'; then
            pass "B1 $name: --dry-run accepted (exit 0, no unknown-flag error)"
        else
            fail "B1 $name: --dry-run rejected (exit=$rc, out=$out)"
        fi
    done <<'TABLE'
sweep-branches        | bin/sweep-branches.sh
sweep-plans           | bin/sweep-plans.sh
sweep-worktrees       | bin/sweep-worktrees.sh
sweep-shell-snapshots | bin/sweep-shell-snapshots.sh
audit-tests           | bin/audit-tests.sh
audit-tests-common    | bin/audit-tests-common.sh
TABLE
}

# B1b. #1833 made audit-tests-common.sh a full member of the write-mode class,
# so --apply is no longer rejected. --help keeps the probe side-effect-free;
# the deletion itself is asserted on a fixture repo in
# tests/bin/fix-1576-audit-tests-apply.sh TC5.
B1b_audit_tests_common_accepts_apply() {
    local out rc
    out="$(run_with_timeout bash "$SCRIPT_CHECKOUT_ROOT/bin/audit-tests-common.sh" --apply --help 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qi 'apply is not supported'; then
        pass "B1b audit-tests-common accepts --apply (write-mode class member)"
    else
        fail "B1b audit-tests-common must no longer reject --apply (exit=$rc, out=$out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# B2. sweep-plans.sh footer: absent with no flag, present with --dry-run.
# ─────────────────────────────────────────────────────────────────────────────

B2_sweep_plans_footer_follows_mode() {
    local plans_dir="$TMPDIR_BASE/b2-plans"
    mkdir -p "$plans_dir"
    local sweep="$SCRIPT_CHECKOUT_ROOT/bin/sweep-plans.sh"

    local out_default out_dry
    out_default="$(WORKFLOW_PLANS_DIR="$plans_dir" run_with_timeout bash "$sweep" 2>&1)"
    out_dry="$(WORKFLOW_PLANS_DIR="$plans_dir" run_with_timeout bash "$sweep" --dry-run 2>&1)"

    if ! echo "$out_default" | grep -qi 'dry-run'; then
        pass "B2a sweep-plans flagless run prints no dry-run footer"
    else
        fail "B2a sweep-plans flagless run still prints dry-run footer: $out_default"
    fi
    if echo "$out_dry" | grep -qi 'dry-run'; then
        pass "B2b sweep-plans --dry-run prints the dry-run footer"
    else
        fail "B2b sweep-plans --dry-run footer missing: $out_dry"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# B3. audit-tests.sh --dry-run --offline must not stage a deletion.
# ─────────────────────────────────────────────────────────────────────────────

B3_audit_tests_dry_run_writes_nothing() {
    local repo="$TMPDIR_BASE/b3-repo"
    mkdir -p "$repo/tests" "$repo/bin"
    git -c init.defaultBranch=main init -q "$repo"
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    git -C "$repo" config core.autocrlf false
    cp "$SCRIPT_CHECKOUT_ROOT/bin/audit-tests.sh" "$repo/bin/audit-tests.sh"
    mkdir -p "$repo/bin/lib"
    cp "$SCRIPT_CHECKOUT_ROOT"/bin/lib/*.sh "$repo/bin/lib/"
    cp -r "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-retire-predicate" "$repo/bin/lib/"
    printf '#!/bin/bash\n' > "$repo/tests/feature-100-stale.sh"
    git -C "$repo" add -A
    GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
        git -C "$repo" commit -q --no-verify -m "stale fixture"

    local out
    out="$(cd "$repo" && run_with_timeout bash "$repo/bin/audit-tests.sh" --dry-run --offline 2>&1)"
    local porcelain
    porcelain="$(git -C "$repo" status --porcelain)"

    if [ -z "$porcelain" ]; then
        pass "B3 audit-tests --dry-run --offline leaves the index clean"
    else
        fail "B3 audit-tests --dry-run --offline dirtied the index: '$porcelain' (out=$out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# B4. --delete-no-pr alone deletes; --delete-no-pr --dry-run only reports.
# ─────────────────────────────────────────────────────────────────────────────

_b4_run() {
    # $1 fixture tag, $2... extra flags → echoes the sweep stdout
    local tag="$1"; shift
    local repo="$TMPDIR_BASE/b4-$tag"
    local fake_script_checkout_root="$TMPDIR_BASE/b4-$tag-agents"
    local ghdir="$TMPDIR_BASE/b4-$tag-gh"
    local origin="$repo.origin.git"
    local stale_epoch="1577836800"   # 2020-01-01 UTC

    mkdir -p "$repo" "$ghdir"
    make_fake_script_checkout "$fake_script_checkout_root"
    git -c init.defaultBranch=main init -q "$repo"
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty --no-verify -m init
    git -C "$repo" checkout -q -b feature/no-pr-b4
    GIT_AUTHOR_DATE="$stale_epoch" GIT_COMMITTER_DATE="$stale_epoch" \
        git -C "$repo" commit -q --allow-empty --no-verify -m "stale work"
    git -C "$repo" checkout -q main
    git init -q --bare -b main "$origin"
    git -C "$repo" remote add origin "$origin"
    git -C "$repo" push -q origin main
    git -C "$repo" merge --no-ff -q -m "merge feature/no-pr-b4" feature/no-pr-b4
    git -C "$repo" push -q origin main
    git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

    cat > "$ghdir/gh" <<'GHSTUB'
#!/bin/bash
# No PR ever exists for this branch.
case "$*" in
    *"--state open"*|*"--state merged"*|*"--state all"*) echo "0"; exit 0 ;;
    *) echo "[]"; exit 0 ;;
esac
GHSTUB
    chmod +x "$ghdir/gh"

    (cd "$repo" && PATH="$ghdir:$PATH" SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$fake_script_checkout_root/bin/sweep-branches.sh" --delete-no-pr --ci-mode "$@" 2>&1)
}

B4_delete_no_pr_alone_is_destructive() {
    local out_apply out_dry n_del n_del_dry n_cand
    out_apply="$(_b4_run apply)"
    n_del="$(ci_field "$out_apply" no_pr_deleted)"
    if [ "${n_del:-0}" -ge 1 ] 2>/dev/null; then
        pass "B4a --delete-no-pr alone deletes (no_pr_deleted=$n_del)"
    else
        fail "B4a --delete-no-pr alone should delete: no_pr_deleted=${n_del:-<absent>}, out=$out_apply"
    fi

    out_dry="$(_b4_run dry --dry-run)"
    n_del_dry="$(ci_field "$out_dry" no_pr_deleted)"
    n_cand="$(ci_field "$out_dry" no_pr_candidates)"
    if [ "${n_del_dry:-x}" = "0" ] && [ "${n_cand:-0}" -ge 1 ] 2>/dev/null; then
        pass "B4b --delete-no-pr --dry-run reports only (deleted=0, candidates=$n_cand)"
    else
        fail "B4b --delete-no-pr --dry-run wrong: deleted=${n_del_dry:-<absent>} candidates=${n_cand:-<absent>}, out=$out_dry"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# B5. sweep-worktrees.sh run to completion (CPR-ORTH: same standard as its
#     siblings in B2/B3/B4) — a --help-only smoke check cannot observe the
#     write/no-write asymmetry, which is the entire point of the inversion.
#     WORKTREE_BASE_DIR points at a throwaway temp dir
#     and --skip-gh-check drops the network dependency, so the real
#     ~/git/worktrees registry can never be an input.
# ─────────────────────────────────────────────────────────────────────────────

_b5_fixture() {
    # <tag> → a main repo plus one zombie linked worktree whose branch is merged
    # and clean. Echoes "<repo>|<worktree-dir>|<wt-base>".
    local tag="$1"
    local root="$TMPDIR_BASE/b5-$tag"
    local repo="$root/main-repo"
    local wtbase="$root/worktrees"
    local hooks="$root/no-hooks"
    local branch="feature/zombie-b5-$tag"

    mkdir -p "$repo" "$wtbase" "$hooks"
    git -c init.defaultBranch=main init -q "$repo"
    git -C "$repo" config core.hooksPath "$hooks"
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty --no-verify -m init
    git -C "$repo" worktree add -q -b "$branch" "$wtbase/task/main-repo" >/dev/null 2>&1

    printf '%s|%s|%s' "$repo" "$wtbase/task/main-repo" "$wtbase"
}

# _b5_run <repo> <wtbase> [extra flags] — echoes the CI-mode JSON summary.
_b5_run() {
    local repo="$1" wtbase="$2"; shift 2
    (cd "$repo" && WORKTREE_BASE_DIR="$wtbase" \
        run_with_timeout bash "$SCRIPT_CHECKOUT_ROOT/bin/sweep-worktrees.sh" \
        --ci-mode --skip-gh-check --min-age-hours 0 "$@" 2>&1)
}

B5_sweep_worktrees_write_mode_asymmetry() {
    local repo wt wtbase out removed deleted cands

    # (a) Flagless run = production run: worktree and branch are really gone.
    IFS='|' read -r repo wt wtbase <<< "$(_b5_fixture apply)"
    out="$(_b5_run "$repo" "$wtbase")"
    removed="$(ci_field "$out" worktree_removed)"
    deleted="$(ci_field "$out" branch_deleted)"

    if [ "${removed:-0}" -ge 1 ] 2>/dev/null && [ ! -d "$wt" ]; then
        pass "B5a sweep-worktrees flagless run removed the worktree (worktree_removed=$removed)"
    else
        fail "B5a sweep-worktrees flagless run should remove the worktree: worktree_removed=${removed:-<absent>}, dir_exists=$([ -d "$wt" ] && echo yes || echo no), out=$out"
    fi

    if [ "${deleted:-0}" -ge 1 ] 2>/dev/null \
       && [ -z "$(git -C "$repo" branch --list 'feature/zombie-b5-apply')" ]; then
        pass "B5b sweep-worktrees flagless run deleted the branch (branch_deleted=$deleted)"
    else
        fail "B5b sweep-worktrees flagless run should delete the branch: branch_deleted=${deleted:-<absent>}, branch=$(git -C "$repo" branch --list 'feature/zombie-b5-apply'), out=$out"
    fi

    # (b) --dry-run = preview: same candidate, zero writes.
    IFS='|' read -r repo wt wtbase <<< "$(_b5_fixture dry)"
    out="$(_b5_run "$repo" "$wtbase" --dry-run)"
    cands="$(ci_field "$out" candidates)"
    removed="$(ci_field "$out" worktree_removed)"
    deleted="$(ci_field "$out" branch_deleted)"

    if [ "${cands:-0}" -ge 1 ] 2>/dev/null && [ "${removed:-x}" = "0" ] && [ "${deleted:-x}" = "0" ]; then
        pass "B5c sweep-worktrees --dry-run reports only (candidates=$cands, removed=0, branch_deleted=0)"
    else
        fail "B5c sweep-worktrees --dry-run wrong: candidates=${cands:-<absent>} removed=${removed:-<absent>} branch_deleted=${deleted:-<absent>}, out=$out"
    fi

    if [ -d "$wt" ] && [ -n "$(git -C "$repo" branch --list 'feature/zombie-b5-dry')" ]; then
        pass "B5d sweep-worktrees --dry-run left the worktree and branch on disk"
    else
        fail "B5d sweep-worktrees --dry-run destroyed state: dir_exists=$([ -d "$wt" ] && echo yes || echo no), branch=$(git -C "$repo" branch --list 'feature/zombie-b5-dry')"
    fi
}
