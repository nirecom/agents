#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, bin/review-plan-codex, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh, agents/plan-security-reviewer.md, agents/test-reviewer.md, skills/review-plan-security/SKILL.md, skills/review-tests/SKILL.md
# Tags: codex, review, allowlist, scope:issue-specific
# Tests for issue #1308: add security-plan and test-review format tokens to Codex review loop.
#
# Expected failures BEFORE implementation (pre-impl):
#   Cases 1-6:  new formats not yet in run-codex-review-loop allowlist/verdict table
#   Cases 10-11: review-plan-codex does not accept security-plan / test-review yet
#   Cases 13-16: source code does not yet contain security-plan / test-review tokens
#   Cases 17-20: CAP/MAX_EXTENSIONS defaults not yet set for new formats
#   Cases 21-22: wrapper scripts not yet created
#   Cases 23-25: wrapper scripts not yet created (cannot check --format / --context)
#   Cases 26-27: agent files not yet created
#
# Expected to PASS even before implementation:
#   Cases 7-9:   regression — existing formats (detail-plan, outline-plan) still work
#   Case 12:     regression — bad-format still rejected by review-plan-codex
#
# Total expected pre-impl failures: ~19 of 32 cases.
#
# L3 gap: these are L2 subprocess tests using mock Codex binaries.
#          A true L3 test would invoke a real `codex` CLI session; that requires a
#          live Codex environment and is out of scope for per-PR CI (#1308 scoped to L2).

set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
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
# Per-test setup: creates a mock AGENTS_CONFIG_DIR with required binaries
# ---------------------------------------------------------------------------
setup_mock_env() {
  local test_tmp="$1"
  local agents_dir="$test_tmp/agents"
  mkdir -p "$agents_dir/bin" "$agents_dir/rules"
  echo "# core principles stub" > "$agents_dir/rules/core-principles.md"

  # Mock build-codex-context: parses --output, touches the file, exits 0
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

  # Copy the wrapper under test into AGENTS_CONFIG_DIR/bin
  if [[ -f "$AGENTS_WORKTREE/bin/run-codex-review-loop" ]]; then
    cp "$AGENTS_WORKTREE/bin/run-codex-review-loop" "$agents_dir/bin/run-codex-review-loop"
    chmod +x "$agents_dir/bin/run-codex-review-loop"
  fi

  # Copy review-loop-verdict (verdict-decision helper invoked by the wrapper)
  if [[ -f "$AGENTS_WORKTREE/bin/review-loop-verdict" ]]; then
    cp "$AGENTS_WORKTREE/bin/review-loop-verdict" "$agents_dir/bin/review-loop-verdict"
    chmod +x "$agents_dir/bin/review-loop-verdict"
  fi

  # Copy codex-core.sh (sourced by review-plan-codex mock and run-codex-review-loop)
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

make_review_plan_codex_mock() {
  local agents_dir="$1"
  local output_content="$2"
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
HEADER_EOF
  cat >> "$agents_dir/bin/review-plan-codex" << EOF
cat << 'MOCK_OUTPUT'
${output_content}
MOCK_OUTPUT
EOF
  chmod +x "$agents_dir/bin/review-plan-codex"
}

invoke_wrapper() {
  local agents_dir="$1"
  shift
  AGENTS_CONFIG_DIR="$agents_dir" run_with_timeout "$agents_dir/bin/run-codex-review-loop" "$@"
}

# Helper: one FORMAT/verdict/exit-code case for Group A table-driven tests.
run_format_case() {
  local name="$1"
  local format="$2"
  local verdict_body="$3"
  local want="$4"

  local tmp mock plans body
  tmp=$(mktemp -d)
  mock=$(setup_mock_env "$tmp")
  plans=$(setup_plans_dir "$tmp")

  # Expand literal '\n' in the verdict body to real newlines.
  body=$(printf '%b' "$verdict_body")

  make_review_plan_codex_mock "$mock" "## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
${body}
<!-- end-codex-output -->"

  AGENTS_CONFIG_DIR="$mock" run_with_timeout "$mock/bin/run-codex-review-loop" \
    --format "$format" --session-id "sid-${name}" --plans-dir "$plans" \
    --draft-file "$plans/draft.md" --cap 1 --max-extensions 0 --extensions-used 0 \
    --accepted-tradeoffs "$plans/outline.md" --round 1 > /dev/null 2>&1
  local rc=$?

  if [[ $rc -eq $want ]]; then
    pass "${name}: format=${format} → exit ${want}"
  else
    fail "${name}: format=${format} → expected exit ${want}, got ${rc}"
  fi

  rm -rf "$tmp"
}

# Group B helper: invoke the REAL review-plan-codex with a given format
REAL_REVIEW_PLAN_CODEX="$AGENTS_WORKTREE/bin/review-plan-codex"

invoke_real_review_plan_codex() {
  local fmt="$1"
  local sid="$2"
  local plans_dir="$3"
  local draft_file="$4"
  local tmp_wrapper
  tmp_wrapper=$(mktemp -d)
  local mock_dir="$tmp_wrapper/mock"
  mkdir -p "$mock_dir/bin/lib"
  cp "$REAL_REVIEW_PLAN_CODEX" "$mock_dir/bin/review-plan-codex"
  chmod +x "$mock_dir/bin/review-plan-codex"
  if [[ -f "$AGENTS_WORKTREE/bin/lib/codex-core.sh" ]]; then
    cp "$AGENTS_WORKTREE/bin/lib/codex-core.sh" "$mock_dir/bin/lib/codex-core.sh"
  fi
  AGENTS_CONFIG_DIR="$mock_dir" run_with_timeout "$mock_dir/bin/review-plan-codex" \
    --format "$fmt" \
    --session-id "$sid" \
    --log-dir "$plans_dir" \
    --input "$draft_file" \
    --round 1 \
    --cap 1 \
    --max-extensions 0 \
    --extensions-used 0 \
    --accepted-tradeoffs "$draft_file" \
    2>&1 || true
  rm -rf "$tmp_wrapper"
}

# Group C / G shared source paths
LOOP_SRC="$AGENTS_WORKTREE/bin/run-codex-review-loop"
CODEX_SRC="$AGENTS_WORKTREE/bin/review-plan-codex"

# Group D shared paths
RPS_WRAPPER="$AGENTS_WORKTREE/skills/review-plan-security/scripts/run-codex-review-loop.sh"
RT_WRAPPER="$AGENTS_WORKTREE/skills/review-tests/scripts/run-codex-review-loop.sh"

# Group E shared paths
PLAN_SEC_AGENT="$AGENTS_WORKTREE/agents/plan-security-reviewer.md"
TEST_REVIEWER_AGENT="$AGENTS_WORKTREE/agents/test-reviewer.md"

# ---------------------------------------------------------------------------
# Source each group sub-file
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$0")/feature-1308-codex-review-allowlist"

# shellcheck source=./feature-1308-codex-review-allowlist/group-a-allowlist.sh
. "$SCRIPT_DIR/group-a-allowlist.sh"
# shellcheck source=./feature-1308-codex-review-allowlist/group-b-format-validation.sh
. "$SCRIPT_DIR/group-b-format-validation.sh"
# shellcheck source=./feature-1308-codex-review-allowlist/group-c-static-defaults.sh
. "$SCRIPT_DIR/group-c-static-defaults.sh"
# shellcheck source=./feature-1308-codex-review-allowlist/group-d-wrappers.sh
. "$SCRIPT_DIR/group-d-wrappers.sh"
# shellcheck source=./feature-1308-codex-review-allowlist/group-e-agents.sh
. "$SCRIPT_DIR/group-e-agents.sh"
# shellcheck source=./feature-1308-codex-review-allowlist/group-f-injection.sh
. "$SCRIPT_DIR/group-f-injection.sh"
# shellcheck source=./feature-1308-codex-review-allowlist/group-g-prompt-bodies.sh
. "$SCRIPT_DIR/group-g-prompt-bodies.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
[[ $ERRORS -eq 0 ]] && echo "All tests passed" || { echo "$ERRORS test(s) failed"; exit 1; }
