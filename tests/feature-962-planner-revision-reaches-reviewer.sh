#!/usr/bin/env bash
# Tests: bin/review-plan-codex, bin/run-codex-review-loop, bin/lib/codex-core.sh
# Tags: codex, review, bin, scope:issue-specific
# L3 gap: no real codex CLI/timing or end-to-end reviewer output check — covered
# at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# (category: skill-orchestration).
#
# Issue #962: cap-check must fire AFTER reviewer verdict, not BEFORE — OLD code
# let count=cap pre-existing rows block a re-run; NEW code sets
# limit = 1 + cap + extensions_used so the reviewer always gets one round.
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

    mkdir -p "$agents_dir/bin/lib" "$agents_dir/bin/lib/codex-review-loop"
    if [[ -f "$AGENTS_WORKTREE/bin/lib/codex-core.sh" ]]; then
      cp "$AGENTS_WORKTREE/bin/lib/codex-core.sh" "$agents_dir/bin/lib/codex-core.sh"
    fi
    if [[ -f "$AGENTS_WORKTREE/bin/lib/codex-timeout.sh" ]]; then
      cp "$AGENTS_WORKTREE/bin/lib/codex-timeout.sh" "$agents_dir/bin/lib/codex-timeout.sh"
    fi
    cp "$AGENTS_WORKTREE/bin/lib/safe-plans-path.sh" "$agents_dir/bin/lib/safe-plans-path.sh"
    cp "$AGENTS_WORKTREE/bin/concern-ledger" "$agents_dir/bin/concern-ledger"
    chmod +x "$agents_dir/bin/concern-ledger"
    cp "$AGENTS_WORKTREE/bin/lib/concern-ledger.sh" "$agents_dir/bin/lib/concern-ledger.sh"
    mkdir -p "$agents_dir/bin/lib/concern-ledger"
    cp "$AGENTS_WORKTREE"/bin/lib/concern-ledger/*.sh "$agents_dir/bin/lib/concern-ledger/"
    cp "$AGENTS_WORKTREE/bin/lib/codex-review-loop/ledger-verdict.sh" \
       "$agents_dir/bin/lib/codex-review-loop/ledger-verdict.sh"
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

# --force-round 2: a fresh fixture has no round counter, so a bare --round 2 is
# rejected before the gate under test runs (sequencing: feature-673-round-counter.sh).

# ---------------------------------------------------------------------------
# 1. Canonical #962: outline-plan CAP=1, round 2, 1 pre-existing row.
#    OLD: old_limit=1, count=1 >= 1 → blocked before the reviewer runs.
#    NEW: the reviewer runs and the verdict comes from the ledger tally — round 2
#    + HIGH residual + budget remaining is AUTO_EXTEND (exit 5) per the matrix in
#    bin/review-loop-verdict. #962 pins that a verdict is reached, not which one.
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
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 2 --ledger "$LEDGER" 2>/dev/null)
  rc=$?
  if echo "$CAPTURED" | grep -q 'begin-codex-output'; then
    pass "1: reviewer invoked at round 2 (begin-codex-output present)"
  else
    fail "1: reviewer was NOT invoked (begin-codex-output missing). Output: $CAPTURED"
  fi
  if [[ $rc -eq 5 ]]; then
    pass "1: round 2 + HIGH residual under remaining budget → exit 5 (AUTO_EXTEND)"
  else
    fail "1: expected exit 5 (AUTO_EXTEND), got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 2. Symmetric fix: detail-plan CAP=2, round 2, 2 pre-existing rows.
#    OLD: old_limit=2, count=2 >= 2 → blocked.
#    NEW: reviewer runs; same verdict path as case 1 → AUTO_EXTEND (exit 5).
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
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 2 --ledger "$LEDGER2" 2>/dev/null)
  rc=$?
  if echo "$CAPTURED" | grep -q 'begin-codex-output'; then
    pass "2: reviewer invoked at round 2 with 2 pre-existing rows (detail-plan)"
  else
    fail "2: reviewer was NOT invoked. Output: $CAPTURED"
  fi
  if [[ $rc -eq 5 ]]; then
    pass "2: detail-plan round 2 + HIGH residual under budget → exit 5 (AUTO_EXTEND)"
  else
    fail "2: expected exit 5 (AUTO_EXTEND), got $rc"
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
# 4. The plan.jsonl row count does not steer the cap gate. Same fixture as case 3
#    plus one pre-existing round-log row (and the mock appends a second), which
#    under the old row-counting gate would have reached limit=2 and forced exit 2.
#    Since #2068 the sole cap authority is the round number (codex_core_hard_cap_check
#    reads <round>, never the log): round 1 < limit 2 → CONTINUE, exit 1, identical
#    to case 3. This case exists to pin that equivalence.
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
  if [[ $rc -eq 1 ]]; then
    pass "4: a pre-existing round-log row does not move the cap gate → exit 1 (CONTINUE)"
  else
    fail "4: expected exit 1 (round number, not log rows, is the cap authority), got $rc"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
[[ $ERRORS -eq 0 ]] && echo "All tests passed" || { echo "$ERRORS test(s) failed"; exit 1; }
