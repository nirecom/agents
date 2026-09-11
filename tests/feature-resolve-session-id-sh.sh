#!/bin/bash
# Tests: bin/resolve-session-id, hooks/workflow-state/session-id.js, bin/lib/codex-core.sh, bin/lib/gemini-core.sh, bin/github-issues/wip-state/session-id.sh, bin/workflow/workflow-init-driver, bin/issue-close-write-outcome.js
# Tags: scope:common, pwsh-not-required, session-id, bridge
# Tests bin/resolve-session-id (bash bridge) and all callers — Issue #1251.
# Contract (SSOT: docs/architecture/claude-code/session-id-resolution.md): stdout =
#   session id; rc=0 success, rc=2 + stderr unresolvable, rc=3 + stderr resolver threw.
# L3 gap: no live ~/.claude/projects JSONL, no CLAUDE_ENV_FILE from the real
#   session-start.js (nor an unreadable one — MSYS ACLs), no native-Windows node path
#   round-trip, no live gh for wip-set-resume.sh, no AGENTS_CONFIG_DIR-unset
#   catch-fallback in issue-close-write-outcome.js. Closest-to-action mitigation:
#   skill-orchestration gate at WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$AGENTS_DIR/bin/resolve-session-id"
CODEX_CORE="$AGENTS_DIR/bin/lib/codex-core.sh"
GEMINI_CORE="$AGENTS_DIR/bin/lib/gemini-core.sh"
WIP_SID_HELPER="$AGENTS_DIR/bin/github-issues/wip-state/session-id.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# mk_jsonl <dir> <sid>  — create a .jsonl fixture with a known mtime.
mk_jsonl() {
    local dir="$1" sid="$2"
    mkdir -p "$dir"
    echo "{}" > "$dir/$sid.jsonl"
    touch -t 202601010000 "$dir/$sid.jsonl"
}

# Early-exit: bridge is missing → all tests are RED; fail cleanly.
if [ ! -f "$BRIDGE" ]; then
    echo "FAIL: bin/resolve-session-id not found (implementation missing — suite is RED)"
    echo ""
    echo "Results: 0 passed, 1+ failed"
    exit 1
fi

TMP=""

setup() {
    TMP="$(mktemp -d)"
    export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts"
    mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
    unset CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID 2>/dev/null || true
}

teardown() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset CLAUDE_TRANSCRIPT_BASE_DIR CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID 2>/dev/null || true
}

# enc <path> — encode a path exactly as the JS resolver's P7 does.
enc() {
    node -p "path=require('path'); path.resolve(process.argv[1]).toLowerCase().replace(/[^a-zA-Z0-9]/g,'-')" "$1" 2>/dev/null
}

# run_bridge <cwd> [KEY=VALUE ...] — run the bridge from <cwd> with the given
# SID env vars exported (all other SID env unset; AGENTS_CONFIG_DIR + transcript
# base injected). Sets BRIDGE_OUT / BRIDGE_RC. Values must not contain "'".
run_bridge() {
    local cwd="$1"; shift
    local exports="" kv
    for kv in "$@"; do
        exports+="export ${kv%%=*}='${kv#*=}'; "
    done
    BRIDGE_OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$AGENTS_DIR'
        $exports
        cd '$cwd'
        bash '$BRIDGE'
    " 2>/dev/null)
    BRIDGE_RC=$?
}

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-resolve-session-id-sh"

# shellcheck source=./feature-resolve-session-id-sh/axis-a.sh
. "$SCRIPT_DIR/axis-a.sh"
# shellcheck source=./feature-resolve-session-id-sh/axis-b.sh
. "$SCRIPT_DIR/axis-b.sh"
# shellcheck source=./feature-resolve-session-id-sh/axis-c.sh
. "$SCRIPT_DIR/axis-c.sh"
# shellcheck source=./feature-resolve-session-id-sh/axis-d.sh
. "$SCRIPT_DIR/axis-d.sh"
# shellcheck source=./feature-resolve-session-id-sh/r7.sh
. "$SCRIPT_DIR/r7.sh"
# shellcheck source=./feature-resolve-session-id-sh/security.sh
. "$SCRIPT_DIR/security.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
