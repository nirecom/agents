#!/usr/bin/env bash
# Tests: bin/review-plan-codex, bin/run-codex-review-loop
# Tags: codex, review, regression, scope:issue-specific
#
# Regression test for #1734: bin/review-plan-codex's truncation warning
# ("Warning: plan is N lines, truncating to 5000 for codex.") was printed to
# stdout instead of stderr. bin/run-codex-review-loop parses the first
# non-blank stdout line as the status header (awk 'NF{print; exit}') — when
# the warning lands on stdout it gets misread as the header, causing a false
# "unrecognized status header" die() -> exit 4 (HALT) instead of proceeding
# with the review, whenever the plan/draft exceeds MAX_PLAN_LINES=5000 lines.
#
# TL3 gap: this test drives bin/review-plan-codex and bin/run-codex-review-loop
# directly (real bash scripts, real codex-core.sh, real review-loop-verdict)
# but substitutes a mock `codex` binary and a stub build-codex-context — it
# does not exercise the real codex CLI or a real workflow session. A genuine
# TL3/TL4 gap remains: an end-to-end run of make-detail-plan against the real
# codex CLI with an oversized draft, which only a live environment can cover.
#
# Mitigation: this test exercises the exact real bash code paths that the
# real codex CLI/session would invoke — only the codex binary itself and the
# context-builder are substituted; the stdout/stderr channel behavior under
# test (the truncation-warning routing that #1734 regressed) is fully
# exercised by real code, not mocked.
#
# Verification-gate category (rules/test.md Risk categories, SSOT
# bin/check-verification-gate.sh): skill-orchestration — this gap is
# precisely "did you run the skill end-to-end (not just unit-tested its
# scripts)?", since bin/review-plan-codex and bin/run-codex-review-loop are
# invoked by the review-plan-codex / make-detail-plan skills and only a live
# skill run against the real codex CLI closes the remaining gap.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEWER="$AGENTS_ROOT/bin/review-plan-codex"
RUN_LOOP="$AGENTS_ROOT/bin/run-codex-review-loop"
CODEX_CORE="$AGENTS_ROOT/bin/lib/codex-core.sh"
VERDICT_BIN="$AGENTS_ROOT/bin/review-loop-verdict"
TIMEOUT_SH="$AGENTS_ROOT/bin/run-with-timeout.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Setup: 5100-line plan/draft file (over MAX_PLAN_LINES=5000)
# ---------------------------------------------------------------------------
BIG_PLAN="$TMPDIR_BASE/big-plan.md"
{
  echo "# Oversized Plan"
  seq 1 5099 | sed 's/^/- line /'
} > "$BIG_PLAN"
BIG_PLAN_LINES=$(wc -l < "$BIG_PLAN")
if [[ "$BIG_PLAN_LINES" -ne 5100 ]]; then
  fail "setup: expected 5100-line plan, got $BIG_PLAN_LINES"
fi

# Mock codex bin dir: echoes a minimal valid APPROVED verdict, exits 0.
MOCK_BIN="$TMPDIR_BASE/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "APPROVED"
echo "plan looks fine"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

# ---------------------------------------------------------------------------
# Case A: direct bin/review-plan-codex invocation
# ---------------------------------------------------------------------------
STDOUT_A="$TMPDIR_BASE/case-a-stdout.txt"
STDERR_A="$TMPDIR_BASE/case-a-stderr.txt"

A_EXIT=0
PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$TIMEOUT_SH" 120 bash "$REVIEWER" \
    --input "$BIG_PLAN" --format detail-plan --no-log \
    > "$STDOUT_A" 2> "$STDERR_A" || A_EXIT=$?

if [[ $A_EXIT -ne 0 ]]; then
  fail "Case A: expected exit 0, got $A_EXIT. stderr: $(cat "$STDERR_A" 2>/dev/null)"
else
  pass "Case A: exits 0"
fi

if grep -q "Warning: plan is" "$STDOUT_A"; then
  fail "Case A: truncation warning leaked onto stdout (regression #1734). stdout: $(cat "$STDOUT_A")"
else
  pass "Case A: stdout does NOT contain 'Warning: plan is'"
fi

if grep -qF "Warning: plan is 5100 lines, truncating to 5000 for codex." "$STDERR_A"; then
  pass "Case A: stderr contains the expected truncation warning"
else
  fail "Case A: stderr missing expected truncation warning. stderr: $(cat "$STDERR_A" 2>/dev/null)"
fi

FIRST_STDOUT_LINE_A=$(awk 'NF{print; exit}' "$STDOUT_A" | tr -d '\r')
if [[ "$FIRST_STDOUT_LINE_A" == "## Codex Plan Review: PERFORMED" ]]; then
  pass "Case A: first non-blank stdout line is the PERFORMED status header"
else
  fail "Case A: first non-blank stdout line is NOT the status header. Got: '$FIRST_STDOUT_LINE_A'"
fi

# ---------------------------------------------------------------------------
# Case B: full pipeline via bin/run-codex-review-loop
# ---------------------------------------------------------------------------
B_CFG="$TMPDIR_BASE/agents-config"
mkdir -p "$B_CFG/bin/lib" "$B_CFG/rules"

cp "$RUN_LOOP" "$B_CFG/bin/run-codex-review-loop"
chmod +x "$B_CFG/bin/run-codex-review-loop"
cp "$REVIEWER" "$B_CFG/bin/review-plan-codex"
chmod +x "$B_CFG/bin/review-plan-codex"
cp "$CODEX_CORE" "$B_CFG/bin/lib/codex-core.sh"
cp "$VERDICT_BIN" "$B_CFG/bin/review-loop-verdict"
chmod +x "$B_CFG/bin/review-loop-verdict"

# Stub build-codex-context: just touches --output (mirrors sibling suite pattern)
cat > "$B_CFG/bin/build-codex-context" << 'STUB_EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) touch "$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 0
STUB_EOF
chmod +x "$B_CFG/bin/build-codex-context"

echo "# core principles stub" > "$B_CFG/rules/core-principles.md"

B_PLANS="$TMPDIR_BASE/plans-dir"
mkdir -p "$B_PLANS"
B_TRADEOFFS="$TMPDIR_BASE/accepted-tradeoffs.txt"
: > "$B_TRADEOFFS"

B_SID="feature-1734-sid"
B_OUT="$TMPDIR_BASE/case-b-combined.txt"

B_EXIT=0
AGENTS_CONFIG_DIR="$B_CFG" PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$TIMEOUT_SH" 120 bash "$B_CFG/bin/run-codex-review-loop" \
    --format detail-plan --session-id "$B_SID" --plans-dir "$B_PLANS" \
    --draft-file "$BIG_PLAN" --cap 2 --max-extensions 2 \
    --accepted-tradeoffs "$B_TRADEOFFS" --round 1 \
    > "$B_OUT" 2>&1 || B_EXIT=$?

if [[ $B_EXIT -eq 0 ]]; then
  pass "Case B: wrapper exits 0 (APPROVED path), not 4 (HALT)"
else
  fail "Case B: expected exit 0, got $B_EXIT. Combined output: $(cat "$B_OUT" 2>/dev/null)"
fi

if grep -q "unrecognized status header" "$B_OUT"; then
  fail "Case B: 'unrecognized status header' die() message present (regression #1734). Output: $(cat "$B_OUT" 2>/dev/null)"
else
  pass "Case B: no 'unrecognized status header' message"
fi

# ---------------------------------------------------------------------------
# Case C: exact-boundary edge cases — 5000 lines (cap, no truncation) vs
# 5001 lines (one over the cap, truncation triggers). bin/review-plan-codex
# uses `if (( INPUT_LINES > MAX_PLAN_LINES ))` with MAX_PLAN_LINES=5000, so
# 5000 is the last non-truncating size and 5001 is the first truncating one.
# ---------------------------------------------------------------------------
C_PLAN_AT_CAP="$TMPDIR_BASE/plan-5000.md"
{
  echo "# At-Cap Plan"
  seq 1 4999 | sed 's/^/- line /'
} > "$C_PLAN_AT_CAP"
C_PLAN_AT_CAP_LINES=$(wc -l < "$C_PLAN_AT_CAP")
if [[ "$C_PLAN_AT_CAP_LINES" -ne 5000 ]]; then
  fail "setup: expected 5000-line at-cap plan, got $C_PLAN_AT_CAP_LINES"
fi

C_PLAN_OVER_CAP="$TMPDIR_BASE/plan-5001.md"
{
  echo "# Over-Cap Plan"
  seq 1 5000 | sed 's/^/- line /'
} > "$C_PLAN_OVER_CAP"
C_PLAN_OVER_CAP_LINES=$(wc -l < "$C_PLAN_OVER_CAP")
if [[ "$C_PLAN_OVER_CAP_LINES" -ne 5001 ]]; then
  fail "setup: expected 5001-line over-cap plan, got $C_PLAN_OVER_CAP_LINES"
fi

# --- Case C1: exactly 5000 lines (at the cap) — no truncation, no warning ---
STDOUT_C1="$TMPDIR_BASE/case-c1-stdout.txt"
STDERR_C1="$TMPDIR_BASE/case-c1-stderr.txt"

C1_EXIT=0
PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$TIMEOUT_SH" 120 bash "$REVIEWER" \
    --input "$C_PLAN_AT_CAP" --format detail-plan --no-log \
    > "$STDOUT_C1" 2> "$STDERR_C1" || C1_EXIT=$?

if [[ $C1_EXIT -ne 0 ]]; then
  fail "Case C1 (5000 lines): expected exit 0, got $C1_EXIT. stderr: $(cat "$STDERR_C1" 2>/dev/null)"
else
  pass "Case C1 (5000 lines): exits 0"
fi

if grep -q "Warning: plan is" "$STDOUT_C1"; then
  fail "Case C1 (5000 lines): truncation warning leaked onto stdout at the exact cap. stdout: $(cat "$STDOUT_C1")"
else
  pass "Case C1 (5000 lines): stdout does NOT contain 'Warning: plan is'"
fi

if grep -q "Warning: plan is" "$STDERR_C1"; then
  fail "Case C1 (5000 lines): unexpected truncation warning on stderr at the exact cap (no truncation should occur). stderr: $(cat "$STDERR_C1")"
else
  pass "Case C1 (5000 lines): stderr does NOT contain 'Warning: plan is' (no truncation at the cap)"
fi

FIRST_STDOUT_LINE_C1=$(awk 'NF{print; exit}' "$STDOUT_C1" | tr -d '\r')
if [[ "$FIRST_STDOUT_LINE_C1" == "## Codex Plan Review: PERFORMED" ]]; then
  pass "Case C1 (5000 lines): first non-blank stdout line is the PERFORMED status header"
else
  fail "Case C1 (5000 lines): first non-blank stdout line is NOT the status header. Got: '$FIRST_STDOUT_LINE_C1'"
fi

# --- Case C2: exactly 5001 lines (one over the cap) — truncation, warning ---
STDOUT_C2="$TMPDIR_BASE/case-c2-stdout.txt"
STDERR_C2="$TMPDIR_BASE/case-c2-stderr.txt"

C2_EXIT=0
PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
  bash "$TIMEOUT_SH" 120 bash "$REVIEWER" \
    --input "$C_PLAN_OVER_CAP" --format detail-plan --no-log \
    > "$STDOUT_C2" 2> "$STDERR_C2" || C2_EXIT=$?

if [[ $C2_EXIT -ne 0 ]]; then
  fail "Case C2 (5001 lines): expected exit 0, got $C2_EXIT. stderr: $(cat "$STDERR_C2" 2>/dev/null)"
else
  pass "Case C2 (5001 lines): exits 0"
fi

if grep -q "Warning: plan is" "$STDOUT_C2"; then
  fail "Case C2 (5001 lines): truncation warning leaked onto stdout (regression #1734). stdout: $(cat "$STDOUT_C2")"
else
  pass "Case C2 (5001 lines): stdout does NOT contain 'Warning: plan is'"
fi

if grep -qF "Warning: plan is 5001 lines, truncating to 5000 for codex." "$STDERR_C2"; then
  pass "Case C2 (5001 lines): stderr contains the expected truncation warning"
else
  fail "Case C2 (5001 lines): stderr missing expected truncation warning. stderr: $(cat "$STDERR_C2" 2>/dev/null)"
fi

FIRST_STDOUT_LINE_C2=$(awk 'NF{print; exit}' "$STDOUT_C2" | tr -d '\r')
if [[ "$FIRST_STDOUT_LINE_C2" == "## Codex Plan Review: PERFORMED" ]]; then
  pass "Case C2 (5001 lines): first non-blank stdout line is the PERFORMED status header"
else
  fail "Case C2 (5001 lines): first non-blank stdout line is NOT the status header. Got: '$FIRST_STDOUT_LINE_C2'"
fi

# ---------------------------------------------------------------------------
# Test design self-check (skills/_shared/test-design.md categories):
#   - normal: Case A (direct) + Case B (pipeline) — both covered above.
#   - error: N/A — this is a single-bug regression test targeting one code
#     path (stdout/stderr channel of the truncation warning); the existing
#     sibling suites (feature-review-plan-codex.sh, feature-603-run-codex-
#     review-loop.sh) already cover argument/error-path validation for both
#     scripts and are not duplicated here.
#   - edge: Case C covers the exact off-by-one boundary — 5000 lines (at
#     the cap: no truncation, no warning on either stream) paired with 5001
#     lines (one over the cap: truncation triggers, warning on stderr only).
#     Case A's 5100-line case covers the well-over-cap case additionally.
#   - idempotency: N/A — the fixed behavior (stderr routing) is stateless
#     per invocation; no idempotency-relevant state is introduced by this fix.
#   - security: N/A — no new input-handling or trust-boundary surface;
#     the fix only changes the output stream (stdout vs stderr) of an
#     existing message.
#   - classifier: N/A — no allowlist/regex/parser table is introduced.
#   - config-dependent: N/A — no environment- or config-driven branch.
# ---------------------------------------------------------------------------

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
