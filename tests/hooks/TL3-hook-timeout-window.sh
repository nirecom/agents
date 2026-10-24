#!/usr/bin/env bash
# Tests: hooks/lib/decision-time-limit.js, hooks/lib/hook-cancel-notice.js
# Tags: TL3, run-e2e, hooks, pretooluse, hook-timeout, hook-cancel, permission-decision, allow-deny-hook, scope:issue-specific
# #2676 Step 7: what Claude Code does with a PreToolUse hook that overruns its `timeout`, in a
# REAL permission flow. Fixed expectations (gate 1 (a)): an allow hook that times out is
# refused (A2); a deny hook that times out, with a permissions.allow rule matching, executes
# (A3); ask beside allow is refused (A6); a timed-out hook leaves one hook_cancelled record.
# A4 (launch delay) is judged only where its outcome is fixed (the cancel record and the next
# turn's notice); its timer-origin question and A5 (two slow hooks side by side) are recorded only.

set -uo pipefail

# TL3 gap (what even this file does NOT catch): an interactive session's dialog (an `ask` is
# observed as the -p refusal it turns into) and other CLI builds' cancel timing. The day-to-day
# runners are tests/hooks/feature-2676-hook-timeout-relation.js and feature-2676-hook-cancel-notice.js.
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

STUB="$(node_path "$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-timeout-window/delay-stub.js")"
PROBE="$SCRIPT_CHECKOUT_ROOT/tests/lib/tl3-turn-transcript.js"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
REPO="$BASE/repo"; WFDIR="$BASE/workflow"; PLANSDIR="$BASE/plans"; MOCKBIN="$BASE/bin"
mkdir -p "$REPO/.claude" "$WFDIR" "$PLANSDIR" "$MOCKBIN"
git -C "$REPO" init -q
git -C "$REPO" config core.hooksPath /dev/null

# SAFETY: shadow `gh` so no turn can reach a remote.
printf '%s\n' '#!/usr/bin/env bash' 'echo "gh is disabled in this TL3 fixture" >&2' 'exit 1' > "$MOCKBIN/gh"
chmod +x "$MOCKBIN/gh"

# stub <ms> <decision> <label> [launch-prefix] -> one hook entry with a 2 s timeout.
stub() {
    printf '{"type":"command","command":"%snode \\"%s\\" %s %s %s","timeout":2}' "${4:-}" "$STUB" "$1" "$2" "$3"
}
# write_settings <permissions-allow-json-array> <hook-entry>... : only these PreToolUse/Bash
# hooks, and never disableBypassPermissionsMode (rules/test/claude-e2e.md).
write_settings() {
    local allow="$1" hooks="" entry; shift
    for entry in "$@"; do hooks="${hooks:+$hooks,}$entry"; done
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[%s]}]},"permissions":{"allow":%s}}\n' \
        "$hooks" "$allow" > "$REPO/.claude/settings.json"
}
# write_settings_with_notice: write_settings plus the UserPromptSubmit hook that tells a cancel
# ($NOTICE_HOOK, this checkout's copy) on the next prompt of the session.
write_settings_with_notice() {
    local allow="$1" hooks="" entry; shift
    for entry in "$@"; do hooks="${hooks:+$hooks,}$entry"; done
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[%s]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"node \\"%s\\"","timeout":30}]}]},"permissions":{"allow":%s}}\n' \
        "$hooks" "$NOTICE_HOOK" "$allow" > "$REPO/.claude/settings.json"
}

unset CLAUDECODE

declare -A TURN_RC=()
run_turn() { # <session-uuid> <prompt>; no --dangerously-skip-permissions: the decision is measured
    local rc=0
    ( cd "$REPO" && \
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
run_resume() { # <session-uuid> <prompt>: the next turn of that session; output in <sid>-notice.out
    local rc=0
    ( cd "$REPO" && \
      unset CLAUDE_CODE_SESSION_ID; \
      PATH="$MOCKBIN:$PATH" \
      WORKFLOW_STATE_DIR="$WFDIR" WORKFLOW_PLANS_DIR="$PLANSDIR" \
      run_with_timeout 180 claude -p "$2" \
        --resume "$1" \
        --setting-sources project \
        --output-format stream-json --verbose \
      >"$BASE/$1-notice.out" 2>&1 ) || rc=$?
    TURN_RC["$1-notice"]=$rc
}
# notice_lines <session> -> transcript lines naming delay-stub that are not the cancel record itself
notice_lines() {
    local tr; tr="$(transcript_of "$1")"
    [ -n "$tr" ] || { printf '0'; return; }
    grep 'delay-stub' "$tr" 2>/dev/null | grep -vc '"type":"hook_cancelled"' || true
}
transcript_of() { find "$HOME/.claude/projects" -name "$1.jsonl" -type f 2>/dev/null | head -n 1; }
outcome() { # <session> -> executed | refused | not-attempted | unobserved
    local out att err tr
    tr="$(transcript_of "$1")"
    out="$(node "$PROBE" --probe --needle "git --version" "$(node_path "$BASE/$1.out")" ${tr:+"$(node_path "$tr")"} 2>/dev/null)"
    att="$(printf '%s\n' "$out" | sed -n 's/^attempted=//p')"
    err="$(printf '%s\n' "$out" | sed -n 's/^result_error=//p')"
    [ "$att" = "true" ] || { printf 'not-attempted'; return; }
    case "$err" in false) printf 'executed' ;; true) printf 'refused' ;; *) printf 'unobserved' ;; esac
}
cancel_count() { # <session> -> number of hook_cancelled attachment records in its transcript
    local tr; tr="$(transcript_of "$1")"
    [ -n "$tr" ] || { printf 'no-transcript'; return; }
    grep -c '"type":"hook_cancelled"' "$tr" 2>/dev/null || true
}
cli_ok() { expect "turn-$2-cli-exited-zero" "0" "${TURN_RC[$1]}" "a timeout (124) or CLI crash leaves the same trace as a refusal"; }

PROMPT="Using the Bash tool, run exactly this one command and report verbatim what happened: git --version. Do not rewrite it, do not use any other form, and do not retry with a different command if it is refused."
A2="aaaaaaaa-2676-4000-8000-0000000000a2"; A3="aaaaaaaa-2676-4000-8000-0000000000a3"
A4="aaaaaaaa-2676-4000-8000-0000000000a4"; A5="aaaaaaaa-2676-4000-8000-0000000000a5"
A6="aaaaaaaa-2676-4000-8000-0000000000a6"

echo "=== timed-out hooks and the permission decision ==="
case_begin "timeout-window-decisions" "hooks/lib/decision-time-limit.js"
write_settings '[]' "$(stub 3000 allow A2)"
run_turn "$A2" "$PROMPT"
write_settings '["Bash(git --version)"]' "$(stub 3000 deny A3)"
run_turn "$A3" "$PROMPT"
write_settings '[]' "$(stub 0 ask A6ask)" "$(stub 0 allow A6allow)"
run_turn "$A6" "$PROMPT"
cli_ok "$A2" A2
cli_ok "$A3" A3
cli_ok "$A6" A6
expect "A2-timed-out-allow-is-lost" "refused" "$(outcome "$A2")" \
    "a timed-out allow hook still allowed -- Claude Code waits for or keeps late answers now; re-measure gate 1 (a)"
expect "A3-timed-out-deny-is-lost" "executed" "$(outcome "$A3")" \
    "a timed-out deny hook still blocked an allow-listed command -- re-measure gate 1 (a)"
expect "A6-ask-beats-allow" "refused" "$(outcome "$A6")" \
    "allow overrode a sibling ask -- the decision-time-limit ask no longer holds the call; re-measure gate 1 (a)"
case_end

echo "=== the hook_cancelled record the notice reads ==="
case_begin "timeout-window-cancel-record" "hooks/lib/hook-cancel-notice.js"
expect "A2-one-hook-cancelled-record" "1" "$(cancel_count "$A2")" \
    "the transcript no longer carries exactly one hook_cancelled record -- hook-cancel-notice.js reads a shape that changed"
case_end

echo "=== A4 launch delay: the cancel record and the notice of the next turn ==="
# Judged (deterministic): the command's own `sleep 1.5` plus the 1000 ms stub (2.5 s) overruns the
# 2 s timeout wherever Claude Code starts its clock, so the allow is lost (refused, as in A2),
# one hook_cancelled record is written, and the next prompt of the session gets the notice.
# Observed only (nondeterministic): whether Claude Code's own spawn delay counts toward the
# timeout (A4's gate 1 question), and A5 below.
case_begin "timeout-window-launch-delay" "hooks/lib/hook-cancel-notice.js"
NOTICE_HOOK="$(node_path "$SCRIPT_CHECKOUT_ROOT/hooks/user-prompt-submit-mechanism-check.js")"
write_settings_with_notice '[]' "$(stub 1000 allow A4 'sleep 1.5; ')"
run_turn "$A4" "$PROMPT"
cli_ok "$A4" A4
expect "A4-launch-delayed-allow-is-lost" "refused" "$(outcome "$A4")" \
    "an allow hook that overran its timeout through a launch prefix still allowed -- re-measure gate 1 (a)"
expect "A4-one-hook-cancelled-record" "1" "$(cancel_count "$A4")" \
    "the overrun left no (or more than one) hook_cancelled record"
before_notice="$(notice_lines "$A4")"
run_resume "$A4" "Reply with the single word OK. Do not use any tool."
expect "A4-notice-turn-cli-exited-zero" "0" "${TURN_RC[$A4-notice]}" "the follow-up turn did not complete"
# The notice names the cancelled hook (delay-stub); a new non-cancel line naming it, in the
# transcript or in the follow-up turn's stream, is the notice reaching the session.
after_notice="$(notice_lines "$A4")"
stream_notice="$(grep -c 'delay-stub' "$BASE/$A4-notice.out" 2>/dev/null || true)"
if [ "$after_notice" -gt "$before_notice" ] || [ "${stream_notice:-0}" -gt 0 ]; then
    pass "A4-next-turn-gets-cancel-notice"
else
    fail "A4-next-turn-gets-cancel-notice" "no notice naming delay-stub after the cancel (transcript $before_notice -> $after_notice, stream $stream_notice)"
fi
case_end

echo "=== observed only (A5 two slow hooks) ==="
# A5 is never judged: two 1200 ms hooks side by side fit the 2 s timeout or not depending on
# whether Claude Code runs them in parallel and on the host's load.
write_settings '[]' "$(stub 1200 allow A5a)" "$(stub 1200 allow A5b)"
run_turn "$A5" "$PROMPT"
echo "OBSERVED A4 (timer origin): durationMs/timeoutMs of its cancel record are in $(transcript_of "$A4")"
echo "OBSERVED A5: outcome=$(outcome "$A5") cancels=$(cancel_count "$A5") rc=${TURN_RC[$A5]}"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
