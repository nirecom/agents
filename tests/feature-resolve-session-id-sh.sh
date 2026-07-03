#!/bin/bash
# Tests: bin/resolve-session-id, hooks/lib/workflow-state/session-id.js, bin/lib/codex-core.sh, bin/lib/gemini-core.sh, bin/github-issues/wip-state/session-id.sh, skills/workflow-init/scripts/aggregate-wip-check.sh, skills/workflow-init/scripts/wip-set-resume.sh, bin/issue-close-write-outcome.js
# Tags: scope:common, pwsh-not-required, session-id, bridge
# Tests for bin/resolve-session-id (bash bridge) and all callers — Issue #1251.
#
# Contract: bash "$AGENTS_CONFIG_DIR/bin/resolve-session-id" → stdout = session id,
#   rc=0 on success, rc=2 + stderr when unresolvable. Internally delegates to
#   hooks/lib/workflow-state.resolveSessionId() via node -e.
#
# L3 gap (what this test does NOT catch):
#   - Real ~/.claude/projects JSONL with a live Claude Code session writing to it
#   - Git Bash MSYS /c/... drive form from CLAUDE_PROJECT_DIR (never emitted by
#     node process.cwd() or env; only old R3 bash encoder produced it — deleted)
#   - CLAUDE_ENV_FILE written by the real session-start.js (P3 file is faked in B-31)
#   - CLAUDE_ENV_FILE present but unreadable (permission denied) → P3 fallthrough;
#     chmod-based read-deny is unreliable under Windows/MSYS ACLs
#   - Windows path separator round-trip through the real node binary on a POSIX host
#   - wip-set-resume.sh full two-pass flow (label probe + WIP set — needs live gh)
#   - issue-close-write-outcome.js catch-fallback when AGENTS_CONFIG_DIR is unset
#     (require of hooks/lib/workflow-state throws → CLAUDE_SESSION_ID env fallback)
# Closest-to-action mitigation: skill-orchestration gate at WORKFLOW_USER_VERIFIED preflight.
#
# All tests isolate via CLAUDE_TRANSCRIPT_BASE_DIR and mktemp.
# NEVER touch ~/.claude/projects.
# RED: this suite exits non-zero (clean FAIL) while bin/resolve-session-id is missing.
# Split: dispatcher sourcing tests/feature-resolve-session-id-sh/ sub-files.

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
