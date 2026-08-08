#!/bin/bash
# Shared helpers for feature-405-final-report tests.
# Sourced by p-series.sh / s-series.sh / k-series.sh / i-series.sh — not a standalone runner.
# Tests: hooks/lib/final-report-schema.js
# Tags: helper, final-report, scope:common

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PARSE_JS="${_AGENTS_DIR_NODE}/hooks/lib/parse-closes-issues.js"
NOTES_JS="${_AGENTS_DIR_NODE}/hooks/lib/worktree-notes.js"
SCHEMA_JS="${_AGENTS_DIR_NODE}/hooks/lib/final-report-schema.js"
SKILL_MD="${AGENTS_DIR}/skills/worktree-end/SKILL.md"
SESSION_CLOSE_SKILL_MD="${AGENTS_DIR}/skills/session-close/SKILL.md"

PASS=0
FAIL=0
SKIP=0
# Guard: ensure AGENTS_CONFIG_DIR does not bleed into pre-agents-gate tests
unset AGENTS_CONFIG_DIR

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f405-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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

node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

require_parser() {
    if [ ! -f "$PARSE_JS" ]; then
        skip "$1 (hooks/lib/parse-closes-issues.js not implemented yet)"
        return 1
    fi
    return 0
}

require_notes_lib() {
    if [ ! -f "$NOTES_JS" ]; then
        skip "$1 (hooks/lib/worktree-notes.js missing)"
        return 1
    fi
    return 0
}

require_schema() {
    if [ ! -f "$SCHEMA_JS" ]; then
        skip "$1 (hooks/lib/final-report-schema.js not implemented yet)"
        return 1
    fi
    return 0
}

require_skill_md() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "$1 (skills/worktree-end/SKILL.md missing)"
        return 1
    fi
    return 0
}

require_session_close_skill() {
    if [ ! -f "$SESSION_CLOSE_SKILL_MD" ]; then
        skip "$1 (skills/session-close/SKILL.md missing)"
        return 1
    fi
    return 0
}
