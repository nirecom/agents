#!/bin/bash
# Shared helpers for feature-1463-session-close-scriptify tests.
# Sourced by render-tests.sh / detect-sc7-tests.sh / structural-tests.sh — not a standalone runner.
# Tests: tests/bin/feature-1463-session-close-scriptify.sh
# Tags: scope:issue-specific, feature-2434, control-dir

set -u

_HELPERS_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}
SCRIPT_CHECKOUT_ROOT_NODE="$(node_path "$_HELPERS_SCRIPT_CHECKOUT_ROOT")"

RENDER_JS="${_HELPERS_SCRIPT_CHECKOUT_ROOT}/bin/render-final-report.js"
DETECT_JS="${_HELPERS_SCRIPT_CHECKOUT_ROOT}/bin/session-close-detect-wf-meta.js"
SC7_JS="${_HELPERS_SCRIPT_CHECKOUT_ROOT}/bin/session-close-render-sc7.js"
SKILL_MD="${_HELPERS_SCRIPT_CHECKOUT_ROOT}/skills/session-close/SKILL.md"
GUARD_JS="${_HELPERS_SCRIPT_CHECKOUT_ROOT}/hooks/stop-final-report-guard.js"

PASS=0
FAIL=0
SKIP=0
unset AGENTS_MAIN_ROOT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

# ---- fixtures ---------------------------------------------------------------
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f1463-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# #2434: control files live at $WORKFLOW_STATE_DIR/<sid>.control/<name>; the
# intent stays in PLANS as <sid>-intent.md. Pin every root the CLIs resolve.
WF_DIR="$(node_path "${TMPDIR_BASE}/wf")"
PLANS_DIR="$(node_path "${TMPDIR_BASE}/plans")"
mkdir -p "$WF_DIR" "$PLANS_DIR" "${TMPDIR_BASE}/home" "${TMPDIR_BASE}/tx"
export HOME="${TMPDIR_BASE}/home"
export WORKFLOW_STATE_DIR="$WF_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"
export CLAUDE_TRANSCRIPT_BASE_DIR="${TMPDIR_BASE}/tx"
unset CLAUDE_CODE_SESSION_ID

# ctl_path <sid> <name>: the derived control path for a session.
ctl_path() { printf '%s' "${WF_DIR}/$1.control/$2"; }

SID="f1463-session"
mkdir -p "${WF_DIR}/${SID}.control"
ENV_JSON="$(ctl_path "$SID" final-report-env.json)"
OUTCOME_JSON="$(ctl_path "$SID" issue-close-outcome.json)"
INTENT_MD="${PLANS_DIR}/${SID}-intent.md"

# Known sentinel values used for substitution assertions (T6).
FIXTURE_PR_TITLE="Fixture PR Title 1463"
FIXTURE_BRANCH="feature/fixture-1463"

# env JSON mirrors the shape written by bin/session-close-build-env.js.
cat > "$ENV_JSON" <<EOF
{
  "PR_NUMBER": "999",
  "PR_TITLE": "${FIXTURE_PR_TITLE}",
  "PR_URL": "https://example.com/pr/999",
  "PR_STATE": "MERGED",
  "BRANCH": "${FIXTURE_BRANCH}",
  "WORKTREE_PATH": "",
  "CREATED_DATE": "",
  "BACKUP_MANIFEST_PATH": "",
  "NOTES_BACKUP_PATH": "",
  "BRANCH_DELETED": "",
  "CLAUDE_CODE_RESTART_REQUIRED": "",
  "CC_RESTART_REQUIRED": "",
  "CC_RESTART_REASON": "",
  "VSCODE_RELOAD_REQUIRED": "",
  "VSCODE_RELOAD_REASON": "",
  "INSTALLER_RERUN_REQUIRED": "",
  "INSTALLER_RERUN_REASON": "",
  "OS_REBOOT_REQUIRED": "",
  "OS_REBOOT_REASON": ""
}
EOF

printf '{"issues":[]}\n' > "$OUTCOME_JSON"

cat > "$INTENT_MD" <<'EOF'
# Intent

## Issues
- #1463: scriptify session-close SKILL.md

## Scope
Test fixture intent.
EOF

ENV_JSON_NODE="$(node_path "$ENV_JSON")"
OUTCOME_JSON_NODE="$(node_path "$OUTCOME_JSON")"
INTENT_MD_NODE="$(node_path "$INTENT_MD")"

# seed_sid_fixture <sid>: copy the base env/outcome/intent to <sid>'s own
# derived control paths so a case can mutate one file without touching $SID.
seed_sid_fixture() {
    mkdir -p "${WF_DIR}/$1.control"
    cp "$ENV_JSON" "$(ctl_path "$1" final-report-env.json)"
    cp "$OUTCOME_JSON" "$(ctl_path "$1" issue-close-outcome.json)"
    cp "$INTENT_MD" "${PLANS_DIR}/$1-intent.md"
}

# Legacy positional form (#2434 shim): each path defaults to the derived path
# of the session in $1; the optional 5th arg is omitted when empty.
render_report() {
    local sid="$1"
    local -a args=(
        "$sid"
        "${FRE_ENV_JSON:-$(ctl_path "$sid" final-report-env.json)}"
        "${FRE_OUTCOME_JSON:-$(ctl_path "$sid" issue-close-outcome.json)}"
        "${FRE_INTENT_MD:-${PLANS_DIR}/${sid}-intent.md}"
    )
    [ -n "${FRE_SUPERVISOR_STATE:-}" ] && args+=("$FRE_SUPERVISOR_STATE")
    run_with_timeout 120 node "$RENDER_JS" "${args[@]}"
}
