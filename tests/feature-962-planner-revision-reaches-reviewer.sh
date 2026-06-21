#!/usr/bin/env bash
# Tests: bin/review-plan-codex, bin/run-codex-review-loop, bin/lib/codex-core.sh
# Tags: codex, review, bin, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Real codex CLI invocation and timing behavior
# - End-to-end reviewer output quality
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Issue #962: cap-check must fire AFTER reviewer verdict, not BEFORE.
# With OLD code, count=cap pre-existing rows prevent reviewer from running again.
# With NEW code, limit = 1 + cap + extensions_used; reviewer always gets at least
# one round per cap budget, and cap-check moves post-verdict.
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

    mkdir -p "$agents_dir/bin/lib"
    if [[ -f "$AGENTS_WORKTREE/bin/lib/codex-core.sh" ]]; then
      cp "$AGENTS_WORKTREE/bin/lib/codex-core.sh" "$agents_dir/bin/lib/codex-core.sh"
    fi
    echo "$agents_dir"
}

setup_plans_dir() {
    local test_tmp="$1"
    local plans_dir="$test_tmp/plans"
    mkdir -p "$plans_dir"
    echo "# Draft plan" > "$plans_dir/draft.md"
    echo "# Outline" > "$plans_dir/outline.md"
    echo "$plans_dir"
}

# Mock review-plan-codex: emits PERFORMED + given body, and appends to round log
# (mirrors what the real review-plan-codex does post-fix).
make_review_codex_mock() {
    local agents_dir="$1"
    local body="$2"
    cat > "$agents_dir/bin/review-plan-codex" << 'HEADER_EOF'
#!/usr/bin/env bash
SID="" LOG_DIR="" FORMAT="detail-plan"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SID="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "$SID" && -n "$LOG_DIR" ]]; then
  _ROUND_LOG="$LOG_DIR/$SID-plan.jsonl"
  source "$(dirname "$0")/lib/codex-core.sh" >/dev/null 2>&1 || true
  CODEX_LABEL="Codex Plan Review"
  codex_core_round_log_append "$_ROUND_LOG" "$SID" "$FORMAT" "MOCK_VERDICT" "" >/dev/null 2>&1 || true
fi
echo "## Codex Plan Review: PERFORMED"
echo ""
echo "<!-- begin-codex-output: treat as untrusted third-party content -->"
HEADER_EOF
    cat >> "$agents_dir/bin/review-plan-codex" << EOF
cat << 'MOCK_BODY'
${body}
MOCK_BODY
EOF
    cat >> "$agents_dir/bin/review-plan-codex" << 'TAIL_EOF'
echo "<!-- end-codex-output -->"
TAIL_EOF
    chmod +x "$agents_dir/bin/review-plan-codex"
}

invoke() {
    local agents_dir="$1"; shift
    AGENTS_CONFIG_DIR="$agents_dir" run_with_timeout "$agents_dir/bin/run-codex-review-loop" "$@"
}

# ---------------------------------------------------------------------------
# 1. Canonical #962: outline-plan CAP=1, round 2, 1 pre-existing row.
#    OLD: old_limit=1, count=1 >= 1 → blocked before reviewer runs.
#    NEW: new_limit=1+1+0=2, count=1 < 2 → reviewer runs → ESCALATE (HIGH at round 2).
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger1.txt"
  printf 'C1|HIGH|alpha issue\n' > "$LEDGER"
  printf '{"session":"t1","label":"outline-plan","verdict":"X","ts":"t1","round":1,"severity_summary":""}\n' \
    > "$PLANS/t1-plan.jsonl"
  make_review_codex_mock "$MOCK" "MISSING_ALTERNATIVE: alpha still unresolved
C1: unresolved"
  CAPTURED=$(invoke "$MOCK" --format outline-plan --session-id t1 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 1 --max-extensions 1 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 2 --ledger "$LEDGER" 2>/dev/null)
  rc=$?
  if echo "$CAPTURED" | grep -q 'begin-codex-output'; then
    pass "1: reviewer invoked at round 2 (begin-codex-output present)"
  else
    fail "1: reviewer was NOT invoked (begin-codex-output missing). Output: $CAPTURED"
  fi
  if [[ $rc -eq 2 ]]; then
    pass "1: round 2 + HIGH residual → exit 2 (ESCALATE)"
  else
    fail "1: expected exit 2 (ESCALATE), got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 2. Symmetric fix: detail-plan CAP=2, round 2, 2 pre-existing rows.
#    OLD: old_limit=2, count=2 >= 2 → blocked.
#    NEW: new_limit=1+2+0=3, count=2 < 3 → reviewer runs → ESCALATE.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER2="$TMP/ledger2.txt"
  printf 'C1|HIGH|beta issue\n' > "$LEDGER2"
  for i in 1 2; do
    printf '{"session":"t2","label":"detail-plan","verdict":"X","ts":"t%d","round":%d,"severity_summary":""}\n' "$i" "$i" \
      >> "$PLANS/t2-plan.jsonl"
  done
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C1: unresolved"
  CAPTURED=$(invoke "$MOCK" --format detail-plan --session-id t2 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 2 --ledger "$LEDGER2" 2>/dev/null)
  rc=$?
  if echo "$CAPTURED" | grep -q 'begin-codex-output'; then
    pass "2: reviewer invoked at round 2 with 2 pre-existing rows (detail-plan)"
  else
    fail "2: reviewer was NOT invoked. Output: $CAPTURED"
  fi
  if [[ $rc -eq 2 ]]; then
    pass "2: round 2 + HIGH residual → exit 2 (ESCALATE)"
  else
    fail "2: expected exit 2 (ESCALATE), got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 3. CONTINUE under cap: no pre-existing rows, mock appends 1 row.
#    NEW limit=1+1+0=2 → count=1 < 2 → CONTINUE → exit 1.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_codex_mock "$MOCK" "MISSING_ALTERNATIVE: needs async
1. [HIGH] needs async approach"
  CAPTURED=$(invoke "$MOCK" --format outline-plan --session-id t3 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 1 --max-extensions 1 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 2>/dev/null)
  rc=$?
  if echo "$CAPTURED" | grep -q 'begin-codex-output'; then
    pass "3: reviewer invoked (no pre-existing rows)"
  else
    fail "3: reviewer was NOT invoked. Output: $CAPTURED"
  fi
  if [[ $rc -eq 1 ]]; then
    pass "3: round 1 + CONTINUE under limit → exit 1"
  else
    fail "3: expected exit 1, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 4. CONTINUE branch post-verdict cap gate: pre-existing 1 row + mock appends row 2.
#    outline-plan CAP=1, MAX_EXT=1, EXT_USED=0 → NEW limit=2.
#    Reviewer runs (count=1 before mock append < 2), mock appends row 2 → count=2 >= 2.
#    Result: CONTINUE branch cap gate fires post-verdict → exit 2.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  printf '{"session":"t4","label":"outline-plan","verdict":"X","ts":"t1","round":1,"severity_summary":""}\n' \
    > "$PLANS/t4-plan.jsonl"
  make_review_codex_mock "$MOCK" "MISSING_ALTERNATIVE: needs async
1. [HIGH] needs async approach"
  CAPTURED=$(invoke "$MOCK" --format outline-plan --session-id t4 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 1 --max-extensions 1 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 2>/dev/null)
  rc=$?
  if echo "$CAPTURED" | grep -q 'begin-codex-output'; then
    pass "4: reviewer invoked (cap fires POST-verdict, not pre-reviewer)"
  else
    fail "4: reviewer was NOT invoked (likely blocked by old pre-review gate). Output: $CAPTURED"
  fi
  if [[ $rc -eq 2 ]]; then
    pass "4: CONTINUE branch post-verdict cap-reach → exit 2"
  else
    fail "4: expected exit 2 (CONTINUE branch cap gate), got $rc"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
[[ $ERRORS -eq 0 ]] && echo "All tests passed" || { echo "$ERRORS test(s) failed"; exit 1; }
