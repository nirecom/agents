#!/usr/bin/env bash
# Tests: hooks/block-capture-echo.js, hooks/lib/session-markers.js, docs/architecture/claude-code/marker-bypass-contract.md
# Tags: capture-echo-guard, marker-bypass, session-markers, protection-fix, scope:issue-specific, pwsh-not-required
# Serial: no

# Section G (round 13, C5) — the marker-bypass contract lists block-capture-echo.js
# as No/No: neither `<sid>.workflow-off` nor `<sid>.worktree-off` may weaken it.
# Every "still blocked" row is paired with a marker-probe control (the marker really
# is visible to session-markers.js under this env) and a benign-command control (the
# hook is not simply blocking everything), so neither direction can pass vacuously.

set -uo pipefail

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
export AGENTS_DIR
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$AGENTS_DIR/hooks/block-capture-echo.js"
command -v node >/dev/null 2>&1 || exit 77

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$want got=$got"; FAIL=$((FAIL + 1))
    fi
}

finish() {
    echo ""
    echo "Section G: PASS=$PASS FAIL=$FAIL"
    exit "$FAIL"
}

if [ ! -f "$HOOK" ]; then
    assert_eq "G-hook-present" "present" "HOOK_MISSING"
    finish
fi

TMPDIR_G="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_G"' EXIT
WFDIR="$TMPDIR_G/workflow"
mkdir -p "$WFDIR" "$TMPDIR_G/plans"
if command -v cygpath >/dev/null 2>&1; then
    WFDIR="$(cygpath -m "$WFDIR")"
fi

unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export CLAUDE_WORKFLOW_DIR="$WFDIR"
export WORKFLOW_PLANS_DIR="$TMPDIR_G/plans"

SID="g2170markerfixture"
EV="$TMPDIR_G/event.json"
OUT="$TMPDIR_G/out.json"

# run_hook <command-text> — spawns the real hook with the fixture sid in env.
run_hook() {
    node "$HERE/mk-event.js" Bash "$1" >"$EV"
    env CLAUDE_SESSION_ID="$SID" node "$HOOK" <"$EV" >"$OUT" 2>/dev/null
    node "$HERE/hook-out.js" "$OUT"
}

probe() { env CLAUDE_SESSION_ID="$SID" node "$HERE/marker-probe.js" "$SID"; }

CAPTURE='X=$(git rev-parse --short HEAD); echo "$X"'
BENIGN='git rev-parse --short HEAD'

# --- G-0: baseline, no markers present -------------------------------------------
assert_eq "G-0a-no-markers-visible" "workflow-off=off worktree-off=off" "$(probe)"
assert_eq "G-0b-capture-echo-blocked" "block" "$(run_hook "$CAPTURE")"
assert_eq "G-0c-benign-command-allowed" "passthrough" "$(run_hook "$BENIGN")"

# --- G-1: workflow-off active -----------------------------------------------------
: >"$WFDIR/$SID.workflow-off"
assert_eq "G-1a-marker-really-visible" "workflow-off=on worktree-off=off" "$(probe)"
assert_eq "G-1b-still-blocked-under-workflow-off" "block" "$(run_hook "$CAPTURE")"
assert_eq "G-1c-benign-still-allowed" "passthrough" "$(run_hook "$BENIGN")"

# --- G-2: worktree-off active -----------------------------------------------------
rm -f "$WFDIR/$SID.workflow-off"
: >"$WFDIR/$SID.worktree-off"
assert_eq "G-2a-marker-really-visible" "workflow-off=off worktree-off=on" "$(probe)"
assert_eq "G-2b-still-blocked-under-worktree-off" "block" "$(run_hook "$CAPTURE")"

# --- G-3: BOTH markers active — the maximum-permission state ----------------------
: >"$WFDIR/$SID.workflow-off"
assert_eq "G-3a-both-markers-visible" "workflow-off=on worktree-off=on" "$(probe)"
assert_eq "G-3b-still-blocked-under-both" "block" "$(run_hook "$CAPTURE")"
assert_eq "G-3c-benign-still-allowed" "passthrough" "$(run_hook "$BENIGN")"

# --- G-4: the hook source consults no marker reader at all ------------------------
# Behavioural rows above prove the outcome; this pins the mechanism, so a future
# refactor that adds a conditional bypass fails here even before behaviour drifts.
for token in session-markers isWorkflowOff isWorktreeOff; do
    hits="$(grep -c -- "$token" "$HOOK" || true)"
    assert_eq "G-4-hook-source-free-of-[$token]" "0" "$hits"
done
# The marker names may appear in the header comment (they do, declaring the hook
# unconditional); they must never appear in executable text.
code_hits="$(grep -v -E '^\s*(//|/\*|\*)' "$HOOK" | grep -c -E 'workflow-off|worktree-off' || true)"
assert_eq "G-4-marker-names-absent-from-executable-lines" "0" "$code_hits"

# --- G-5: the contract doc still classifies this hook as No/No --------------------
DOC="$AGENTS_DIR/docs/architecture/claude-code/marker-bypass-contract.md"
row="$(grep -F 'block-capture-echo.js' "$DOC" | head -1 | tr -d ' *')"
case "$row" in
    *"|No|No|"*) got="no-no" ;;
    "") got="ROW_MISSING" ;;
    *) got="$row" ;;
esac
assert_eq "G-5-contract-doc-row-is-no-no" "no-no" "$got"

finish
