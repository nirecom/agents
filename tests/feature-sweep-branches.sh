#!/bin/bash
# tests/feature-sweep-branches.sh
# Tests: bin/sweep-branches.sh, hooks/enforce-worktree/branch-delete-guard.js
# Tags: sweep, branch, maintenance, bin, git, remote
#
# Tests for bin/sweep-branches.sh — the branch-sweep mechanism that deletes
# merged-but-undeleted local and remote branches.
#
# Contract under test:
#   bin/sweep-branches.sh [--dry-run|--apply] [--ci-mode] [--skip-gh-check]
#                         [--min-age-hours N]
#
# A "candidate" for sweep is a local or remote branch whose:
#   - last commit is older than --min-age-hours (default threshold)
#   - has a merged PR (gh pr list says merged), OR can be force-skipped
#     via --skip-gh-check
#   - is NOT a protected branch (main, master, HEAD, etc.)
#
# Age control: GIT_AUTHOR_DATE/GIT_COMMITTER_DATE (not touch -d) — the script
# uses `git log -1 --format=%ct` to read commit timestamps.
#
# Outputs:
#   --dry-run    → human-readable list (count + per-candidate line)
#   --ci-mode    → JSON with keys: scanned, candidates, local_deleted,
#                  remote_deleted, remote_delete_failed, skipped_unmerged,
#                  skipped_young, errors
#
# Source bin/sweep-branches.sh does NOT exist yet — all tests for that binary
# are RED until the implementation step lands. T11 (JS unit test) is GREEN
# since branch-delete-guard.js already exists.
# Test-first.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$AGENTS_DIR/bin/sweep-branches.sh"
GUARD_JS="$AGENTS_DIR/hooks/enforce-worktree/branch-delete-guard.js"

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

# Create a git repo at $1 with one commit on main.
init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
}

# Create a local branch $2 in repo $1 with a commit dated at EPOCH $3.
# Uses GIT_AUTHOR_DATE/GIT_COMMITTER_DATE to control commit age.
make_branch_with_date() {
    local repo="$1" branch="$2" epoch="$3"
    (cd "$repo" && \
        git checkout -q -b "$branch" && \
        GIT_AUTHOR_DATE="$epoch" GIT_COMMITTER_DATE="$epoch" \
            git -c user.email=t@example.com -c user.name=t \
            commit --allow-empty --no-verify -q -m "commit on $branch" && \
        git checkout -q main)
}

# Create a stub AGENTS_CONFIG_DIR at $1 with is-github-dotcom-remote (exits 0).
make_stub_agents_dir() {
    local stubdir="$1"
    mkdir -p "$stubdir/bin"
    cat > "$stubdir/bin/is-github-dotcom-remote" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$stubdir/bin/is-github-dotcom-remote"
}

# Extract a field from --ci-mode JSON output.
# $1: multiline string (may include non-JSON lines), $2: field key → prints value or empty string
ci_field() {
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            const key = process.argv[1];
            const lines = b.split(/\r?\n/);
            for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed.startsWith('{')) continue;
                try {
                    const d = JSON.parse(trimmed);
                    if (key in d) { console.log(d[key]); return; }
                } catch (e) { /* not JSON, skip */ }
            }
        });
    " -- "$2" 2>/dev/null
}

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
# T2 — local branch present, stub gh returns merged=false → skipped_unmerged>=1
# ─────────────────────────────────────────────────────────────────────────────

T2_unmerged_branch_skipped() {
    local repo="$TMPDIR_BASE/t2-repo"
    local stubdir="$TMPDIR_BASE/t2-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    make_branch_with_date "$repo" "feature/unmerged-t2" "$stale_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T2 unmerged_branch_skipped: $SWEEP not found / not executable"
        return
    fi

    # Stub gh: pr list returns empty array (no merged PR)
    local ghstubdir="$TMPDIR_BASE/t2-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
# T2 stub: no merged PRs
echo "[]"
exit 0
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T2 unmerged_branch_skipped: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" skipped_unmerged)"
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
        pass "T2 unmerged_branch_skipped (skipped_unmerged>=1)"
    else
        fail "T2 unmerged_branch_skipped: skipped_unmerged=${n:-?}, out=$out"
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
# T5 — remote-only branch; stub gh api -X DELETE exits 0; stub gh pr list
#      returns merged=true → remote_deleted=1 in --ci-mode JSON
# ─────────────────────────────────────────────────────────────────────────────

T5_remote_branch_deleted_when_merged() {
    local repo="$TMPDIR_BASE/t5-repo"
    local stubdir="$TMPDIR_BASE/t5-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    # Create a fake remote repo and add it as origin
    local remote="$TMPDIR_BASE/t5-remote"
    init_repo "$remote"
    (cd "$repo" && git remote add origin "$remote")

    # Push a branch to the remote to simulate a remote-only branch
    make_branch_with_date "$repo" "feature/remote-t5" "$stale_epoch"
    (cd "$repo" && git push -q origin "feature/remote-t5" && git branch -D "feature/remote-t5")

    if [ ! -x "$SWEEP" ]; then
        fail "T5 remote_branch_deleted_when_merged: $SWEEP not found / not executable"
        return
    fi

    # Stub gh: pr list returns merged state; api DELETE succeeds
    local ghstubdir="$TMPDIR_BASE/t5-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
# T5 stub gh: pr list → merged (returns "true" for --jq 'length > 0'); api DELETE → success
case "$*" in
    *"pr list"*|*"pr view"*)
        echo "true"
        exit 0
        ;;
    *"api"*"-X DELETE"*|*"api"*"DELETE"*)
        exit 0
        ;;
    *"repo view"*)
        echo '{"owner":{"login":"testowner"},"name":"testrepo"}'
        exit 0
        ;;
    *)
        echo "[]"
        exit 0
        ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T5 remote_branch_deleted_when_merged: exit=$exit_code, out=$out"
        return
    fi

    local remote_del
    remote_del="$(ci_field "$out" remote_deleted)"

    if [ "${remote_del:-0}" -ge 1 ] 2>/dev/null; then
        pass "T5 remote_branch_deleted_when_merged (remote_deleted>=1)"
    else
        fail "T5 remote_branch_deleted_when_merged: remote_deleted=${remote_del:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T6 — no origin or git@gitlab.com origin → exit 0,
#      remote_deleted=0, local_deleted=0
# Note: T6 does NOT stub is-github-dotcom-remote; uses natural repo with
#       non-GitHub remote so the guard returns non-zero.
# ─────────────────────────────────────────────────────────────────────────────

T6_non_github_remote_exits_zero_no_deletes() {
    local repo="$TMPDIR_BASE/t6-repo"
    local stubdir="$TMPDIR_BASE/t6-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"

    # Create a stub AGENTS_CONFIG_DIR where is-github-dotcom-remote exits 1
    # (non-GitHub remote) — do NOT stub it as exits 0
    mkdir -p "$stubdir/bin"
    cat > "$stubdir/bin/is-github-dotcom-remote" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$stubdir/bin/is-github-dotcom-remote"

    # Add a gitlab-style remote to simulate non-GitHub origin
    (cd "$repo" && git remote add origin "git@gitlab.com:user/repo.git" 2>/dev/null || true)

    make_branch_with_date "$repo" "feature/gitlab-t6" "$stale_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T6 non_github_remote_exits_zero_no_deletes: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T6 non_github_remote_exits_zero_no_deletes: exit=$exit_code (expected 0), out=$out"
        return
    fi

    local remote_del local_del
    remote_del="$(ci_field "$out" remote_deleted)"
    local_del="$(ci_field "$out" local_deleted)"

    if [ "${remote_del:-0}" = "0" ] && [ "${local_del:-0}" = "0" ]; then
        pass "T6 non_github_remote_exits_zero_no_deletes (exit=0, remote_deleted=0, local_deleted=0)"
    else
        fail "T6 non_github_remote_exits_zero_no_deletes: remote_deleted=${remote_del:-?} local_deleted=${local_del:-?}, out=$out"
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
                                  'remote_delete_failed','skipped_unmerged','skipped_young','errors'];
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
# T9 — stub gh api -X DELETE exits 1 → exit 0 (non-fatal),
#      remote_delete_failed=1 in JSON
# ─────────────────────────────────────────────────────────────────────────────

T9_remote_delete_failure_non_fatal() {
    local repo="$TMPDIR_BASE/t9-repo"
    local stubdir="$TMPDIR_BASE/t9-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    # Create a fake remote and push a branch
    local remote="$TMPDIR_BASE/t9-remote"
    init_repo "$remote"
    (cd "$repo" && git remote add origin "$remote")
    make_branch_with_date "$repo" "feature/remote-t9" "$stale_epoch"
    (cd "$repo" && git push -q origin "feature/remote-t9" && git branch -D "feature/remote-t9")

    if [ ! -x "$SWEEP" ]; then
        fail "T9 remote_delete_failure_non_fatal: $SWEEP not found / not executable"
        return
    fi

    # Stub gh: pr list returns merged; api DELETE fails
    local ghstubdir="$TMPDIR_BASE/t9-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
# T9 stub gh: pr list → merged (returns "true" for --jq 'length > 0'); api DELETE → failure
case "$*" in
    *"pr list"*|*"pr view"*)
        echo "true"
        exit 0
        ;;
    *"api"*"-X DELETE"*|*"api"*"DELETE"*)
        echo "error: could not delete ref" >&2
        exit 1
        ;;
    *"repo view"*)
        echo '{"owner":{"login":"testowner"},"name":"testrepo"}'
        exit 0
        ;;
    *)
        echo "[]"
        exit 0
        ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T9 remote_delete_failure_non_fatal: exit=$exit_code (expected 0), out=$out"
        return
    fi

    local failed
    failed="$(ci_field "$out" remote_delete_failed)"

    if [ "${failed:-0}" -ge 1 ] 2>/dev/null; then
        pass "T9 remote_delete_failure_non_fatal (exit=0, remote_delete_failed>=1)"
    else
        fail "T9 remote_delete_failure_non_fatal: remote_delete_failed=${failed:-?}, out=$out"
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
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

T1_no_branches_zero_candidates
T2_unmerged_branch_skipped
T3_stale_branch_dry_run_candidate
T4_apply_deletes_stale_local_branch
T5_remote_branch_deleted_when_merged
T6_non_github_remote_exits_zero_no_deletes
T7_ci_mode_json_shape
T8_fresh_commit_skipped_young
T9_remote_delete_failure_non_fatal
T10_age_gate_fresh_vs_stale
T11_isSweepBranchesSkillForceDelete_unit

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
