#!/usr/bin/env bash
# tests/skills/feature-1937-resolve-dir-expand.sh
# Tests: skills/worktree-end/scripts/resolve-dir-expand.js, hooks/lib/verbose-prompt.js
# Tags: worktree-end, dir_expand, verbose-prompt, session-id-resolution, TL1, scope:issue-specific
#
# Issue #1937: WE-9 gates gitignored-directory expansion on verbose_prompt.
# resolve-dir-expand.js self-resolves the session id (resolveSessionId SSOT) and
# prints true/false; [SID] cases pin that it reads CLAUDE_CODE_SESSION_ID (the id
# reliably present in the WE-9 Bash subprocess) and fail-safes to false with none.
# TL3 gap: the live payload wiring is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh (category: skill-orchestration).

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENTS_DIR="$REPO_DIR"
# shellcheck source=../lib/harness.sh
. "$REPO_DIR/tests/lib/harness.sh"
SCRIPT_JS="$REPO_DIR/skills/worktree-end/scripts/resolve-dir-expand.js"
VERBOSE_PROMPT_JS="$REPO_DIR/hooks/lib/verbose-prompt.js"
to_node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
WFDIR="$TMPROOT/workflow"
PLANSDIR="$TMPROOT/plans"
mkdir -p "$WFDIR" "$PLANSDIR"
WFDIR_N="$(to_node_path "$WFDIR")"
PLANSDIR_N="$(to_node_path "$PLANSDIR")"
SCRIPT_N="$(to_node_path "$SCRIPT_JS")"
VP_N="$(to_node_path "$VERBOSE_PROMPT_JS")"

# seed_state <sid> <extra-json> — write a minimal state file the readState resolver finds.
seed_state() {
    local sid="$1"
    local extra
    if [ -n "${2:-}" ]; then extra="$2"; else extra='{}'; fi
    run_with_timeout 30 env CLAUDE_WORKFLOW_DIR="$WFDIR_N" node -e '
const fs = require("fs"), path = require("path");
const sid = process.argv[1];
const extra = JSON.parse(process.argv[2]);
const state = Object.assign({ version: 1, session_id: sid,
  created_at: new Date().toISOString(), steps: {} }, extra);
fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + ".json"),
  JSON.stringify(state, null, 2));
' "$sid" "$extra" </dev/null >/dev/null 2>&1
}

# resolve <env-kv-string> [script-args...] — run the resolver in a clean env.
# Both inherited session ids are unset so only what the case sets is visible.
resolve() {
    local envkv="$1"; shift
    run_with_timeout 60 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
        CLAUDE_WORKFLOW_DIR="$WFDIR_N" WORKFLOW_PLANS_DIR="$PLANSDIR_N" \
        $envkv node "$SCRIPT_N" "$@" </dev/null 2>/dev/null
}

if [ ! -f "$SCRIPT_JS" ]; then
    fail "0-resolver-script-exists" "not implemented yet: $SCRIPT_JS"
fi

# Case A — verbose_prompt:true resolves to "true"
case_begin "A-verbose-true" "skills/worktree-end/scripts/resolve-dir-expand.js"
seed_state "sid-a01" '{"verbose_prompt":true}'
assert_eq "A-verbose-true-prints-true" "true" "$(resolve "" --session sid-a01)"
case_end

# Case B — verbose_prompt:false resolves to "false"
case_begin "B-verbose-false" "skills/worktree-end/scripts/resolve-dir-expand.js"
seed_state "sid-b01" '{"verbose_prompt":false}'
assert_eq "B-verbose-false-prints-false" "false" "$(resolve "" --session sid-b01)"
case_end

# Case C — verbose_prompt absent resolves to "false" (default off)
case_begin "C-verbose-absent" "skills/worktree-end/scripts/resolve-dir-expand.js"
seed_state "sid-c01" '{}'
assert_eq "C-verbose-absent-prints-false" "false" "$(resolve "" --session sid-c01)"
case_end

# Case D — [SID] WE-9 reality: CLAUDE_CODE_SESSION_ID is the only id reliably
#   present. A verbose session must resolve "true" from it alone; with NO id at
#   all the resolver must fail-safe to "false".
case_begin "D-SID-code-session-id-only" "skills/worktree-end/scripts/resolve-dir-expand.js"
seed_state "sid-d01" '{"verbose_prompt":true}'
assert_eq "D-code-session-id-only-resolves-true" "true" \
    "$(resolve "CLAUDE_CODE_SESSION_ID=sid-d01")"
assert_eq "D-no-id-fail-safes-false" "false" "$(resolve "")"
case_end

# Case E — an explicit --session overrides the ambient env id.
case_begin "E-explicit-session-arg" "skills/worktree-end/scripts/resolve-dir-expand.js"
seed_state "sid-e-true" '{"verbose_prompt":true}'
seed_state "sid-e-false" '{"verbose_prompt":false}'
assert_eq "E-explicit-session-arg-wins" "true" \
    "$(resolve "CLAUDE_CODE_SESSION_ID=sid-e-false" --session sid-e-true)"
case_end

# isVerbosePromptSession — the read-only boolean the resolver delegates to.
vp_call() {
    run_with_timeout 30 env CLAUDE_WORKFLOW_DIR="$WFDIR_N" WORKFLOW_PLANS_DIR="$PLANSDIR_N" \
        node -e '
const m = require(process.argv[1]);
if (typeof m.isVerbosePromptSession !== "function") { process.stdout.write("(no-fn)"); process.exit(0); }
let r;
try { r = m.isVerbosePromptSession(process.argv[2]); } catch (e) { r = "THREW"; }
process.stdout.write(String(r));
' "$VP_N" "$1" </dev/null 2>/dev/null
}
case_begin "VP-is-verbose-prompt-session" "hooks/lib/verbose-prompt.js"
assert_eq "VP-true-session-returns-true" "true" "$(vp_call sid-a01)"
assert_eq "VP-false-session-returns-false" "false" "$(vp_call sid-b01)"
assert_eq "VP-absent-session-returns-false" "false" "$(vp_call sid-c01)"
assert_eq "VP-unknown-session-returns-false" "false" "$(vp_call sid-never-created)"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
