#!/usr/bin/env bash
# Tests: hooks/lib/assemble-cmd-parse.js, hooks/show-plan-link.js, hooks/show-plan-link.js., skills/_shared/assemble-mandatory.sh
# Tags: plan, vscode, hook, workflow, plans
# Tests for isFinalPlanArtifact detection and systemMessage output in hooks/show-plan-link.js.
#
# Uses WORKFLOW_PLANS_DIR to control the resolved plans directory so tests work
# regardless of the actual home directory path.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/show-plan-link.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (rules/test-rules/macos-timeout.md)
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# Per-run temp dir as plans dir (no pollution of real ~/.workflow-plans).
# Use node os.tmpdir() so the path is in the same form Node.js sees it —
# on Windows, MSYS2 converts /tmp/... env vars to C:/Users/.../Temp/... but
# the JSON stdin value stays POSIX-form; using Node's tmpdir avoids the mismatch.
NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
PLANS_DIR="${NODE_TMPDIR}/show-plan-link-test-$$"
mkdir -p "$PLANS_DIR"
trap 'rm -rf "$PLANS_DIR"' EXIT
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

# Unset VS Code detection vars by default (restored per-test that needs them).
unset TERM_PROGRAM 2>/dev/null || true
unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true

run_hook() {
  local json="$1"
  echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

# Asserts stdout is empty (noop)
expect_empty() {
  local desc="$1" json="$2"
  local result
  result=$(run_hook "$json")
  if [ -z "$result" ]; then
    pass "$desc"
  else
    fail "$desc — expected empty stdout, got: $result"
  fi
}

# Asserts stdout is valid JSON with .systemMessage containing the expected substring
expect_message() {
  local desc="$1" json="$2" expected="$3"
  local result
  result=$(run_hook "$json")
  if [ -z "$result" ]; then
    fail "$desc — expected systemMessage, got empty stdout"
    return
  fi
  # Validate JSON and extract .systemMessage
  local msg
  msg=$(echo "$result" | run_with_timeout node -e "
    let data; try { data = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    if (!data.systemMessage) process.exit(2);
    process.stdout.write(data.systemMessage);
  " 2>/dev/null)
  local rc=$?
  if [ $rc -eq 1 ]; then
    fail "$desc — stdout is not valid JSON: $result"
  elif [ $rc -eq 2 ]; then
    fail "$desc — JSON has no .systemMessage field: $result"
  elif echo "$msg" | grep -qF "$expected"; then
    pass "$desc"
  else
    fail "$desc — .systemMessage does not contain '$expected': $msg"
  fi
}

# Helper: run hook with CONFIRM_* env vars and assert systemMessage is emitted
# $1 = description, $2 = file_path (under PLANS_DIR), $3 = expected substring,
# $4... = KEY=VAL env assignments
expect_message_with_env() {
  local desc="$1" file_path="$2" expected="$3"
  shift 3
  local result
  result=$(
    for assignment in "$@"; do
      key="${assignment%%=*}"
      val="${assignment#*=}"
      export "$key=$val"
    done
    echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$file_path\"},\"tool_response\":{\"success\":true}}" \
      | run_with_timeout node "$HOOK" 2>/dev/null
  )
  if [ -z "$result" ]; then
    fail "$desc — expected systemMessage, got empty stdout"
    return
  fi
  local msg
  msg=$(echo "$result" | run_with_timeout node -e "
    let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    process.stdout.write(d.systemMessage || '');
  " 2>/dev/null)
  if echo "$msg" | grep -qF "$expected"; then
    pass "$desc"
  else
    fail "$desc — .systemMessage does not contain '$expected': $msg"
  fi
}

# ── Source test groups ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=feature-show-plan-link/write-tool.sh
. "$SCRIPT_DIR/feature-show-plan-link/write-tool.sh"
# shellcheck source=feature-show-plan-link/bash-tool.sh
. "$SCRIPT_DIR/feature-show-plan-link/bash-tool.sh"
# shellcheck source=feature-show-plan-link/vscode-lib.sh
. "$SCRIPT_DIR/feature-show-plan-link/vscode-lib.sh"

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi
