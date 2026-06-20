#!/usr/bin/env bash
# Tests: skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, bin/run-codex-review-loop
# Tags: fix, round-counter, ledger, recovery, exit4, 776, 748
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
# Helpers for T1/T2/T3 (per-stage wrappers with stub bin/run-codex-review-loop)
# ---------------------------------------------------------------------------
setup_wrapper_env() {
    # $1 = tmp dir, $2 = exit code for stub bin/run-codex-review-loop
    local test_tmp="$1"
    local exit_code="$2"
    local agents_dir="$test_tmp/agents"
    mkdir -p "$agents_dir/bin"
    cat > "$agents_dir/bin/run-codex-review-loop" << EOF
#!/usr/bin/env bash
exit $exit_code
EOF
    chmod +x "$agents_dir/bin/run-codex-review-loop"

    local plans_dir="$test_tmp/plans"
    # #866: intermediate files live under PLANS_DIR root (no drafts/ subdir).
    mkdir -p "$plans_dir"
    echo "# Detail draft" > "$plans_dir/sid-detail-draft.md"
    echo "# Outline" > "$plans_dir/sid-outline.md"
}

# ---------------------------------------------------------------------------
# T1: detail wrapper + exit 4 → counter file absent
# ---------------------------------------------------------------------------
if [[ ! -f "$DETAIL_WRAPPER" ]]; then
    echo "SKIP: T1: $DETAIL_WRAPPER missing"
elif ! grep -qE '0\|2\|4' "$DETAIL_WRAPPER"; then
    echo "SKIP: T1: exit-4 cleanup not yet in detail wrapper"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_wrapper_env "$TMP" 4
    # Ensure detail draft exists for this session id
    echo "# detail draft" > "$TMP/plans/sid1-detail-draft.md"
    AGENTS_CONFIG_DIR="$TMP/agents" SESSION_ID="sid1" PLANS_DIR="$TMP/plans" \
      EXTENSIONS_USED="0" \
      run_with_timeout bash "$DETAIL_WRAPPER" >/dev/null 2>&1 || true
    CFILE="$TMP/plans/sid1-detail-plan-round-number.txt"
    if [[ ! -f "$CFILE" ]]; then
      pass "T1: exit 4 deletes counter file (detail wrapper)"
    else
      fail "T1: counter file still exists after exit 4. Path: $CFILE, content: $(cat "$CFILE" 2>/dev/null)"
    fi
    rm -rf "$TMP"
    trap - EXIT
fi

# ---------------------------------------------------------------------------
# T2: outline wrapper + exit 4 → counter file absent
# ---------------------------------------------------------------------------
if [[ ! -f "$OUTLINE_WRAPPER" ]]; then
    echo "SKIP: T2: $OUTLINE_WRAPPER missing"
elif ! grep -qE '0\|2\|4' "$OUTLINE_WRAPPER"; then
    echo "SKIP: T2: exit-4 cleanup not yet in outline wrapper"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_wrapper_env "$TMP" 4
    # outline wrapper requires an outline draft file
    echo "# outline draft" > "$TMP/plans/sid2-outline-draft.md"
    echo "# intent" > "$TMP/plans/sid2-intent.md"
    AGENTS_CONFIG_DIR="$TMP/agents" SESSION_ID="sid2" PLANS_DIR="$TMP/plans" \
      EXTENSIONS_USED="0" \
      run_with_timeout bash "$OUTLINE_WRAPPER" >/dev/null 2>&1 || true
    CFILE="$TMP/plans/sid2-outline-plan-round-number.txt"
    if [[ ! -f "$CFILE" ]]; then
      pass "T2: exit 4 deletes counter file (outline wrapper)"
    else
      fail "T2: counter file still exists after exit 4. Path: $CFILE, content: $(cat "$CFILE" 2>/dev/null)"
    fi
    rm -rf "$TMP"
    trap - EXIT
fi

# ---------------------------------------------------------------------------
# T3: CONTINUE (exit 1) → counter still present at value 1 (regression guard)
# ---------------------------------------------------------------------------
if [[ ! -f "$DETAIL_WRAPPER" ]]; then
    echo "SKIP: T3: $DETAIL_WRAPPER missing"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_wrapper_env "$TMP" 1
    echo "# detail draft" > "$TMP/plans/sid3-detail-draft.md"
    AGENTS_CONFIG_DIR="$TMP/agents" SESSION_ID="sid3" PLANS_DIR="$TMP/plans" \
      EXTENSIONS_USED="0" \
      run_with_timeout bash "$DETAIL_WRAPPER" >/dev/null 2>&1 || true
    CFILE="$TMP/plans/sid3-detail-plan-round-number.txt"
    if [[ -f "$CFILE" ]] && [[ "$(tr -d '[:space:]' < "$CFILE")" == "1" ]]; then
      pass "T3: CONTINUE (exit 1) preserves counter file at value 1"
    else
      fail "T3: counter file missing or wrong value after CONTINUE. Path: $CFILE, content: $(cat "$CFILE" 2>/dev/null)"
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
# T4: round-2 ledger-absent early recovery (detail-plan)
# ---------------------------------------------------------------------------
if [[ ! -f "$BIN_WRAPPER" ]]; then
    echo "SKIP: T4: $BIN_WRAPPER missing"
elif ! grep -q 'ledger absent at round' "$BIN_WRAPPER"; then
    echo "SKIP: T4: round-2 ledger-absent recovery not yet in bin wrapper"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_bin_env "$TMP"
    write_recording_shim_needs_revision "$TMP/agents" "$TMP"
    mkdir -p "$TMP/plans"
    echo "# outline (accepted tradeoffs)" > "$TMP/plans/sid4-outline.md"
    echo "# detail draft" > "$TMP/plans/sid4-detail-draft.md"
    # Do NOT create a ledger file

    STDERR_FILE="$TMP/stderr.txt"
    AGENTS_CONFIG_DIR="$TMP/agents" \
      run_with_timeout "$TMP/agents/bin/run-codex-review-loop" \
        --format detail-plan --session-id sid4 --plans-dir "$TMP/plans" \
        --draft-file "$TMP/plans/sid4-detail-draft.md" \
        --cap 2 --max-extensions 1 --extensions-used 0 \
        --accepted-tradeoffs "$TMP/plans/sid4-outline.md" \
        --round 2 \
        >/dev/null 2>"$STDERR_FILE"
    RC=$?

    ARGV="$(cat "$TMP/rpc-argv.txt" 2>/dev/null || echo "")"
    STDERR_CONTENT="$(cat "$STDERR_FILE" 2>/dev/null || echo "")"
    LEDGER_FILE="$TMP/plans/sid4-detail-plan-concern-ledger.txt"

    T4_OK=1
    if [[ "$RC" -ne 0 && "$RC" -ne 1 && "$RC" -ne 2 ]]; then
      fail "T4: RC expected 0|1|2, got $RC. STDERR: $STDERR_CONTENT"
      T4_OK=0
    fi
    if ! echo "$ARGV" | grep -q -- "--round 1"; then
      fail "T4: argv should contain --round 1, got: $ARGV"
      T4_OK=0
    fi
    if echo "$ARGV" | grep -q -- "--ledger"; then
      fail "T4: argv should NOT contain --ledger, got: $ARGV"
      T4_OK=0
    fi
    if [[ ! -f "$LEDGER_FILE" ]]; then
      fail "T4: ledger file not created at $LEDGER_FILE"
      T4_OK=0
    elif ! grep -q "C1|HIGH|" "$LEDGER_FILE" || ! grep -q "C2|MEDIUM|" "$LEDGER_FILE"; then
      fail "T4: ledger missing expected entries. Content: $(cat "$LEDGER_FILE")"
      T4_OK=0
    fi
    if ! echo "$STDERR_CONTENT" | grep -q "ledger absent at round"; then
      fail "T4: STDERR should mention 'ledger absent at round'. Got: $STDERR_CONTENT"
      T4_OK=0
    fi
    if [[ "$T4_OK" -eq 1 ]]; then
      pass "T4: round-2 ledger-absent recovery (detail-plan) — downgrade to round 1, no --ledger, ledger created, warning emitted"
    fi
    rm -rf "$TMP"
    trap - EXIT
fi

# ---------------------------------------------------------------------------
# T5: round-2 ledger-absent early recovery (outline-plan)
# ---------------------------------------------------------------------------
if [[ ! -f "$BIN_WRAPPER" ]]; then
    echo "SKIP: T5: $BIN_WRAPPER missing"
elif ! grep -q 'ledger absent at round' "$BIN_WRAPPER"; then
    echo "SKIP: T5: round-2 ledger-absent recovery not yet in bin wrapper"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    setup_bin_env "$TMP"
    write_recording_shim_missing_alternative "$TMP/agents" "$TMP"
    mkdir -p "$TMP/plans"
    echo "# intent (accepted tradeoffs)" > "$TMP/plans/sid5-intent.md"
    echo "# outline draft" > "$TMP/plans/sid5-outline-draft.md"
    # Do NOT create a ledger file

    STDERR_FILE="$TMP/stderr.txt"
    AGENTS_CONFIG_DIR="$TMP/agents" \
      run_with_timeout "$TMP/agents/bin/run-codex-review-loop" \
        --format outline-plan --session-id sid5 --plans-dir "$TMP/plans" \
        --draft-file "$TMP/plans/sid5-outline-draft.md" \
        --cap 2 --max-extensions 1 --extensions-used 0 \
        --accepted-tradeoffs "$TMP/plans/sid5-intent.md" \
        --round 2 \
        >/dev/null 2>"$STDERR_FILE"
    RC=$?

    ARGV="$(cat "$TMP/rpc-argv.txt" 2>/dev/null || echo "")"
    STDERR_CONTENT="$(cat "$STDERR_FILE" 2>/dev/null || echo "")"
    LEDGER_FILE="$TMP/plans/sid5-outline-plan-concern-ledger.txt"

    T5_OK=1
    if [[ "$RC" -ne 0 && "$RC" -ne 1 && "$RC" -ne 2 ]]; then
      fail "T5: RC expected 0|1|2, got $RC. STDERR: $STDERR_CONTENT"
      T5_OK=0
    fi
    if ! echo "$ARGV" | grep -q -- "--round 1"; then
      fail "T5: argv should contain --round 1, got: $ARGV"
      T5_OK=0
    fi
    if echo "$ARGV" | grep -q -- "--ledger"; then
      fail "T5: argv should NOT contain --ledger, got: $ARGV"
      T5_OK=0
    fi
    if [[ ! -f "$LEDGER_FILE" ]]; then
      fail "T5: ledger file not created at $LEDGER_FILE"
      T5_OK=0
    elif ! grep -q "C1|HIGH|" "$LEDGER_FILE"; then
      fail "T5: ledger missing C1|HIGH entry. Content: $(cat "$LEDGER_FILE")"
      T5_OK=0
    fi
    if ! echo "$STDERR_CONTENT" | grep -q "ledger absent at round"; then
      fail "T5: STDERR should mention 'ledger absent at round'. Got: $STDERR_CONTENT"
      T5_OK=0
    fi
    if [[ "$T5_OK" -eq 1 ]]; then
      pass "T5: round-2 ledger-absent recovery (outline-plan) — downgrade to round 1, no --ledger, ledger created, warning emitted"
    fi
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
