#!/usr/bin/env bash
# Tests: bin/build-codex-context, bin/review-loop-verdict, bin/review-plan-codex, bin/run-codex-review-loop
# Tags: worktree, codex, review, bin, install, scope:issue-specific
# Tests for bin/run-codex-review-loop (issue #603): exit-code matrix,
# pre-flight checks, and argument forwarding.
# TL1 dispatcher: shared fixtures and helpers live here, the cases live in
# tests/feature-603-run-codex-review-loop/ per rules/coding/file-split.md.
set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
# The wrapper is installed in AGENTS_CONFIG_DIR/bin — mocked per-test
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
# Per-test setup helper: creates a mock AGENTS_CONFIG_DIR with binaries
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
  # (wrapper won't exist yet — that's intentional pre-implementation)
  if [[ -f "$AGENTS_WORKTREE/bin/run-codex-review-loop" ]]; then
    cp "$AGENTS_WORKTREE/bin/run-codex-review-loop" "$agents_dir/bin/run-codex-review-loop"
    chmod +x "$agents_dir/bin/run-codex-review-loop"
  fi

  # Copy concern-ledger: since #2025 C5 the wrapper resolves the ledger CLI only
  # under AGENTS_CONFIG_DIR or beside itself — the repo-under-review and
  # `git rev-parse --show-toplevel` are no longer candidates, so the mock must
  # carry its own copy.
  if [[ -f "$AGENTS_WORKTREE/bin/concern-ledger" ]]; then
    cp "$AGENTS_WORKTREE/bin/concern-ledger" "$agents_dir/bin/concern-ledger"
    chmod +x "$agents_dir/bin/concern-ledger"
  fi

  # Copy review-loop-verdict (verdict-decision helper invoked by the wrapper)
  if [[ -f "$AGENTS_WORKTREE/bin/review-loop-verdict" ]]; then
    cp "$AGENTS_WORKTREE/bin/review-loop-verdict" "$agents_dir/bin/review-loop-verdict"
    chmod +x "$agents_dir/bin/review-loop-verdict"
  fi

  # Copy bin/lib wholesale: codex-core.sh sources its siblings (codex-timeout.sh),
  # so copying it alone leaves the fixture emitting "No such file" noise on stderr.
  mkdir -p "$agents_dir/bin/lib"
  if [[ -d "$AGENTS_WORKTREE/bin/lib" ]]; then
    cp -r "$AGENTS_WORKTREE/bin/lib/." "$agents_dir/bin/lib/"
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

# ---------------------------------------------------------------------------
# Cases — sourced in the original block order so the output stays byte-identical.
# ---------------------------------------------------------------------------
SUITE_DIR="$AGENTS_WORKTREE/tests/feature-603-run-codex-review-loop"

# shellcheck source=./feature-603-run-codex-review-loop/verdict-exit-codes.sh
. "$SUITE_DIR/verdict-exit-codes.sh"
# shellcheck source=./feature-603-run-codex-review-loop/arg-validation-and-context-build.sh
. "$SUITE_DIR/arg-validation-and-context-build.sh"
# shellcheck source=./feature-603-run-codex-review-loop/preflight-and-flag-values.sh
. "$SUITE_DIR/preflight-and-flag-values.sh"
# shellcheck source=./feature-603-run-codex-review-loop/forwarding-and-repo-root.sh
. "$SUITE_DIR/forwarding-and-repo-root.sh"
# shellcheck source=./feature-603-run-codex-review-loop/cap-and-extension-branches.sh
. "$SUITE_DIR/cap-and-extension-branches.sh"
# shellcheck source=./feature-603-run-codex-review-loop/round-counter-ownership.sh
. "$SUITE_DIR/round-counter-ownership.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
[[ $ERRORS -eq 0 ]] && echo "All tests passed" || { echo "$ERRORS test(s) failed"; exit 1; }
