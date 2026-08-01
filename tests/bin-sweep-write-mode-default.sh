#!/bin/bash
# tests/bin-sweep-write-mode-default.sh
# Tests: bin/lib/sweep-write-mode.sh, bin/sweep-branches.sh, bin/sweep-plans.sh, bin/sweep-worktrees.sh, bin/audit-tests.sh, bin/audit-tests-common.sh, .github/workflows/sweep.yml
# Tags: sweep, write-mode, defaults, cron, scope:common, TL2
#
# Pins the apply-by-default write-mode inversion across the whole /sweep series:
#   - no flag  = production run (writes / deletes)
#   - --dry-run = classify and report only, write nothing
#   - --apply   = accepted, backward-compatible synonym of "no flag"
#
# Covers the three surfaces that must stay in lock-step (CPR-5 / CPR-6):
#   A. bin/lib/sweep-write-mode.sh semantics SSOT
#   B. every member script's flag face and observable footer / side effects
#   C. the unattended callers (.github/workflows/sweep.yml) and the SKILL.md prose
#
# TL3 gap (what this test does NOT catch):
# - The nightly GitHub Actions run itself: sweep.yml is grepped, not executed,
#   so a runner-only failure (missing GH_TOKEN, checkout depth) is invisible here.
# - A real /sweep hub dispatch forwarding user flags verbatim through the skill
#   layer — only the bin/ scripts are exercised.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRITE_MODE_LIB="$AGENTS_DIR/bin/lib/sweep-write-mode.sh"
SWEEP_YML="$AGENTS_DIR/.github/workflows/sweep.yml"

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

ci_field() {
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            const key = process.argv[1];
            for (const line of b.split(/\r?\n/)) {
                const t = line.trim();
                if (!t.startsWith('{')) continue;
                try { const d = JSON.parse(t); if (key in d) { console.log(d[key]); return; } }
                catch (e) { /* skip */ }
            }
        });
    " -- "$2" 2>/dev/null
}

# Stub AGENTS_CONFIG_DIR whose is-github-dotcom-remote always succeeds.
make_stub_agents_dir() {
    local stubdir="$1"
    mkdir -p "$stubdir/bin"
    printf '#!/bin/bash\nexit 0\n' > "$stubdir/bin/is-github-dotcom-remote"
    chmod +x "$stubdir/bin/is-github-dotcom-remote"
}

# ─────────────────────────────────────────────────────────────────────────────
# A. bin/lib/sweep-write-mode.sh — the semantics SSOT
# ─────────────────────────────────────────────────────────────────────────────

A1_lib_exists_and_defaults_to_apply() {
    if [ ! -f "$WRITE_MODE_LIB" ]; then
        fail "A1 write-mode lib: $WRITE_MODE_LIB does not exist"
        return
    fi
    local out
    out="$(run_with_timeout bash -c '
        set -uo pipefail
        # shellcheck disable=SC1090
        . "$1"
        sweep_write_mode_init;    printf "init:%s/%s " "${APPLY:-?}" "${DRY_RUN:-?}"
        sweep_write_mode_dry_run; printf "dry:%s/%s "  "${APPLY:-?}" "${DRY_RUN:-?}"
        sweep_write_mode_apply;   printf "apply:%s/%s" "${APPLY:-?}" "${DRY_RUN:-?}"
    ' _ "$WRITE_MODE_LIB" 2>&1)"

    if [ "$out" = "init:1/0 dry:0/1 apply:1/0" ]; then
        pass "A1 write-mode lib: init=apply, dry_run=0/1, apply=1/0"
    else
        fail "A1 write-mode lib: got '$out', want 'init:1/0 dry:0/1 apply:1/0'"
    fi
}

A2_lib_footer_and_usage_helpers() {
    if [ ! -f "$WRITE_MODE_LIB" ]; then
        fail "A2 write-mode lib helpers: $WRITE_MODE_LIB does not exist"
        return
    fi
    local usage footer_dry footer_apply
    usage="$(run_with_timeout bash -c '. "$1"; sweep_write_mode_usage_lines' _ "$WRITE_MODE_LIB" 2>&1)"
    footer_dry="$(run_with_timeout bash -c '. "$1"; sweep_write_mode_dry_run; sweep_write_mode_footer' _ "$WRITE_MODE_LIB" 2>&1)"
    footer_apply="$(run_with_timeout bash -c '. "$1"; sweep_write_mode_init; sweep_write_mode_footer' _ "$WRITE_MODE_LIB" 2>&1)"

    if echo "$usage" | grep -q -- '--dry-run' && echo "$usage" | grep -q -- '--apply'; then
        pass "A2a usage lines mention both --dry-run and --apply"
    else
        fail "A2a usage lines incomplete: '$usage'"
    fi
    if echo "$footer_dry" | grep -qi 'dry-run'; then
        pass "A2b footer printed in dry-run mode"
    else
        fail "A2b footer missing in dry-run mode: '$footer_dry'"
    fi
    if [ -z "${footer_apply// /}" ]; then
        pass "A2c footer silent in apply mode"
    else
        fail "A2c footer should be empty in apply mode, got: '$footer_apply'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# B1. All five member scripts accept --dry-run (table-driven over the class).
# ─────────────────────────────────────────────────────────────────────────────

B1_all_scripts_accept_dry_run() {
    local script out rc
    while IFS='|' read -r name relpath; do
        [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        relpath="${relpath//[[:space:]]/}"
        script="$AGENTS_DIR/$relpath"
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
sweep-branches      | bin/sweep-branches.sh
sweep-plans         | bin/sweep-plans.sh
sweep-worktrees     | bin/sweep-worktrees.sh
audit-tests         | bin/audit-tests.sh
audit-tests-common  | bin/audit-tests-common.sh
TABLE
}

B1b_audit_tests_common_still_rejects_apply() {
    local out rc
    out="$(run_with_timeout bash "$AGENTS_DIR/bin/audit-tests-common.sh" --apply 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "B1b audit-tests-common still rejects --apply (exit=$rc)"
    else
        fail "B1b audit-tests-common must keep rejecting --apply, got exit 0 (out=$out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# B2. sweep-plans.sh footer: absent with no flag, present with --dry-run.
# ─────────────────────────────────────────────────────────────────────────────

B2_sweep_plans_footer_follows_mode() {
    local plans_dir="$TMPDIR_BASE/b2-plans"
    mkdir -p "$plans_dir"
    local sweep="$AGENTS_DIR/bin/sweep-plans.sh"

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
    cp "$AGENTS_DIR/bin/audit-tests.sh" "$repo/bin/audit-tests.sh"
    mkdir -p "$repo/bin/lib"
    cp "$AGENTS_DIR"/bin/lib/*.sh "$repo/bin/lib/"
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
    local stubdir="$TMPDIR_BASE/b4-$tag-agents"
    local ghdir="$TMPDIR_BASE/b4-$tag-gh"
    local origin="$repo.origin.git"
    local stale_epoch="1577836800"   # 2020-01-01 UTC

    mkdir -p "$repo" "$ghdir"
    make_stub_agents_dir "$stubdir"
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

    (cd "$repo" && PATH="$ghdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$AGENTS_DIR/bin/sweep-branches.sh" --delete-no-pr --ci-mode "$@" 2>&1)
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
# B5. sweep-worktrees.sh run to completion (CPR-5: same standard as its
#     siblings — sweep-branches in B4, sweep-plans in B2 /
#     tests/fix-847-sweep-plans-empty-prefix.sh, audit-tests in B3 /
#     tests/feature-test-cleanup-944/group-e-deletion.sh). A --help-only smoke
#     check cannot observe the write/no-write asymmetry, which is the entire
#     point of the inversion.
#
#     Sandboxing: WORKTREE_BASE_DIR and AGENTS_CONFIG_DIR are both pointed at
#     throwaway temp dirs, and --skip-gh-check removes the network dependency,
#     so the real ~/git/worktrees registry can never be an input.
# ─────────────────────────────────────────────────────────────────────────────

# _b5_fixture <tag> — builds a main repo plus one zombie linked worktree whose
# branch is merged and clean. Echoes "<repo>|<worktree-dir>|<wt-base>".
_b5_fixture() {
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
    local stubdir="$wtbase/../agents-stub"
    mkdir -p "$stubdir"
    make_stub_agents_dir "$stubdir"
    (cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" WORKTREE_BASE_DIR="$wtbase" \
        run_with_timeout bash "$AGENTS_DIR/bin/sweep-worktrees.sh" \
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

# ─────────────────────────────────────────────────────────────────────────────
# C1. Nightly cron must pin the non-destructive intent explicitly.
# ─────────────────────────────────────────────────────────────────────────────

C1_cron_flags_updated() {
    if [ ! -f "$SWEEP_YML" ]; then
        fail "C1 cron: $SWEEP_YML not found"
        return
    fi
    local wt at atc
    wt="$(grep -n 'sweep-worktrees\.sh' "$SWEEP_YML" | head -1)"
    at="$(grep -n 'audit-tests\.sh' "$SWEEP_YML" | head -1)"
    atc="$(grep -n 'audit-tests-common\.sh' "$SWEEP_YML" | head -1)"

    if [ -n "$wt" ] && ! echo "$wt" | grep -q -- '--apply'; then
        pass "C1a sweep.yml sweep-worktrees step no longer passes --apply"
    else
        fail "C1a sweep.yml sweep-worktrees step still passes --apply: $wt"
    fi
    if echo "$at" | grep -q -- '--dry-run'; then
        pass "C1b sweep.yml audit-tests step passes --dry-run"
    else
        fail "C1b sweep.yml audit-tests step missing --dry-run: $at"
    fi
    if echo "$atc" | grep -q -- '--dry-run'; then
        pass "C1c sweep.yml audit-tests-common step passes --dry-run"
    else
        fail "C1c sweep.yml audit-tests-common step missing --dry-run: $atc"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# C2. No stale "dry-run is the default" prose left in any sweep SKILL.md.
#     Pattern set deliberately broad so a missed rewrite cannot slip through.
# ─────────────────────────────────────────────────────────────────────────────

C2_no_stale_dry_run_prose() {
    local hits
    hits="$(grep -rniE 'Default is dry-run|Dry-run by default|Default is report-only|no --apply = dry-run' \
        "$AGENTS_DIR"/skills/sweep*/SKILL.md 2>/dev/null || true)"
    if [ -z "$hits" ]; then
        pass "C2 no stale dry-run-default prose in skills/sweep*/SKILL.md"
    else
        fail "C2 stale dry-run-default prose remains:"$'\n'"$hits"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

A1_lib_exists_and_defaults_to_apply
A2_lib_footer_and_usage_helpers
B1_all_scripts_accept_dry_run
B1b_audit_tests_common_still_rejects_apply
B2_sweep_plans_footer_follows_mode
B3_audit_tests_dry_run_writes_nothing
B4_delete_no_pr_alone_is_destructive
B5_sweep_worktrees_write_mode_asymmetry
C1_cron_flags_updated
C2_no_stale_dry_run_prose

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
