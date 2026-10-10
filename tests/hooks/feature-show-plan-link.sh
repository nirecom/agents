#!/usr/bin/env bash
# Tests: hooks/lib/assemble-cmd-parse.js, hooks/show-plan-link.js, skills/_shared/assemble-mandatory.sh
# Tags: plan, vscode, hook, workflow, plans, scope:issue-specific, plan-sync, breadcrumb, edit-write-tools, command-tools
# Tests for isFinalPlanArtifact detection and systemMessage output in hooks/show-plan-link.js.
#
# Uses WORKFLOW_PLANS_DIR to control the resolved plans directory so tests work
# regardless of the actual home directory path.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/show-plan-link.js"
ERRORS=0
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

SPL_NI=""
[ -f "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-sync.js" ] || SPL_NI=" [not implemented: #2513 breadcrumb, hooks/lib/plan-sync.js absent]"
fail() { echo "FAIL: $1$SPL_NI"; ERRORS=$((ERRORS + 1)); }
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
# isolation (#2512): pin state and plans dirs once for this file, rooted in Node's tmpdir form for the reason above.
_ISOLATION_TMP_ROOT="${NODE_TMPDIR}/show-plan-link-test-$$"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
PLANS_DIR="$WORKFLOW_PLANS_DIR"
WORKFLOW_DIR_TEST="$WORKFLOW_STATE_DIR"
CFG_DIR_TEST="$_ISOLATION_TMP_ROOT/cfg"
mkdir -p "$CFG_DIR_TEST"
# #2513: plan-sync off (empty export + empty agents main root .env), so every
# breadcrumb is the local path plus the "not configured" line.
export AGENTS_MAIN_ROOT="$CFG_DIR_TEST"
export PLAN_SYNC_REMOTE_URL=""
OFF_LINE="[plan-sync] not configured (PLAN_SYNC_REMOTE_URL empty)"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# Unset VS Code detection vars by default (restored per-test that needs them).
unset TERM_PROGRAM 2>/dev/null || true
unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
unset SHOW_PLAN_LINK_NO_AUTO_OPEN SHOW_PLAN_LINK_NO_SPAWN SHOW_PLAN_LINK_MARKER_FILE 2>/dev/null || true
# #2513 safety net: a `code` stub is first on PATH for the whole file, so no case
# (e.g. T21 sets CLAUDE_CODE_ENTRYPOINT) can ever launch the real editor.
# shellcheck source=../lib/code-stub.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/code-stub.sh"
setup_code_stub "$WORKFLOW_DIR_TEST/code-stub" || { echo "FAIL: code stub setup"; exit 1; }
code_stub_probe || { echo "FAIL: code stub is not first on PATH; refusing to run (real editor could launch)"; exit 1; }

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
  elif ! echo "$msg" | grep -qF "Plan file: "; then
    fail "$desc — .systemMessage lacks the 'Plan file: ' breadcrumb: $msg"
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
  if ! echo "$msg" | grep -qF "Plan file: "; then
    fail "$desc — .systemMessage lacks the 'Plan file: ' breadcrumb: $msg"
  elif echo "$msg" | grep -qF "$expected"; then
    pass "$desc"
  else
    fail "$desc — .systemMessage does not contain '$expected': $msg"
  fi
}

# ── Isolation (#2512): the turn marker lands under the pinned state dir ─────
# Runs before the groups: plan-sync-breadcrumb.sh re-pins both dirs via psf_setup
# and deletes them on cleanup, so only here does the file-level pin still hold.
ISO_SID="25120000-0000-4000-8000-000000002512"
echo "{\"session_id\":\"$ISO_SID\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/iso-detail.md\"},\"tool_response\":{\"success\":true}}" \
  | run_with_timeout node "$HOOK" >/dev/null 2>&1
if compgen -G "$WORKFLOW_STATE_DIR/$ISO_SID.confirm-plan-turn-*.json" >/dev/null; then
  pass "turn marker lands under \$WORKFLOW_STATE_DIR"
else
  fail "turn marker not found under \$WORKFLOW_STATE_DIR ($WORKFLOW_STATE_DIR)"
fi

# ── Source test groups ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=feature-show-plan-link/write-tool.sh
. "$SCRIPT_DIR/feature-show-plan-link/write-tool.sh"
# shellcheck source=feature-show-plan-link/bash-tool.sh
. "$SCRIPT_DIR/feature-show-plan-link/bash-tool.sh"
# shellcheck source=feature-show-plan-link/plan-sync-breadcrumb.sh
. "$SCRIPT_DIR/feature-show-plan-link/plan-sync-breadcrumb.sh"

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi
