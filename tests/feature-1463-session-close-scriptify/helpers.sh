#!/bin/bash
# Shared helpers for feature-1463-session-close-scriptify tests.
# Sourced by render-tests.sh / detect-sc7-tests.sh / structural-tests.sh — not a standalone runner.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}
AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

RENDER_JS="${AGENTS_DIR}/bin/render-final-report.js"
DETECT_JS="${AGENTS_DIR}/bin/session-close-detect-wf-meta.js"
SC7_JS="${AGENTS_DIR}/bin/session-close-render-sc7.js"
SKILL_MD="${AGENTS_DIR}/skills/session-close/SKILL.md"
GUARD_JS="${AGENTS_DIR}/hooks/stop-final-report-guard.js"

PASS=0
FAIL=0
SKIP=0
unset AGENTS_CONFIG_DIR

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

SID="f1463-session"
ENV_JSON="${TMPDIR_BASE}/${SID}-final-report-env.json"
OUTCOME_JSON="${TMPDIR_BASE}/${SID}-issue-close-outcome.json"
INTENT_MD="${TMPDIR_BASE}/${SID}-intent.md"

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

# render-final-report.js CLI contract is not yet frozen; drive it via the two
# argument styles the SKILL.md notes describe (positional paths + env vars).
# The test passes both so it survives either final signature.
render_report() {
    # $1 = session-id ; env overrides applied by caller
    run_with_timeout 120 env \
        FINAL_REPORT_ENV_JSON="${FRE_ENV_JSON:-$ENV_JSON_NODE}" \
        OUTCOME_JSON="${FRE_OUTCOME_JSON:-$OUTCOME_JSON_NODE}" \
        INTENT_MD="${FRE_INTENT_MD:-$INTENT_MD_NODE}" \
        SUPERVISOR_STATE_JSON="${FRE_SUPERVISOR_STATE:-}" \
        node "$RENDER_JS" \
        "$1" \
        "${FRE_ENV_JSON:-$ENV_JSON_NODE}" \
        "${FRE_OUTCOME_JSON:-$OUTCOME_JSON_NODE}" \
        "${FRE_INTENT_MD:-$INTENT_MD_NODE}" \
        "${FRE_SUPERVISOR_STATE:-}"
}
