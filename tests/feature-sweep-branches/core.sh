#!/bin/bash
# tests/feature-sweep-branches/core.sh
# Core sweep tests: local-branch lifecycle, age gate, JSON shape, JS unit,
# env-var validation. Remote-branch behaviors live in remote.sh.
# Tests: T1, T3, T4, T7, T8, T10, T11, T17
#
# Sourced helpers come from _lib.sh. Runnable standalone:
#   bash tests/feature-sweep-branches/core.sh

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T1 — no local branches beyond main → candidates=0 (dry-run, --ci-mode)
# ─────────────────────────────────────────────────────────────────────────────

T1_no_branches_zero_candidates() {
    local repo="$TMPDIR_BASE/t1-repo"
    local stubdir="$TMPDIR_BASE/t1-stub"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    if [ ! -x "$SWEEP" ]; then
        fail "T1 no_branches_zero_candidates: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T1 no_branches_zero_candidates: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" candidates)"
    if [ "${n:-0}" = "0" ]; then
        pass "T1 no_branches_zero_candidates (candidates=0)"
    else
        # Also accept human-readable "0 candidates" / "no candidates"
        case "$out" in
            *"0 candidates"*|*"candidates: 0"*|*"no candidates"*)
                pass "T1 no_branches_zero_candidates (human-readable 0)" ;;
            *)
                fail "T1 no_branches_zero_candidates: candidates=${n:-?}, out=$out" ;;
        esac
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T3 — stale local branch + --skip-gh-check --dry-run --ci-mode → candidates>=1,
#      local_deleted=0 (dry-run does not delete)
# ─────────────────────────────────────────────────────────────────────────────

T3_stale_branch_dry_run_candidate() {
    local repo="$TMPDIR_BASE/t3-repo"
    local stubdir="$TMPDIR_BASE/t3-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    make_branch_with_date "$repo" "feature/stale-t3" "$stale_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T3 stale_branch_dry_run_candidate: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --skip-gh-check --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T3 stale_branch_dry_run_candidate: exit=$exit_code, out=$out"
        return
    fi

    local cands local_del
    cands="$(ci_field "$out" candidates)"
    local_del="$(ci_field "$out" local_deleted)"

    if [ "${cands:-0}" -ge 1 ] 2>/dev/null && [ "${local_del:-0}" = "0" ] 2>/dev/null; then
        pass "T3 stale_branch_dry_run_candidate (candidates>=1, local_deleted=0)"
    else
        fail "T3 stale_branch_dry_run_candidate: candidates=${cands:-?} local_deleted=${local_del:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T4 — --apply --skip-gh-check with stale local branch → branch deleted,
#      local_deleted=1 in JSON
# ─────────────────────────────────────────────────────────────────────────────

T4_apply_deletes_stale_local_branch() {
    local repo="$TMPDIR_BASE/t4-repo"
    local stubdir="$TMPDIR_BASE/t4-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    make_branch_with_date "$repo" "feature/stale-t4" "$stale_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T4 apply_deletes_stale_local_branch: $SWEEP not found / not executable"
        return
    fi

    # Verify branch exists before
    local before
    before="$(cd "$repo" && git branch --list "feature/stale-t4" 2>/dev/null)"
    if [ -z "$before" ]; then
        fail "T4 apply_deletes_stale_local_branch: precondition failed — branch not found"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --apply --skip-gh-check --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T4 apply_deletes_stale_local_branch: exit=$exit_code, out=$out"
        return
    fi

    local after local_del
    after="$(cd "$repo" && git branch --list "feature/stale-t4" 2>/dev/null)"
    local_del="$(ci_field "$out" local_deleted)"

    if [ -z "$after" ] && [ "${local_del:-0}" = "1" ]; then
        pass "T4 apply_deletes_stale_local_branch (branch gone, local_deleted=1)"
    else
        fail "T4 apply_deletes_stale_local_branch: branch_still_exists=$([ -n "$after" ] && echo yes || echo no) local_deleted=${local_del:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T7 — --apply --ci-mode → stdout is valid JSON with all required keys
# ─────────────────────────────────────────────────────────────────────────────

T7_ci_mode_json_shape() {
    local repo="$TMPDIR_BASE/t7-repo"
    local stubdir="$TMPDIR_BASE/t7-stub"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    if [ ! -x "$SWEEP" ]; then
        fail "T7 ci_mode_json_shape: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --skip-gh-check 2>/dev/null)"
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
                const required = ['scanned','candidates','local_deleted','remote_deleted',
                                  'remote_delete_failed','skipped_unmerged','skipped_young','errors',
                                  'no_pr_candidates','no_pr_deleted','no_pr_skipped_young','unmerged_pr_skipped'];
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
        *)  fail "T7 ci_mode_json_shape: $check; raw=$out" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T8 — --min-age-hours 999 with fresh commit → skipped_young>=1, candidates=0
# ─────────────────────────────────────────────────────────────────────────────

T8_fresh_commit_skipped_young() {
    local repo="$TMPDIR_BASE/t8-repo"
    local stubdir="$TMPDIR_BASE/t8-stub"
    local fresh_epoch
    fresh_epoch="$(date +%s)"  # now
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    make_branch_with_date "$repo" "feature/fresh-t8" "$fresh_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T8 fresh_commit_skipped_young: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check \
        --min-age-hours 999 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T8 fresh_commit_skipped_young: exit=$exit_code, out=$out"
        return
    fi

    local young cands
    young="$(ci_field "$out" skipped_young)"
    cands="$(ci_field "$out" candidates)"

    if [ "${young:-0}" -ge 1 ] 2>/dev/null && [ "${cands:-0}" = "0" ] 2>/dev/null; then
        pass "T8 fresh_commit_skipped_young (skipped_young>=1, candidates=0)"
    else
        fail "T8 fresh_commit_skipped_young: skipped_young=${young:-?} candidates=${cands:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T10 — stale branch age test: fresh commit → not candidate; old commit → candidate
# ─────────────────────────────────────────────────────────────────────────────

T10_age_gate_fresh_vs_stale() {
    local repo="$TMPDIR_BASE/t10-repo"
    local stubdir="$TMPDIR_BASE/t10-stub"
    local stale_epoch="1577836800"  # 2020-01-01 — definitely old
    local fresh_epoch
    fresh_epoch="$(date +%s)"      # now — definitely fresh
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    make_branch_with_date "$repo" "feature/old-t10" "$stale_epoch"
    make_branch_with_date "$repo" "feature/new-t10" "$fresh_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T10 age_gate_fresh_vs_stale: $SWEEP not found / not executable"
        return
    fi

    # Use a large min-age-hours to ensure fresh branch never qualifies
    local out exit_code
    out="$(cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode --skip-gh-check \
        --min-age-hours 100 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T10 age_gate_fresh_vs_stale: exit=$exit_code, out=$out"
        return
    fi

    # The old branch should be a candidate; the fresh one should be skipped_young
    local cands young
    cands="$(ci_field "$out" candidates)"
    young="$(ci_field "$out" skipped_young)"

    # At minimum: old branch must be a candidate (cands>=1) and fresh must NOT
    # be a candidate (young>=1 counts the fresh one as skipped_young).
    # We accept cands>=1 AND young>=1 as both conditions satisfied.
    if [ "${cands:-0}" -ge 1 ] 2>/dev/null && [ "${young:-0}" -ge 1 ] 2>/dev/null; then
        pass "T10 age_gate_fresh_vs_stale (candidates>=1 for old, skipped_young>=1 for fresh)"
    else
        fail "T10 age_gate_fresh_vs_stale: candidates=${cands:-?} skipped_young=${young:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T11 — JS unit test for isSweepBranchesSkillForceDelete in branch-delete-guard.js
#   a) "SWEEP_BRANCHES_SKILL=1 git -C /fake branch -D feature/x" → true
#   b) "SWEEP_BRANCHES_SKILL=1 git -C /fake branch -D main" → false
#   c) "git -C /fake branch -D feature/x" (no prefix) → false
# T11 is GREEN since branch-delete-guard.js already exists.
# ─────────────────────────────────────────────────────────────────────────────

T11_isSweepBranchesSkillForceDelete_unit() {
    if [ ! -f "$GUARD_JS" ]; then
        fail "T11 isSweepBranchesSkillForceDelete_unit: $GUARD_JS not found"
        return
    fi

    # Run inline node -e from AGENTS_DIR so require('./hooks/...') resolves on
    # Windows/Git Bash without needing a temp file (avoids heredoc write issues).
    local result
    result="$(cd "$AGENTS_DIR" && node -e \
        "const g=require('./hooks/enforce-worktree/branch-delete-guard.js');const fn=typeof g.isSweepBranchesSkillForceDelete==='function'?g.isSweepBranchesSkillForceDelete:null;if(!fn){console.log('MISSING_FN');process.exit(0);}const a=fn('SWEEP_BRANCHES_SKILL=1 git -C /fake branch -D feature/x');const b=fn('SWEEP_BRANCHES_SKILL=1 git -C /fake branch -D main');const c=fn('git -C /fake branch -D feature/x');console.log(a===true&&b===false&&c===false?'OK':'FAIL:a='+a+',b='+b+',c='+c);" \
        2>/dev/null)"

    case "$result" in
        OK)
            pass "T11 isSweepBranchesSkillForceDelete_unit" ;;
        MISSING_FN)
            # Function not yet exported from branch-delete-guard.js — expected RED
            # until implementation step adds it.
            fail "T11 isSweepBranchesSkillForceDelete_unit: isSweepBranchesSkillForceDelete not exported from branch-delete-guard.js (RED — implementation pending)" ;;
        *)
            fail "T11 isSweepBranchesSkillForceDelete_unit: ${result:-node error}" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T17 — SWEEP_AGE_DAYS=0 env var → exit non-zero, validation error on stderr
# ─────────────────────────────────────────────────────────────────────────────

T17_sweep_age_days_zero_rejected() {
    local repo="$TMPDIR_BASE/t17-repo"
    local stubdir="$TMPDIR_BASE/t17-stub"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    if [ ! -x "$SWEEP" ]; then
        fail "T17 sweep_age_days_zero_rejected: $SWEEP not found / not executable"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t17.out"
    local stderr_file="$TMPDIR_BASE/t17.err"
    local exit_code=0
    (cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" SWEEP_AGE_DAYS=0 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file") || exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T17 sweep_age_days_zero_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T17 sweep_age_days_zero_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T1_no_branches_zero_candidates
T3_stale_branch_dry_run_candidate
T4_apply_deletes_stale_local_branch
T7_ci_mode_json_shape
T8_fresh_commit_skipped_young
T10_age_gate_fresh_vs_stale
T11_isSweepBranchesSkillForceDelete_unit
T17_sweep_age_days_zero_rejected

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
