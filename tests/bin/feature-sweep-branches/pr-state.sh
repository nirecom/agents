#!/bin/bash
# tests/feature-sweep-branches/pr-state.sh
# PR-state sweep tests: open-PR preservation + unknown-state safety.
# Tests: T16, T19
#
# Sourced helpers come from _lib.sh. Runnable standalone:
#   bash tests/feature-sweep-branches/pr-state.sh

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T16 — open-unmerged-PR branch: --state all returns "1", --state merged "0"
#       → unmerged_pr_skipped>=1, no_pr_candidates=0, branch preserved
# ─────────────────────────────────────────────────────────────────────────────

T16_open_unmerged_pr_branch_preserved() {
    local repo="$TMPDIR_BASE/t16-repo"
    local stubdir="$TMPDIR_BASE/t16-stub"
    local stale_epoch="1577836800"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    make_branch_with_date "$repo" "feature/open-t16" "$stale_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T16 open_unmerged_pr_branch_preserved: $SWEEP not found / not executable"
        return
    fi

    local ghstubdir="$TMPDIR_BASE/t16-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
    *"--state open"*)    echo "1"; exit 0 ;;
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
        fail "T16 open_unmerged_pr_branch_preserved: exit=$exit_code, out=$out"
        return
    fi

    local skipped cands after
    skipped="$(ci_field "$out" unmerged_pr_skipped)"
    cands="$(ci_field "$out" no_pr_candidates)"
    after="$(cd "$repo" && git branch --list "feature/open-t16" 2>/dev/null)"

    if [ "${skipped:-0}" -ge 1 ] 2>/dev/null && [ "${cands:-0}" = "0" ] 2>/dev/null && [ -n "$after" ]; then
        pass "T16 open_unmerged_pr_branch_preserved (unmerged_pr_skipped>=1, no_pr_candidates=0, branch kept)"
    else
        fail "T16 open_unmerged_pr_branch_preserved: unmerged_pr_skipped=${skipped:-?} no_pr_candidates=${cands:-?} after=[$after], out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T19 — gh failure → pr_state_unknown counter increments, no deletion
#       (HIGH #1 unknown-state safety from Codex review)
# ─────────────────────────────────────────────────────────────────────────────

T19_pr_state_unknown_skipped() {
    local repo="$TMPDIR_BASE/t19-repo"
    local stubdir="$TMPDIR_BASE/t19-stub"
    local stale_epoch="1577836800"
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"
    make_branch_with_date "$repo" "feature/unknown-t19" "$stale_epoch"

    # Stub gh exits non-zero so classify_pr_state must return "unknown".
    local ghstubdir="$TMPDIR_BASE/t19-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
    *"repo view"*)       echo '{"owner":{"login":"o"},"name":"r"}'; exit 0 ;;
    *)                   echo "transient API error" >&2; exit 1 ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        SWEEP_AGE_DAYS=1 \
        run_with_timeout bash "$SWEEP" --apply --delete-no-pr --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T19 pr_state_unknown_skipped: exit=$exit_code, out=$out"
        return
    fi

    local unknown del after
    unknown="$(ci_field "$out" pr_state_unknown)"
    del="$(ci_field "$out" no_pr_deleted)"
    after="$(cd "$repo" && git branch --list "feature/unknown-t19" 2>/dev/null)"

    if [ "${unknown:-0}" -ge 1 ] 2>/dev/null && [ "${del:-0}" = "0" ] 2>/dev/null && [ -n "$after" ]; then
        pass "T19 pr_state_unknown_skipped (pr_state_unknown>=1, branch kept)"
    else
        fail "T19 pr_state_unknown_skipped: unknown=${unknown:-?} del=${del:-?} after=[$after], out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T16_open_unmerged_pr_branch_preserved
T19_pr_state_unknown_skipped

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
