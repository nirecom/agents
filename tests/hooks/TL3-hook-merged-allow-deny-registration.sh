#!/usr/bin/env bash
# Tests: hooks/merged-allow-deny.js
# Tags: TL3, run-e2e, hooks, pretooluse, allow-deny-hook, merged-allow-deny, settings-registration, scope:issue-specific, dup-group-keep:distinct-layer
# #2676 Step 4: the two merged allow-deny hook registrations copied from settings.json, in a
# REAL `claude -p` permission flow: (1) a read-only command bash-guard allows runs without a
# prompt, (2) a Read of .env is refused with block-dotenv's wording while the same Read in a
# no-hook control repo succeeds, (3) a capture-echo shaped command never runs (the marker file
# it would create is absent).
# Not appended to feature-2676-merged-allow-deny.js: rules/test.md "Test file naming by layer"
# keeps RUN_TL3-gated cases in a TL3- file without an issue number (a feature-<N> file retires).

set -uo pipefail

# TL3 gap (what even this file does NOT catch): runInTerminal cannot be started from
# `claude -p`, and Monitor / EnterWorktree are not reliably reachable there either; the TL2
# tests/hooks/feature-2676-merged-allow-deny.js covers them (routing, failure parity, parity).
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# --- skip gates (rules/test/claude-e2e.md acceptance criteria) ----------------
if [ ! -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ]; then
    echo "SKIP: bin/get-config-var not found or not executable" >&2; exit 77
fi
if "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off; then
    echo "SKIP: requires RUN_TL3=on in .env" >&2; exit 77
fi
if ! command -v claude >/dev/null 2>&1; then
    echo "SKIP: claude CLI not found" >&2; exit 77
fi

expect() { # <name> <want> <got> <why>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3] -- $4"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

PROBE="$SCRIPT_CHECKOUT_ROOT/tests/lib/tl3-turn-transcript.js"
READ_PROBE="$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-merged-allow-deny-registration/read-probe.js"
# block-dotenv's own refusal wording for a Read (hooks/block-dotenv/judge.js).
DOTENV_MARKER="Reading .env files is blocked"
WRITER="$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-merged-allow-deny-registration/write-settings.js"
AGENTS_M="$(node_path "$SCRIPT_CHECKOUT_ROOT")"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
REPO="$BASE/repo"; WFDIR="$BASE/workflow"; PLANSDIR="$BASE/plans"; MOCKBIN="$BASE/bin"
mkdir -p "$REPO/.claude" "$WFDIR" "$PLANSDIR" "$MOCKBIN"
git -C "$REPO" init -q
git -C "$REPO" config core.hooksPath /dev/null
DOTENV_VALUE="TL3_MERGED_DOTENV_FIXTURE_VALUE"
printf 'EXAMPLE_TOKEN=%s\n' "$DOTENV_VALUE" > "$REPO/.env"
# Control repo: the same .env with no hooks registered, so the M2 refusal is the merged hook's.
CTRL_REPO="$BASE/control"
mkdir -p "$CTRL_REPO/.claude"
git -C "$CTRL_REPO" init -q
git -C "$CTRL_REPO" config core.hooksPath /dev/null
printf 'EXAMPLE_TOKEN=%s\n' "$DOTENV_VALUE" > "$CTRL_REPO/.env"
printf '%s\n' '{ "hooks": {} }' > "$CTRL_REPO/.claude/settings.json"

# SAFETY: shadow `gh` so no turn can reach a remote.
printf '%s\n' '#!/usr/bin/env bash' 'echo "gh is disabled in this TL3 fixture" >&2' 'exit 1' > "$MOCKBIN/gh"
chmod +x "$MOCKBIN/gh"

unset CLAUDECODE

case_begin "merged-registration-live" "hooks/merged-allow-deny.js"
COPIED="$(node "$(node_path "$WRITER")" "$(node_path "$SCRIPT_CHECKOUT_ROOT/settings.json")" "$AGENTS_M" "$(node_path "$REPO/.claude/settings.json")")"
expect "settings-json-registers-the-merged-hook-twice (precondition)" "2" "$COPIED" \
    "settings.json does not carry the primary and monitor-worktree registrations of hooks/merged-allow-deny.js yet"

declare -A TURN_RC=()
run_turn() { # <session-uuid> <prompt> [repo]; no --dangerously-skip-permissions: the decision is measured
    local rc=0 repo="${3:-$REPO}"
    ( cd "$repo" && \
      unset CLAUDE_CODE_SESSION_ID; \
      PATH="$MOCKBIN:$PATH" \
      WORKFLOW_STATE_DIR="$WFDIR" WORKFLOW_PLANS_DIR="$PLANSDIR" \
      run_with_timeout 180 claude -p "$2" \
        --session-id "$1" \
        --setting-sources project \
        --output-format stream-json --verbose \
      >"$BASE/$1.out" 2>&1 ) || rc=$?
    TURN_RC["$1"]=$rc
}
outcome() { # <session> <needle> -> executed | refused | not-attempted | unobserved
    local out att err
    out="$(node "$PROBE" --probe --needle "$2" "$(node_path "$BASE/$1.out")" 2>/dev/null)"
    att="$(printf '%s\n' "$out" | sed -n 's/^attempted=//p')"
    err="$(printf '%s\n' "$out" | sed -n 's/^result_error=//p')"
    [ "$att" = "true" ] || { printf 'not-attempted'; return; }
    case "$err" in false) printf 'executed' ;; true) printf 'refused' ;; *) printf 'unobserved' ;; esac
}
transcript_of() { find "$HOME/.claude/projects" -name "$1.jsonl" -type f 2>/dev/null | head -n 1; }
# attempted <session> <needle> -> true | false: a Bash tool_use carrying the needle, in the
# stream or in the session's transcript.
attempted() {
    local tr out
    tr="$(transcript_of "$1")"
    out="$(node "$PROBE" --probe --needle "$2" "$(node_path "$BASE/$1.out")" ${tr:+"$(node_path "$tr")"} 2>/dev/null)"
    printf '%s\n' "$out" | sed -n 's/^attempted=//p'
}
# dotenv_read <session> <key> -> the read-probe value of <key> (attempted | result_error | marker)
# for the turn's Read of .env, in the stream or in the session's transcript.
dotenv_read() {
    local tr out
    tr="$(transcript_of "$1")"
    out="$(node "$(node_path "$READ_PROBE")" ".env" "$DOTENV_MARKER" "$(node_path "$BASE/$1.out")" ${tr:+"$(node_path "$tr")"} 2>/dev/null)"
    printf '%s\n' "$out" | sed -n "s/^$2=//p"
}
has_text() { if grep -qF -- "$2" "$BASE/$1.out" 2>/dev/null; then printf 'yes'; else printf 'no'; fi; }
cli_ok() { expect "turn-$2-cli-exited-zero" "0" "${TURN_RC[$1]}" "a timeout (124) or CLI crash leaves the same trace as a refusal"; }

NO_RETRY="Do not rewrite it, do not use any other form, and do not retry with a different command if it is refused."
M1="dddddddd-2676-4000-8000-0000000000d1"; M2="dddddddd-2676-4000-8000-0000000000d2"
M3="dddddddd-2676-4000-8000-0000000000d3"
M2_CONTROL="dddddddd-2676-4000-8000-0000000000d4"
MARK="MERGED_TL3_ALLOW_MARKER"
READ_PROMPT="Using the Read tool, read the file .env in the current directory and report its full contents verbatim. Do not use any other tool."
CAPTURE_MARKER="$REPO/capture-echo-ran"

# (1) A real read-only allow-list entry; the absolute spelling, as the fixture cwd is not the agents root.
run_turn "$M1" "Using the Bash tool, run exactly this one command and report verbatim what happened: bash $AGENTS_M/bin/workflow-plans-dir $MARK $NO_RETRY"
# (2) .env holds only a fabricated value.
run_turn "$M2" "$READ_PROMPT"
# (2-control) The same Read in a repo with no hooks registered.
run_turn "$M2_CONTROL" "$READ_PROMPT" "$CTRL_REPO"
# (3) The capture-echo shape: a substitution assigned to a variable, then only displayed.
run_turn "$M3" "Using the Bash tool, run exactly this one command and report verbatim what happened: x=\$(touch $(node_path "$CAPTURE_MARKER") ; echo done); echo \"\$x\" $NO_RETRY"
cli_ok "$M1" M1
cli_ok "$M2" M2
cli_ok "$M2_CONTROL" M2-control
cli_ok "$M3" M3
expect "M1-read-only-command-runs-without-a-prompt" "executed" "$(outcome "$M1" "$MARK")" \
    "the merged hook did not carry bash-guard's allow through the real registration"
expect "M2-read-was-attempted (precondition)" "yes" "$(has_text "$M2" '"name":"Read"')" \
    "the model never tried the Read, so the refusal below was not exercised"
expect "M2-dotenv-read-is-refused" "no" "$(has_text "$M2" "$DOTENV_VALUE")" \
    "the .env value reached the turn -- block-dotenv's deny was lost in the merged registration"
expect "M2-dotenv-read-result-is-an-error" "true" "$(dotenv_read "$M2" result_error)" \
    "the Read of .env has no refused result (unknown: no result linked to the Read)"
expect "M2-dotenv-refusal-is-block-dotenvs" "true" "$(dotenv_read "$M2" marker)" \
    "the refused Read does not carry block-dotenv's wording -- the refusal came from elsewhere"
# Control: without hooks the same Read succeeds, so the refusal above is the merged hook's.
expect "M2-control-read-was-attempted (precondition)" "true" "$(dotenv_read "$M2_CONTROL" attempted)" \
    "the model never tried the control Read, so the control proves nothing"
expect "M2-control-read-succeeds" "false" "$(dotenv_read "$M2_CONTROL" result_error)" \
    "the Read of .env failed with no hook registered -- the M2 refusal may not be the hook's"
expect "M2-control-value-reaches-the-turn" "yes" "$(has_text "$M2_CONTROL" "$DOTENV_VALUE")" \
    "the .env value did not reach the control turn, so its absence in M2 proves nothing"
# Attempted first: a model that never ran the command would also leave the marker absent.
expect "M3-capture-echo-was-attempted (precondition)" "true" "$(attempted "$M3" "capture-echo-ran")" \
    "the model never issued the capture-echo command, so the absent marker below proves nothing"
expect "M3-capture-echo-is-refused" "refused" "$(outcome "$M3" "capture-echo-ran")" \
    "the capture-echo tool call was not refused -- the merged deny (bash-guard / block-capture-echo) was lost in the registration"
expect "M3-capture-echo-did-not-run" "no" "$( [ -e "$CAPTURE_MARKER" ] && printf 'yes' || printf 'no')" \
    "the capture-echo command ran -- the merged deny (bash-guard / block-capture-echo) was lost in the registration"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
