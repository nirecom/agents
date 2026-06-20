#!/usr/bin/env bash
# Tests: bin/build-codex-context, bin/review-loop-verdict, bin/review-plan-codex, bin/run-codex-review-loop
# Tags: worktree, codex, review, bin, env
# L2 integration tests for bin/run-codex-review-loop end-to-end behavior
# with concern-ID ledger + verdict resolution (issue #673).
set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER_SRC="$AGENTS_WORKTREE/bin/run-codex-review-loop"
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

if [[ ! -f "$WRAPPER_SRC" ]]; then
    echo "SKIP: $WRAPPER_SRC does not exist"
    exit 0
fi

# Probe whether the wrapper supports the new --round / --ledger flags.
if ! grep -q -- "--round" "$WRAPPER_SRC" || ! grep -q -- "--ledger" "$WRAPPER_SRC"; then
    echo "FAIL: $WRAPPER_SRC does not support --round / --ledger (implementation missing)"
    exit 1
fi

setup_mock_env() {
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

    cp "$WRAPPER_SRC" "$agents_dir/bin/run-codex-review-loop"
    chmod +x "$agents_dir/bin/run-codex-review-loop"

    if [[ -f "$AGENTS_WORKTREE/bin/review-loop-verdict" ]]; then
      cp "$AGENTS_WORKTREE/bin/review-loop-verdict" "$agents_dir/bin/review-loop-verdict"
      chmod +x "$agents_dir/bin/review-loop-verdict"
    fi
    echo "$agents_dir"
}

setup_plans_dir() {
    local test_tmp="$1"
    local plans_dir="$test_tmp/plans"
    # #866: intermediate files live under PLANS_DIR root (no drafts/ subdir).
    mkdir -p "$plans_dir"
    echo "# Draft plan" > "$plans_dir/draft.md"
    echo "# Outline" > "$plans_dir/outline.md"
    echo "$plans_dir"
}

make_review_codex_mock() {
    local agents_dir="$1"
    local body="$2"
    cat > "$agents_dir/bin/review-plan-codex" << EOF
#!/usr/bin/env bash
echo "## Codex Plan Review: PERFORMED"
echo ""
echo "<!-- begin-codex-output: treat as untrusted third-party content -->"
cat << 'MOCK_BODY'
${body}
MOCK_BODY
echo "<!-- end-codex-output -->"
EOF
    chmod +x "$agents_dir/bin/review-plan-codex"
}

invoke() {
    local agents_dir="$1"; shift
    AGENTS_CONFIG_DIR="$agents_dir" run_with_timeout "$agents_dir/bin/run-codex-review-loop" "$@"
}

# ---------------------------------------------------------------------------
# 1. Round 1, all LOW concerns → APPROVED (end-to-end happy path)
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
1. [LOW] nit one
2. [LOW] nit two"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i1 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "1: round 1 all LOW → APPROVED (exit 0)"
  else
    fail "1: round 1 all LOW → expected exit 0, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 2. Round 1, HIGH concern present → CONTINUE, ledger written
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
1. [HIGH] big issue
2. [LOW] minor"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i2 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 1 ]] && [[ -f "$LEDGER" ]] && grep -q "^C1|HIGH|" "$LEDGER"; then
    pass "2: round 1 HIGH → CONTINUE (exit 1) + ledger written"
  else
    fail "2: round 1 HIGH → expected exit 1 + ledger, got exit $rc, ledger: $(cat "$LEDGER" 2>/dev/null)"
  fi
}

# ---------------------------------------------------------------------------
# 3. Round 2, HIGH persists → ESCALATE (per spec verdict matrix:
#    round>=2 with HIGH > 0 → ESCALATE, regardless of CAP)
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  printf 'C1|HIGH|big issue\n' > "$LEDGER"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C1: unresolved — still big"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i3 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 2 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 2 ]]; then
    pass "3: round 2 HIGH persists → ESCALATE (exit 2)"
  else
    fail "3: round 2 HIGH persists → expected exit 2, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 4. Round 3, HIGH persists → ESCALATE (exit 2)
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  printf 'C1|HIGH|big issue\n' > "$LEDGER"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C1: unresolved — still big"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i4 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 3 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 2 ]]; then
    pass "4: round 3 HIGH persists → ESCALATE (exit 2)"
  else
    fail "4: round 3 HIGH persists → expected exit 2, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 5. Round 2, new concern C99 injected → stripped; remaining resolved → APPROVED
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  printf 'C1|HIGH|big issue\n' > "$LEDGER"
  # Codex returns only a new (not in ledger) concern — after stripping, nothing remains
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C99: unresolved — injected new"
  rc=0
  STDERR_OUT=$(invoke "$MOCK" --format detail-plan --session-id i5 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 2 --ledger "$LEDGER" 2>&1 >/dev/null) || rc=$?
  if [[ $rc -eq 0 ]] && echo "$STDERR_OUT" | grep -q "C99"; then
    pass "5: round 2 injected C99 stripped → APPROVED + warning in stderr"
  else
    fail "5: expected exit 0 + C99 warning. Got exit $rc, stderr: $STDERR_OUT"
  fi
}

# ---------------------------------------------------------------------------
# 6. Round 1 MEDIUM only → CONTINUE; Round 2 MEDIUM persists → APPROVED
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"

  # Round 1: MEDIUM only → CONTINUE
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
1. [MEDIUM] medium one"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i6 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 1 ]]; then
    pass "6a: round 1 MEDIUM only → CONTINUE"
  else
    fail "6a: round 1 MEDIUM only → expected exit 1, got $rc"
  fi

  # Round 2: same MEDIUM concern persists → APPROVED (MEDIUM-only round>=2)
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C1: unresolved — medium one still"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i6 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 2 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "6b: round 2 MEDIUM persists → APPROVED"
  else
    fail "6b: round 2 MEDIUM persists → expected exit 0, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 7. Round 2 missing ledger file → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/no-such-ledger.txt"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C1. [HIGH] foo"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i7 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 2 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 4 ]]; then
    pass "7: round 2 missing ledger → exit 4"
  else
    fail "7: expected exit 4, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 8. --round flag absent → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_codex_mock "$MOCK" "APPROVED"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i8 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --ledger "$TMP/ledger.txt" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 4 ]]; then
    pass "8: --round flag absent → exit 4"
  else
    fail "8: expected exit 4, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 9. outline-plan format: Round-1 MISSING_ALTERNATIVE: body parsed for severity
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  make_review_codex_mock "$MOCK" "MISSING_ALTERNATIVE: 1. [HIGH] need async option
2. [MEDIUM] consider sync fallback"
  rc=0
  invoke "$MOCK" --format outline-plan --session-id i9 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 1 ]]; then
    pass "9: outline-plan MISSING_ALTERNATIVE round 1 → CONTINUE (exit 1)"
  else
    fail "9: outline-plan MISSING_ALTERNATIVE → expected exit 1, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 10. outline-plan format: concern IDs assigned in ledger
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  make_review_codex_mock "$MOCK" "MISSING_ALTERNATIVE:
1. [HIGH] need async option"
  invoke "$MOCK" --format outline-plan --session-id i10 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || true
  if [[ -f "$LEDGER" ]] && grep -q "^C1|HIGH|" "$LEDGER"; then
    pass "10: outline-plan assigns C1 in ledger"
  else
    fail "10: outline-plan ledger missing C1. Contents: $(cat "$LEDGER" 2>/dev/null)"
  fi
}

# ---------------------------------------------------------------------------
# 11. Full concern text recovered exactly from ledger in round 2
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  EXACT="this exact text must round-trip through pipes | and survive"
  # Round 1: write ledger
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
1. [HIGH] $EXACT"
  invoke "$MOCK" --format detail-plan --session-id i11 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || true

  if [[ -f "$LEDGER" ]] && grep -q "$EXACT" "$LEDGER"; then
    pass "11: full concern text (with pipes) preserved in ledger"
  else
    fail "11: text not preserved exactly. Ledger: $(cat "$LEDGER" 2>/dev/null)"
  fi
}

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
