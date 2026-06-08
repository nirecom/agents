#!/bin/bash
# tests/feature-sweep-branches/no-pr.sh
# No-PR sweep tests: routing, --delete-no-pr, young-skip, reachable/unreachable.
# Tests: T2, T12, T13, T14, T15, T18
#
# Sourced helpers come from _lib.sh. Runnable standalone:
#   bash tests/feature-sweep-branches/no-pr.sh

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T2 — local branch present, stub gh returns [] (no PR at all) → no_pr_candidates>=1
# After #808: no-PR branches route to no_pr_candidates, not skipped_unmerged.
# ─────────────────────────────────────────────────────────────────────────────

T2_unmerged_branch_skipped() {
    local repo="$TMPDIR_BASE/t2-repo"
    local stubdir="$TMPDIR_BASE/t2-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    # Must be reachable from origin/main so the reachability gate (now at
    # classification time) doesn't filter this branch out before the no-PR check.
    make_branch_reachable_from_origin_main "$repo" "feature/unmerged-t2" "$stale_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T2 unmerged_branch_skipped: $SWEEP not found / not executable"
        return
    fi

    # Stub gh: pr list returns empty array (no PR ever)
    local ghstubdir="$TMPDIR_BASE/t2-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
# T2 stub: no PRs at all — return "0" for length-based queries.
case "$*" in
    *"--state open"*)    echo "0"; exit 0 ;;
    *"--state merged"*)  echo "0"; exit 0 ;;
    *)                   echo "[]"; exit 0 ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    # SWEEP_AGE_DAYS=1 so the stale 2020-01-01 branch passes the no-PR age gate.
    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T2 unmerged_branch_skipped: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" no_pr_candidates)"
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
        pass "T2 unmerged_branch_skipped (no_pr_candidates>=1)"
    else
        fail "T2 unmerged_branch_skipped: no_pr_candidates=${n:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T12 — no-PR detection dry-run: stub gh returns "0" for --state all
#       → no_pr_candidates>=1, output contains NO-PR-CANDIDATE marker
# ─────────────────────────────────────────────────────────────────────────────

T12_no_pr_dry_run_candidate() {
    local repo="$TMPDIR_BASE/t12-repo"
    local stubdir="$TMPDIR_BASE/t12-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    make_branch_reachable_from_origin_main "$repo" "feature/no-pr-t12" "$stale_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T12 no_pr_dry_run_candidate: $SWEEP not found / not executable"
        return
    fi

    local ghstubdir="$TMPDIR_BASE/t12-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
# T12 stub: no PR for branch
case "$*" in
    *"--state open"*)    echo "0"; exit 0 ;;
    *"--state merged"*)  echo "0"; exit 0 ;;
    *"repo view"*)       echo '{"owner":{"login":"o"},"name":"r"}'; exit 0 ;;
    *)                   echo "[]"; exit 0 ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T12 no_pr_dry_run_candidate: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" no_pr_candidates)"
    case "$out" in
        *"NO-PR-CANDIDATE"*) : ;;
        *)
            fail "T12 no_pr_dry_run_candidate: NO-PR-CANDIDATE marker not in output: $out"
            return ;;
    esac
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
        pass "T12 no_pr_dry_run_candidate (no_pr_candidates>=1, NO-PR-CANDIDATE present)"
    else
        fail "T12 no_pr_dry_run_candidate: no_pr_candidates=${n:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T13 — --apply without --delete-no-pr: branch preserved, no_pr_deleted=0
# ─────────────────────────────────────────────────────────────────────────────

T13_apply_without_delete_no_pr_preserves() {
    local repo="$TMPDIR_BASE/t13-repo"
    local stubdir="$TMPDIR_BASE/t13-stub"
    local stale_epoch="1577836800"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    make_branch_reachable_from_origin_main "$repo" "feature/no-pr-t13" "$stale_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T13 apply_without_delete_no_pr_preserves: $SWEEP not found / not executable"
        return
    fi

    local ghstubdir="$TMPDIR_BASE/t13-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
    *"--state open"*)    echo "0"; exit 0 ;;
    *"--state merged"*)  echo "0"; exit 0 ;;
    *"repo view"*)       echo '{"owner":{"login":"o"},"name":"r"}'; exit 0 ;;
    *)                   echo "[]"; exit 0 ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T13 apply_without_delete_no_pr_preserves: exit=$exit_code, out=$out"
        return
    fi

    local after del cands
    after="$(cd "$repo" && git branch --list "feature/no-pr-t13" 2>/dev/null)"
    del="$(ci_field "$out" no_pr_deleted)"
    cands="$(ci_field "$out" no_pr_candidates)"

    if [ -n "$after" ] && [ "${del:-0}" = "0" ] && [ "${cands:-0}" -ge 1 ] 2>/dev/null; then
        pass "T13 apply_without_delete_no_pr_preserves (branch kept, no_pr_deleted=0, no_pr_candidates>=1)"
    else
        fail "T13 apply_without_delete_no_pr_preserves: after=[$after] no_pr_deleted=${del:-?} no_pr_candidates=${cands:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T14 — --apply --delete-no-pr: branch gone, no_pr_deleted=1
# ─────────────────────────────────────────────────────────────────────────────

T14_apply_delete_no_pr_removes() {
    local repo="$TMPDIR_BASE/t14-repo"
    local stubdir="$TMPDIR_BASE/t14-stub"
    local stale_epoch="1577836800"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    # Branch must be reachable from origin/main for the safety gate to allow
    # deletion. T18 covers the unreachable-skip path.
    make_branch_reachable_from_origin_main "$repo" "feature/no-pr-t14" "$stale_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T14 apply_delete_no_pr_removes: $SWEEP not found / not executable"
        return
    fi

    local ghstubdir="$TMPDIR_BASE/t14-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
    *"--state open"*)    echo "0"; exit 0 ;;
    *"--state merged"*)  echo "0"; exit 0 ;;
    *"repo view"*)       echo '{"owner":{"login":"o"},"name":"r"}'; exit 0 ;;
    *)                   echo "[]"; exit 0 ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --apply --delete-no-pr --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T14 apply_delete_no_pr_removes: exit=$exit_code, out=$out"
        return
    fi

    local after del
    after="$(cd "$repo" && git branch --list "feature/no-pr-t14" 2>/dev/null)"
    del="$(ci_field "$out" no_pr_deleted)"

    if [ -z "$after" ] && [ "${del:-0}" = "1" ]; then
        pass "T14 apply_delete_no_pr_removes (branch gone, no_pr_deleted=1)"
    else
        fail "T14 apply_delete_no_pr_removes: after=[$after] no_pr_deleted=${del:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T15 — no-PR branch newer than SWEEP_AGE_DAYS → no_pr_skipped_young>=1,
#       no_pr_candidates=0
# ─────────────────────────────────────────────────────────────────────────────

T15_no_pr_branch_too_young_skipped() {
    local repo="$TMPDIR_BASE/t15-repo"
    local stubdir="$TMPDIR_BASE/t15-stub"
    local fresh_epoch
    fresh_epoch="$(date +%s)"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    make_branch_with_date "$repo" "feature/fresh-t15" "$fresh_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T15 no_pr_branch_too_young_skipped: $SWEEP not found / not executable"
        return
    fi

    local ghstubdir="$TMPDIR_BASE/t15-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
    *"--state open"*)    echo "0"; exit 0 ;;
    *"--state merged"*)  echo "0"; exit 0 ;;
    *"repo view"*)       echo '{"owner":{"login":"o"},"name":"r"}'; exit 0 ;;
    *)                   echo "[]"; exit 0 ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T15 no_pr_branch_too_young_skipped: exit=$exit_code, out=$out"
        return
    fi

    local young cands
    young="$(ci_field "$out" no_pr_skipped_young)"
    cands="$(ci_field "$out" no_pr_candidates)"

    if [ "${young:-0}" -ge 1 ] 2>/dev/null && [ "${cands:-0}" = "0" ] 2>/dev/null; then
        pass "T15 no_pr_branch_too_young_skipped (no_pr_skipped_young>=1, no_pr_candidates=0)"
    else
        fail "T15 no_pr_branch_too_young_skipped: no_pr_skipped_young=${young:-?} no_pr_candidates=${cands:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T18 — no-PR branch NOT reachable from origin/main → skipped, counter goes up
#       (HIGH #2 salvage gate from Codex review)
# ─────────────────────────────────────────────────────────────────────────────

T18_no_pr_unreachable_skipped() {
    local repo="$TMPDIR_BASE/t18-repo"
    local stubdir="$TMPDIR_BASE/t18-stub"
    local stale_epoch="1577836800"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    # Branch is created with no origin remote → unreachable from default ref.
    make_branch_with_date "$repo" "feature/no-pr-t18" "$stale_epoch"

    local ghstubdir="$TMPDIR_BASE/t18-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
    *"--state open"*)    echo "0"; exit 0 ;;
    *"--state merged"*)  echo "0"; exit 0 ;;
    *"repo view"*)       echo '{"owner":{"login":"o"},"name":"r"}'; exit 0 ;;
    *)                   echo "[]"; exit 0 ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --apply --delete-no-pr --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T18 no_pr_unreachable_skipped: exit=$exit_code, out=$out"
        return
    fi

    local skipped del after
    skipped="$(ci_field "$out" no_pr_skipped_unreachable)"
    del="$(ci_field "$out" no_pr_deleted)"
    after="$(cd "$repo" && git branch --list "feature/no-pr-t18" 2>/dev/null)"

    if [ "${skipped:-0}" -ge 1 ] 2>/dev/null && [ "${del:-0}" = "0" ] 2>/dev/null && [ -n "$after" ]; then
        pass "T18 no_pr_unreachable_skipped (no_pr_skipped_unreachable>=1, branch kept)"
    else
        fail "T18 no_pr_unreachable_skipped: skipped=${skipped:-?} del=${del:-?} after=[$after], out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T2_unmerged_branch_skipped
T12_no_pr_dry_run_candidate
T13_apply_without_delete_no_pr_preserves
T14_apply_delete_no_pr_removes
T15_no_pr_branch_too_young_skipped
T18_no_pr_unreachable_skipped

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
