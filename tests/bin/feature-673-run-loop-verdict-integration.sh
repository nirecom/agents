#!/usr/bin/env bash
# Tests: bin/build-codex-context, bin/review-loop-verdict, bin/review-plan-codex, bin/run-codex-review-loop
# Tags: worktree, codex, review, bin, env, scope:issue-specific
# L2 integration tests for bin/run-codex-review-loop end-to-end behavior
# with concern-ID ledger + verdict resolution (issue #673).
set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER_SRC="$AGENTS_WORKTREE/bin/run-codex-review-loop"
AGENTS_DIR="${AGENTS_DIR:-$AGENTS_WORKTREE}"
. "$AGENTS_WORKTREE/tests/lib/harness.sh"
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

# #2434: control files (counter, ledger default, risk signal) live under
# $CLAUDE_WORKFLOW_DIR/<sid>.control/, so pin both state roots to a fixture.
STATE_ROOT=$(mktemp -d)
trap 'rm -rf "$STATE_ROOT"' EXIT
export CLAUDE_WORKFLOW_DIR="$STATE_ROOT/workflow-state"
export WORKFLOW_PLANS_DIR="$STATE_ROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

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
    if [[ -f "$AGENTS_WORKTREE/bin/lib/cli-exec-guard.sh" ]]; then
      cp "$AGENTS_WORKTREE/bin/lib/cli-exec-guard.sh" "$agents_dir/bin/lib/cli-exec-guard.sh"
    fi
    if [[ -f "$AGENTS_WORKTREE/bin/lib/codex-review-loop/ledger-verdict.sh" ]]; then
      cp "$AGENTS_WORKTREE/bin/lib/codex-review-loop/ledger-verdict.sh" \
         "$agents_dir/bin/lib/codex-review-loop/ledger-verdict.sh"
    fi
    cp "$AGENTS_WORKTREE"/bin/lib/codex-review-loop/*.sh "$agents_dir/bin/lib/codex-review-loop/"
    [[ -f "$AGENTS_WORKTREE/bin/lib/safe-state-path.sh" ]] && cp "$AGENTS_WORKTREE/bin/lib/safe-state-path.sh" "$agents_dir/bin/lib/safe-state-path.sh"
    cp "$AGENTS_WORKTREE/bin/concern-ledger" "$agents_dir/bin/concern-ledger"
    chmod +x "$agents_dir/bin/concern-ledger"
    cp "$AGENTS_WORKTREE/bin/lib/concern-ledger.sh" "$agents_dir/bin/lib/concern-ledger.sh"
    mkdir -p "$agents_dir/bin/lib/concern-ledger"
    cp "$AGENTS_WORKTREE"/bin/lib/concern-ledger/*.sh "$agents_dir/bin/lib/concern-ledger/"
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
echo "## Codex Review: PERFORMED"
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

SCRIPT_DIR="$(dirname "$0")/feature-673-run-loop-verdict-integration"

case_begin "safe-state-path-preflight" "bin/run-codex-review-loop"
# The shared loop sources bin/lib/safe-state-path.sh (#2434 rename of
# safe-plans-path.sh). Name its absence once instead of letting every case
# below cascade into an unexplained exit 4.
if [[ -f "$AGENTS_WORKTREE/bin/lib/safe-state-path.sh" ]]; then
  pass "preflight: bin/lib/safe-state-path.sh present"
else
  fail "implementation missing: bin/lib/safe-state-path.sh (the cases below exit 4 until it exists)"
fi
case_end

# shellcheck source=./feature-673-run-loop-verdict-integration/verdict-cases.sh
. "$SCRIPT_DIR/verdict-cases.sh"
# shellcheck source=./feature-673-run-loop-verdict-integration/loop-cases.sh
. "$SCRIPT_DIR/loop-cases.sh"

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
