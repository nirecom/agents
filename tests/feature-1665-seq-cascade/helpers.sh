#!/bin/bash
# tests/feature-1665-seq-cascade/helpers.sh
# Tests: hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/effective-state/write-code-resume.js
# Tags: workflow-state, updated-seq, causal-order, write-code-resume, harness, scope:issue-specific, pwsh-not-required, TL1, TL2
#
# Shared harness for the #1665 commit-3 suite (seq projection + write-code resume
# cascade). SOURCED by each case file; never run standalone.
#
# Isolation contract — rules/test/fixture-isolation.md:
#   - CLAUDE_WORKFLOW_DIR and WORKFLOW_PLANS_DIR are BOTH pinned (dual-pin).
#   - CLAUDE_SESSION_ID / CLAUDE_CODE_SESSION_ID are unset before any node spawn.
#   - CWD is a neutral temp dir, never the worktree.
#   - Fixture repos get `git config core.hooksPath /dev/null`.
#   - Paths handed to node are normalized with `cygpath -m`.
#
# NO SKIP PATH: exit 77 is reserved for "node is not installed". Every other
# outcome is PASS or FAIL — an unimplemented feature must surface as a genuine
# assertion failure, never as a skip.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# native path: node on Windows needs a drive-letter path, not /c/...
nrm() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

TMPROOT="$(mktemp -d)"
trap 'cd /; rm -rf "$TMPROOT" >/dev/null 2>&1 || true' EXIT

mkdir -p "$TMPROOT/wf" "$TMPROOT/plans" "$TMPROOT/cfg" "$TMPROOT/home"
: > "$TMPROOT/cfg/.env"

CLAUDE_WORKFLOW_DIR="$(nrm "$TMPROOT/wf")"; export CLAUDE_WORKFLOW_DIR
WORKFLOW_PLANS_DIR="$(nrm "$TMPROOT/plans")"; export WORKFLOW_PLANS_DIR
AGENTS_CONFIG_DIR="$(nrm "$TMPROOT/cfg")"; export AGENTS_CONFIG_DIR
HOME="$TMPROOT/home"; export HOME
USERPROFILE="$(nrm "$TMPROOT/home")"; export USERPROFILE
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR

# Neutral CWD: hooks that shell out to `git rev-parse` must not resolve the worktree.
cd "$TMPROOT" || exit 1

# Module paths handed to node via env (keeps the -e scripts free of interpolation).
M_SIO="$AGENTS_DIR_N/hooks/workflow-state/state-io.js"; export M_SIO
M_CORE="$AGENTS_DIR_N/hooks/workflow-state/state-io/core.js"; export M_CORE
M_PROJ="$AGENTS_DIR_N/hooks/workflow-state/state-io/projection.js"; export M_PROJ
M_EVT="$AGENTS_DIR_N/hooks/workflow-state/state-io/events.js"; export M_EVT
M_V1V2="$AGENTS_DIR_N/hooks/workflow-state/state-io/migrations/v1-to-v2.js"; export M_V1V2
M_ES="$AGENTS_DIR_N/hooks/workflow-state/effective-state.js"; export M_ES
M_WCR="$AGENTS_DIR_N/hooks/workflow-state/effective-state/write-code-resume.js"; export M_WCR
M_INH="$AGENTS_DIR_N/hooks/workflow-state/inheritance/apply.js"; export M_INH
M_LIFE="$AGENTS_DIR_N/hooks/workflow-state/lifecycle.js"; export M_LIFE
M_POLICY="$AGENTS_DIR_N/hooks/lib/stop-exemption-policy.js"; export M_POLICY
M_GUARD="$AGENTS_DIR_N/hooks/stop-premature-stop-guard.js"; export M_GUARD

NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"

PASS_N=0; FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "  PASS: $1"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "  FAIL: $1"; }

assert_eq() { # assert_eq <label> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi
}
assert_ne() { # assert_ne <label> <notwant> <got>
    if [ "$2" != "$3" ]; then pass "$1"; else fail "$1 -- got the forbidden value [$3]"; fi
}
assert_contains() { # assert_contains <label> <needle> <haystack>
    case "$3" in *"$2"*) pass "$1";; *) fail "$1 -- [$2] not found in [$3]";; esac
}
assert_not_contains() { # assert_not_contains <label> <needle> <haystack>
    case "$3" in *"$2"*) fail "$1 -- [$2] unexpectedly found in [$3]";; *) pass "$1";; esac
}

finish() {
    echo "  -- ${CASE_TAG:-case}: $PASS_N passed, $FAIL_N failed"
    [ "$FAIL_N" -eq 0 ]
}

# js <script> -- run node -e under a 120s timeout. Result in JS_OUT / JS_RC.
JS_OUT=""; JS_RC=0
js() {
    JS_RC=0
    JS_OUT="$("$RWT" 120 node -e "$1" 2>&1)" || JS_RC=$?
}

# js_g <script> -- same, but a throw inside the probe is reported as a single
# clean PROBE_ERROR line instead of a node stack trace. Unimplemented source
# (a missing module, a step not yet in VALID_STEPS) is expected RED, and it must
# read as one legible failure, not as harness noise.
js_g() {
    js "try {
$1
} catch (e) { console.log(\"PROBE_ERROR=\" + String((e && e.message) || e).split(\"\\n\")[0]); }"
}

# kv <key> -- first "key=value" line of JS_OUT. Missing key yields "" (never a
# silent pass: every caller compares against a concrete expected value).
kv() { printf '%s\n' "$JS_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }

# assert_js <label> <key> <want>
assert_js() { assert_eq "$1 ($2)" "$3" "$(kv "$2")"; }

# require_js_ok <label> -- the probe produced usable output. A non-zero node
# exit or a PROBE_ERROR line is reported once, and the per-key assertions that
# follow are skipped (they would only restate the same fact N times).
require_js_ok() {
    if [ "$JS_RC" -ne 0 ]; then
        fail "$1 -- node exited $JS_RC: $(printf '%s\n' "$JS_OUT" | grep -m1 -E 'Error|error' || printf '%s' "$JS_OUT")"
        return 1
    fi
    local perr
    perr="$(kv PROBE_ERROR)"
    if [ -n "$perr" ]; then
        fail "$1 -- probe could not run: $perr"
        return 1
    fi
    return 0
}

# mk_repo <dir> -- throwaway git repo for hooks that need CLAUDE_PROJECT_DIR.
mk_repo() {
    mkdir -p "$1"
    git -C "$1" init -q 2>/dev/null
    git -C "$1" config core.hooksPath /dev/null
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test"
}
