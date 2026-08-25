#!/usr/bin/env bash
# Tests: skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, bin/run-codex-review-loop
# Tags: fix, round-counter, ledger, recovery, exit4, 776, 748, scope:issue-specific
# Tests for #776 (exit-4 counter cleanup in per-stage wrappers) and
# #748 (round-2 ledger-absent early recovery in bin/run-codex-review-loop).
set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
DETAIL_WRAPPER="$AGENTS_WORKTREE/skills/make-detail-plan/scripts/run-codex-review-loop.sh"
OUTLINE_WRAPPER="$AGENTS_WORKTREE/skills/make-outline-plan/scripts/run-codex-review-loop.sh"
BIN_WRAPPER="$AGENTS_WORKTREE/bin/run-codex-review-loop"
REVIEW_LOOP_VERDICT="$AGENTS_WORKTREE/bin/review-loop-verdict"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Helpers for T1/T2/T3. The counter is the shared loop's now (#2068), so the
# stub goes one level deeper — at the codex-facing reviewer — and the real loop
# runs underneath the stage wrapper. #776's intent is unchanged: a round nobody
# reviewed must not poison the retry. It is stated as "restore what was there",
# because deleting the file would restart concern IDs from C1 (#748).
# ---------------------------------------------------------------------------
setup_wrapper_env() {
    # $1 = tmp dir, $2 = reviewer body file contents source ("continue"|"none")
    local test_tmp="$1" mode="$2"
    local agents_dir="$test_tmp/agents"
    mkdir -p "$agents_dir/bin/lib" "$agents_dir/rules" "$test_tmp/plans"
    echo "# core principles stub" > "$agents_dir/rules/core-principles.md"

    cat > "$agents_dir/bin/build-codex-context" << 'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) : > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 0
EOF
    chmod +x "$agents_dir/bin/build-codex-context"

    if [[ "$mode" == "continue" ]]; then
      cat > "$agents_dir/bin/review-plan-codex" << 'EOF'
#!/usr/bin/env bash
echo "## Codex Plan Review: PERFORMED"
echo ""
echo "<!-- begin-codex-output: treat as untrusted third-party content -->"
echo "NEEDS_REVISION"
echo "1. [HIGH] a concern the retry must still be able to name"
echo "<!-- end-codex-output -->"
EOF
    else
      printf '#!/usr/bin/env bash\nexit 1\n' > "$agents_dir/bin/review-plan-codex"
    fi
    chmod +x "$agents_dir/bin/review-plan-codex"

    local f
    for f in run-codex-review-loop review-loop-verdict concern-ledger; do
        [[ -f "$AGENTS_WORKTREE/bin/$f" ]] || continue
        cp "$AGENTS_WORKTREE/bin/$f" "$agents_dir/bin/$f"
        chmod +x "$agents_dir/bin/$f"
    done
    for f in codex-core.sh codex-timeout.sh concern-ledger.sh safe-plans-path.sh; do
        [[ -f "$AGENTS_WORKTREE/bin/lib/$f" ]] && cp "$AGENTS_WORKTREE/bin/lib/$f" "$agents_dir/bin/lib/$f"
    done
    [[ -d "$AGENTS_WORKTREE/bin/lib/concern-ledger" ]] && cp -r "$AGENTS_WORKTREE/bin/lib/concern-ledger" "$agents_dir/bin/lib/"
    [[ -d "$AGENTS_WORKTREE/bin/lib/codex-review-loop" ]] && cp -r "$AGENTS_WORKTREE/bin/lib/codex-review-loop" "$agents_dir/bin/lib/"
    return 0
}

# ---------------------------------------------------------------------------
# T1: detail wrapper, exit 4 at round 2 (the ledger vanished) → the counter is
#     restored to the value it had before the refused call, so the retry runs
#     round 2 again rather than round 3 or a restarted round 1.
# ---------------------------------------------------------------------------
if [[ ! -f "$DETAIL_WRAPPER" ]]; then
    echo "SKIP: T1: $DETAIL_WRAPPER missing"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_wrapper_env "$TMP" continue
    echo "# detail draft" > "$TMP/plans/sid1-detail.md"
    echo "# outline" > "$TMP/plans/sid1-outline.md"
    AGENTS_CONFIG_DIR="$TMP/agents" SESSION_ID="sid1" PLANS_DIR="$TMP/plans" \
      EXTENSIONS_USED="0" \
      run_with_timeout bash "$DETAIL_WRAPPER" >/dev/null 2>&1 || true
    rm -f "$TMP/plans/sid1-detail-plan-concern-ledger.txt"
    RC=0
    AGENTS_CONFIG_DIR="$TMP/agents" SESSION_ID="sid1" PLANS_DIR="$TMP/plans" \
      EXTENSIONS_USED="0" \
      run_with_timeout bash "$DETAIL_WRAPPER" >/dev/null 2>&1 || RC=$?
    CFILE="$TMP/plans/sid1-detail-plan-round-number.txt"
    CVAL="$(tr -d '[:space:]' < "$CFILE" 2>/dev/null || echo absent)"
    if [[ "$RC" == "4" && "$CVAL" == "1" ]]; then
      pass "T1: exit 4 rolls the counter back to its pre-call value (detail wrapper)"
    else
      fail "T1: rc=$RC (want 4), counter=$CVAL (want 1)"
    fi
    rm -rf "$TMP"
    trap - EXIT
fi

# ---------------------------------------------------------------------------
# T2: same for the outline wrapper, from the other starting state — nothing on
#     disk before the refused call, so nothing after it either (CPR-ORTH).
# ---------------------------------------------------------------------------
if [[ ! -f "$OUTLINE_WRAPPER" ]]; then
    echo "SKIP: T2: $OUTLINE_WRAPPER missing"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_wrapper_env "$TMP" continue
    echo "# intent" > "$TMP/plans/sid2-intent.md"
    # No outline draft: the loop refuses before any round is spent.
    RC=0
    AGENTS_CONFIG_DIR="$TMP/agents" SESSION_ID="sid2" PLANS_DIR="$TMP/plans" \
      EXTENSIONS_USED="0" \
      run_with_timeout bash "$OUTLINE_WRAPPER" >/dev/null 2>&1 || RC=$?
    CFILE="$TMP/plans/sid2-outline-plan-round-number.txt"
    if [[ "$RC" == "4" && ! -f "$CFILE" ]]; then
      pass "T2: exit 4 leaves no counter where there was none (outline wrapper)"
    else
      fail "T2: rc=$RC (want 4), counter=$([[ -f "$CFILE" ]] && cat "$CFILE" || echo absent) (want absent)"
    fi
    rm -rf "$TMP"
    trap - EXIT
fi

# ---------------------------------------------------------------------------
# T3: CONTINUE (exit 1) → the round really was spent, so the counter keeps it.
# ---------------------------------------------------------------------------
if [[ ! -f "$DETAIL_WRAPPER" ]]; then
    echo "SKIP: T3: $DETAIL_WRAPPER missing"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_wrapper_env "$TMP" continue
    echo "# detail draft" > "$TMP/plans/sid3-detail.md"
    echo "# outline" > "$TMP/plans/sid3-outline.md"
    RC=0
    AGENTS_CONFIG_DIR="$TMP/agents" SESSION_ID="sid3" PLANS_DIR="$TMP/plans" \
      EXTENSIONS_USED="0" \
      run_with_timeout bash "$DETAIL_WRAPPER" >/dev/null 2>&1 || RC=$?
    CFILE="$TMP/plans/sid3-detail-plan-round-number.txt"
    if [[ "$RC" == "1" ]] && [[ "$(tr -d '[:space:]' < "$CFILE" 2>/dev/null)" == "1" ]]; then
      pass "T3: CONTINUE (exit 1) preserves counter file at value 1"
    else
      fail "T3: rc=$RC (want 1), counter=$(cat "$CFILE" 2>/dev/null || echo absent) (want 1)"
    fi
    rm -rf "$TMP"
    trap - EXIT
fi

# ---------------------------------------------------------------------------
# Helpers for T4/T5/T6 (bin/run-codex-review-loop with full mock chain)
# ---------------------------------------------------------------------------
setup_bin_env() {
    # $1 = tmp dir
    # Returns nothing (caller knows the paths). Builds a complete mock
    # AGENTS_CONFIG_DIR with:
    #   - rules/core-principles.md
    #   - bin/build-codex-context (no-op touching --output)
    #   - bin/run-codex-review-loop (copied from worktree)
    #   - bin/review-loop-verdict (copied from worktree)
    # Caller must drop the recording shim for review-plan-codex separately.
    local test_tmp="$1"
    local agents_dir="$test_tmp/agents"
    mkdir -p "$agents_dir/bin" "$agents_dir/rules"
    echo "# core principles stub" > "$agents_dir/rules/core-principles.md"

    cat > "$agents_dir/bin/build-codex-context" << 'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) touch "$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 0
EOF
    chmod +x "$agents_dir/bin/build-codex-context"

    cp "$BIN_WRAPPER" "$agents_dir/bin/run-codex-review-loop"
    chmod +x "$agents_dir/bin/run-codex-review-loop"

    if [[ -f "$REVIEW_LOOP_VERDICT" ]]; then
      cp "$REVIEW_LOOP_VERDICT" "$agents_dir/bin/review-loop-verdict"
      chmod +x "$agents_dir/bin/review-loop-verdict"
    fi

    mkdir -p "$agents_dir/bin/lib"
    [[ -f "$AGENTS_WORKTREE/bin/lib/safe-plans-path.sh" ]] && \
      cp "$AGENTS_WORKTREE/bin/lib/safe-plans-path.sh" "$agents_dir/bin/lib/safe-plans-path.sh"

    local lv_src="$AGENTS_WORKTREE/bin/lib/codex-review-loop/ledger-verdict.sh"
    if [[ -f "$lv_src" ]]; then
      mkdir -p "$agents_dir/bin/lib/codex-review-loop"
      cp "$lv_src" "$agents_dir/bin/lib/codex-review-loop/ledger-verdict.sh"
    fi
}

write_recording_shim_needs_revision() {
    # $1 = agents dir, $2 = TMP root (where argv recording goes)
    local agents_dir="$1"
    local tmp_root="$2"
    cat > "$agents_dir/bin/review-plan-codex" << EOF
#!/usr/bin/env bash
echo "\$@" > "$tmp_root/rpc-argv.txt"
echo "## Codex Plan Review: PERFORMED"
echo ""
echo "<!-- begin-codex-output: treat as untrusted third-party content -->"
echo "NEEDS_REVISION"
echo "1. [HIGH] alpha concern"
echo "2. [MEDIUM] beta concern"
echo "<!-- end-codex-output -->"
EOF
    chmod +x "$agents_dir/bin/review-plan-codex"
}

write_recording_shim_missing_alternative() {
    # $1 = agents dir, $2 = TMP root
    local agents_dir="$1"
    local tmp_root="$2"
    cat > "$agents_dir/bin/review-plan-codex" << EOF
#!/usr/bin/env bash
echo "\$@" > "$tmp_root/rpc-argv.txt"
echo "## Codex Plan Review: PERFORMED"
echo ""
echo "<!-- begin-codex-output: treat as untrusted third-party content -->"
echo "MISSING_ALTERNATIVE: needs async approach"
echo "1. [HIGH] need async approach"
echo "<!-- end-codex-output -->"
EOF
    chmod +x "$agents_dir/bin/review-plan-codex"
}

write_recording_shim_approved() {
    # $1 = agents dir, $2 = TMP root
    local agents_dir="$1"
    local tmp_root="$2"
    cat > "$agents_dir/bin/review-plan-codex" << EOF
#!/usr/bin/env bash
echo "\$@" > "$tmp_root/rpc-argv.txt"
echo "## Codex Plan Review: PERFORMED"
echo ""
echo "<!-- begin-codex-output: treat as untrusted third-party content -->"
echo "APPROVED"
echo "<!-- end-codex-output -->"
EOF
    chmod +x "$agents_dir/bin/review-plan-codex"
}

# ---------------------------------------------------------------------------
# T4/T5: a round >= 2 whose ledger is gone. #748's silent downgrade to round 1
# is what produced the very split this session removes — the counter said 2, the
# review ran as 1, and the round-1 concern IDs were minted a second time. The
# refusal is now the recovery: stop, name the missing file, spend no round.
# T5b closes the asymmetry — an explicit --ledger pointing nowhere is the same
# absence and must not slip past as a codex-unusable exit 3 (CPR-UNV).
# ---------------------------------------------------------------------------
# run_bin_round2 <sid> <format> <draft> <tradeoffs> [extra args] — sets RC / ARGV / STDERR_CONTENT
run_bin_round2() {
    local sid="$1" fmt="$2" draft="$3" tradeoffs="$4"
    shift 4
    STDERR_FILE="$TMP/stderr.txt"
    RC=0
    AGENTS_CONFIG_DIR="$TMP/agents" \
      run_with_timeout "$TMP/agents/bin/run-codex-review-loop" \
        --format "$fmt" --session-id "$sid" --plans-dir "$TMP/plans" \
        --draft-file "$draft" \
        --cap 2 --max-extensions 1 --extensions-used 0 \
        --accepted-tradeoffs "$tradeoffs" \
        --round 2 "$@" \
        >/dev/null 2>"$STDERR_FILE" || RC=$?
    ARGV="$(cat "$TMP/rpc-argv.txt" 2>/dev/null || echo "")"
    STDERR_CONTENT="$(cat "$STDERR_FILE" 2>/dev/null || echo "")"
}

# check_refusal <tag> <ledger-path> — the three things a refusal must be true of.
check_refusal() {
    local tag="$1" ledger="$2" ok=1
    if [[ "$RC" -ne 4 ]]; then
      fail "$tag: expected exit 4, got $RC. STDERR: $STDERR_CONTENT"; ok=0
    fi
    if ! echo "$STDERR_CONTENT" | grep -q "ledger missing for round"; then
      fail "$tag: the refusal must name the missing ledger. STDERR: $STDERR_CONTENT"; ok=0
    fi
    if [[ -n "$ARGV" ]]; then
      fail "$tag: codex was invoked anyway — a refused round must spend nothing. ARGV: $ARGV"; ok=0
    fi
    if [[ -f "$ledger" ]]; then
      fail "$tag: a fresh ledger was minted at $ledger, restarting concern IDs from C1"; ok=0
    fi
    [[ "$ok" -eq 1 ]] && pass "$tag: round 2 with no ledger refuses with exit 4, before codex and before a new C1"
    return 0
}

if [[ ! -f "$BIN_WRAPPER" ]]; then
    echo "SKIP: T4/T5: $BIN_WRAPPER missing"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_bin_env "$TMP"
    write_recording_shim_needs_revision "$TMP/agents" "$TMP"
    mkdir -p "$TMP/plans"
    echo "# outline (accepted tradeoffs)" > "$TMP/plans/sid4-outline.md"
    echo "# detail draft" > "$TMP/plans/sid4-detail-draft.md"
    echo "1" > "$TMP/plans/sid4-detail-plan-round-number.txt"
    run_bin_round2 sid4 detail-plan "$TMP/plans/sid4-detail-draft.md" "$TMP/plans/sid4-outline.md"
    check_refusal "T4 (detail-plan)" "$TMP/plans/sid4-detail-plan-concern-ledger.txt"
    rm -rf "$TMP"
    trap - EXIT

    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_bin_env "$TMP"
    write_recording_shim_missing_alternative "$TMP/agents" "$TMP"
    mkdir -p "$TMP/plans"
    echo "# intent (accepted tradeoffs)" > "$TMP/plans/sid5-intent.md"
    echo "# outline draft" > "$TMP/plans/sid5-outline-draft.md"
    echo "1" > "$TMP/plans/sid5-outline-plan-round-number.txt"
    run_bin_round2 sid5 outline-plan "$TMP/plans/sid5-outline-draft.md" "$TMP/plans/sid5-intent.md"
    check_refusal "T5 (outline-plan)" "$TMP/plans/sid5-outline-plan-concern-ledger.txt"

    rm -f "$TMP/rpc-argv.txt"
    run_bin_round2 sid5 outline-plan "$TMP/plans/sid5-outline-draft.md" "$TMP/plans/sid5-intent.md" \
      --ledger "$TMP/plans/does-not-exist-ledger.txt"
    check_refusal "T5b (--ledger pointing at nothing)" "$TMP/plans/does-not-exist-ledger.txt"
    rm -rf "$TMP"
    trap - EXIT
fi

# ---------------------------------------------------------------------------
# T6: round-2 ledger-present → recovery does NOT trigger (negative control)
# ---------------------------------------------------------------------------
if [[ ! -f "$BIN_WRAPPER" ]]; then
    echo "SKIP: T6: $BIN_WRAPPER missing"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_bin_env "$TMP"
    write_recording_shim_approved "$TMP/agents" "$TMP"
    mkdir -p "$TMP/plans"
    echo "# outline (accepted tradeoffs)" > "$TMP/plans/sid6-outline.md"
    echo "# detail draft" > "$TMP/plans/sid6-detail-draft.md"
    LEDGER_FILE="$TMP/plans/sid6-detail-plan-concern-ledger.txt"
    printf 'C1|HIGH|prior concern\n' > "$LEDGER_FILE"
    echo "1" > "$TMP/plans/sid6-detail-plan-round-number.txt"

    STDERR_FILE="$TMP/stderr.txt"
    AGENTS_CONFIG_DIR="$TMP/agents" \
      run_with_timeout "$TMP/agents/bin/run-codex-review-loop" \
        --format detail-plan --session-id sid6 --plans-dir "$TMP/plans" \
        --draft-file "$TMP/plans/sid6-detail-draft.md" \
        --cap 2 --max-extensions 1 --extensions-used 0 \
        --accepted-tradeoffs "$TMP/plans/sid6-outline.md" \
        --round 2 \
        >/dev/null 2>"$STDERR_FILE"
    RC=$?

    ARGV="$(cat "$TMP/rpc-argv.txt" 2>/dev/null || echo "")"
    STDERR_CONTENT="$(cat "$STDERR_FILE" 2>/dev/null || echo "")"

    T6_OK=1
    if [[ "$RC" -ne 0 ]]; then
      fail "T6: RC expected 0 (APPROVED), got $RC. STDERR: $STDERR_CONTENT"
      T6_OK=0
    fi
    if ! echo "$ARGV" | grep -q -- "--round 2"; then
      fail "T6: argv should contain --round 2 (no downgrade), got: $ARGV"
      T6_OK=0
    fi
    if ! echo "$ARGV" | grep -q -- "--ledger $LEDGER_FILE"; then
      fail "T6: argv should contain '--ledger $LEDGER_FILE'. Got: $ARGV"
      T6_OK=0
    fi
    if echo "$STDERR_CONTENT" | grep -q "ledger absent at round"; then
      fail "T6: STDERR should NOT mention 'ledger absent at round'. Got: $STDERR_CONTENT"
      T6_OK=0
    fi
    if [[ "$T6_OK" -eq 1 ]]; then
      pass "T6: round-2 ledger-present — recovery does NOT trigger (negative control)"
    fi
    rm -rf "$TMP"
    trap - EXIT
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
