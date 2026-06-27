#!/usr/bin/env bash
# tests/feature-299-session-titles.sh
# Tests: hooks/lib/session-title.js, bin/cc-session-title, hooks/session-start.js
# Tags: scope:issue-specific
#
# L3 gap (what this test does NOT catch):
#   - VS Code extension JSONL polling and actual tab title display in a live VS Code window
#   - The custom-title record being read and applied by the vscode-claude extension
#   - CLAUDE_CODE_CHILD_SESSION propagation into real Claude Code subagent environments
#   - Hook registration: session-start.js wiring is exercised here by direct invocation of the
#     real hook via piped stdin, not via a real SessionStart hook event from a live claude -p session
#   - CLAUDE_SESSION_ID propagation bug #27987: resolved via CLAUDE_ENV_FILE path in tests;
#     the fallback mtime path is tested with synthetic JSONL fixtures, not a live session

set -euo pipefail

# Unset CLAUDE_CODE_CHILD_SESSION so the library's subagent guard does not fire
# when tests call node subprocesses. T11 re-sets it explicitly to test the guard.
unset CLAUDE_CODE_CHILD_SESSION 2>/dev/null || true

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Windows-compatible node path resolution (Git Bash: /c/... → C:/...)
to_node_path() {
  local p="$1"
  if [[ "$p" =~ ^/([a-zA-Z])/(.*) ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    echo "${drive^^}:/${rest}"
  else
    echo "$p"
  fi
}

_AGENTS_DIR_NODE="$(to_node_path "$AGENTS_DIR")"
SESSION_TITLE_LIB="$_AGENTS_DIR_NODE/hooks/lib/session-title.js"
BIN_CC_SESSION_TITLE="$_AGENTS_DIR_NODE/bin/cc-session-title"
SESSION_START_HOOK="$_AGENTS_DIR_NODE/hooks/session-start.js"

PASS=0; FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

# ---------------------------------------------------------------------------
# Temp directory setup — Windows-compatible
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
  _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
  _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
  _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
  TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctest299.XXXXXXXX")
else
  TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

encode_cwd_node() {
  local p="$1"
  node -e "
const path = require('path');
process.stdout.write(path.resolve('$p').toLowerCase().replace(/[^a-zA-Z0-9]/g, '-'));
" 2>/dev/null
}

make_transcript_dir() {
  local transcript_base_bash="$1"
  local cwd_node="$2"
  local encoded
  encoded=$(encode_cwd_node "$cwd_node")
  local dir="$transcript_base_bash/$encoded"
  mkdir -p "$dir"
  echo "$dir"
}

# ---------------------------------------------------------------------------
# JSONL read helpers
# ---------------------------------------------------------------------------

read_last_title() {
  local jsonl_file_node="$1" session_id="$2"
  node -e "
const fs = require('fs');
try {
  const lines = fs.readFileSync('$jsonl_file_node', 'utf8').split('\n').filter(l => l.trim());
  let last = '';
  for (const line of lines) {
    try {
      const r = JSON.parse(line);
      if (r.type === 'custom-title' && r.sessionId === '$session_id') last = r.customTitle;
    } catch(_) {}
  }
  process.stdout.write(last);
} catch(_) { process.stdout.write(''); }
" 2>/dev/null
}

count_title_records() {
  local jsonl_file_node="$1" session_id="$2"
  node -e "
const fs = require('fs');
try {
  const lines = fs.readFileSync('$jsonl_file_node', 'utf8').split('\n').filter(l => l.trim());
  let count = 0;
  for (const line of lines) {
    try {
      const r = JSON.parse(line);
      if (r.type === 'custom-title' && r.sessionId === '$session_id') count++;
    } catch(_) {}
  }
  process.stdout.write(String(count));
} catch(_) { process.stdout.write('0'); }
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Setup helpers
# ---------------------------------------------------------------------------

make_intent() {
  local plans_dir_bash="$1" session_id="$2" content="$3"
  mkdir -p "$plans_dir_bash"
  printf '%s' "$content" > "$plans_dir_bash/${session_id}-intent.md"
}

make_jsonl_with_title() {
  local jsonl_bash="$1" session_id="$2" title="$3"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")
  mkdir -p "$(dirname "$jsonl_bash")"
  node -e "
const fs = require('fs');
const record = JSON.stringify({type:'custom-title',sessionId:'$session_id',customTitle:'$title'}) + '\n';
fs.writeFileSync('$jsonl_node', record, 'utf8');
" 2>/dev/null
}

call_lib_fn() {
  local transcript_base_node="$1"
  local fn_call_js="$2"
  (
    unset CLAUDE_CODE_CHILD_SESSION
    CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_base_node"
    export CLAUDE_TRANSCRIPT_BASE_DIR
    run_with_timeout 10 node -e "
const m = require('$SESSION_TITLE_LIB');
$fn_call_js
" 2>/dev/null || true
  )
}

# ---------------------------------------------------------------------------
# Sub-file dispatch (sourced — shares functions and PASS/FAIL counters)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-299-session-titles"

# shellcheck source=./feature-299-session-titles/core-functions.sh
. "$SCRIPT_DIR/core-functions.sh"
# shellcheck source=./feature-299-session-titles/cli-and-resolution.sh
. "$SCRIPT_DIR/cli-and-resolution.sh"
# shellcheck source=./feature-299-session-titles/integration.sh
. "$SCRIPT_DIR/integration.sh"
# shellcheck source=./feature-299-session-titles/null-title-sentinel.sh
. "$SCRIPT_DIR/null-title-sentinel.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
