#!/usr/bin/env bash
# Tests: hooks/workflow-mark/emit.js, hooks/stop-sentinel-unapplied-notice.js
# Tags: TL3, run-e2e, hooks, posttooluse, stop, pretooluse, output-channel, sentinel, scope:issue-specific, test-lang-exception:e2e
# #2824 Step 0: which PostToolUse output shapes reach the model in a REAL `claude -p` turn.
# S1 top-level additionalContext, S2 hookSpecificOutput.additionalContext, S3 systemMessage,
# S4 stderr + exit 2, S5 {decision:"block"}, S6 Stop systemMessage, S7 PreToolUse deny.
# Judged: the normal channel (S2, else S1) reaches the model (R1); the strong channel that
# hooks/workflow-mark/emit.js STRONG_CHANNEL chose (exit2 -> S4, block-decision -> S5) reaches it;
# S7's refused Bash leaves tool_result is_error and PostToolUse does not run. Observed only: S3,
# S6 and the attachment types each shape leaves in the transcript (R-tr).

set -uo pipefail

# TL3 gap (what even this file does NOT catch): what the user SEES (R2). `-p` shows no screen, so
# S2-S6's on-screen display is checked by eye in an interactive session, once, by the user; the
# day-to-day runners are tests/hooks/feature-2824-emit-render.js and
# tests/hooks/feature-2877-sentinel-receipt-backstop.js, which assume the shapes judged here.
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

BASE="$(make_tmp)"
readonly BASE
trap 'cd / || true; rm -rf "$BASE"' EXIT
REPO="$BASE/repo"; MOCKBIN="$BASE/bin"
mkdir -p "$REPO/.claude" "$MOCKBIN"
harness_isolate "$BASE"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
git -C "$REPO" init -q
git -C "$REPO" config core.hooksPath /dev/null

expect() { # <name> <want> <got> <why>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3] -- $4"; fi
}
PROBE_HOOK="$(np "$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-posttooluse-output-channels/probe-hook.js")"
TURN_PROBE="$SCRIPT_CHECKOUT_ROOT/tests/lib/tl3-turn-transcript.js"
OUT_LIB="$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/workflow-mark-output.js")"

# SAFETY: shadow `gh` so no turn can reach a remote.
printf '%s\n' '#!/usr/bin/env bash' 'echo "gh is disabled in this TL3 fixture" >&2' 'exit 1' > "$MOCKBIN/gh"
chmod +x "$MOCKBIN/gh"

hook() { printf '{"type":"command","command":"node \\"%s\\" %s %s","timeout":10}' "$PROBE_HOOK" "$1" "$2"; }
# write_settings <event> <hook-entry> [<event2> <hook-entry2>]: only these hooks, an allow rule
# for the probe command, and never disableBypassPermissionsMode (rules/test/claude-e2e.md).
write_settings() {
    local body="" m
    while [ "$#" -ge 2 ]; do
        m=""; [ "$1" = "Stop" ] || m='"matcher":"Bash",'
        body="${body:+$body,}\"$1\":[{${m}\"hooks\":[$2]}]"
        shift 2
    done
    printf '{"hooks":{%s},"permissions":{"allow":["Bash(echo hello-2824)"]}}\n' "$body" > "$REPO/.claude/settings.json"
}

unset CLAUDECODE

declare -A TURN_RC=()
run_turn() { # <session-uuid> <prompt>
    local rc=0
    ( cd "$REPO" && \
      PATH="$MOCKBIN:$PATH" \
      run_with_timeout 180 claude -p "$2" \
        --session-id "$1" \
        --setting-sources project \
        --output-format json \
      >"$BASE/$1.out" 2>"$BASE/$1.err" ) || rc=$?
    TURN_RC["$1"]=$rc
}
transcript_of() { find "$HOME/.claude/projects" -name "$1.jsonl" -type f 2>/dev/null | head -n 1; }
# reached <session> <nonce> -> yes | no: the nonce is in the final result the model wrote.
reached() {
    local res
    res="$(node -e 'const t=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").pop();let r="";try{r=String(JSON.parse(t).result||"")}catch(_){}process.stdout.write(r)' "$(np "$BASE/$1.out")" 2>/dev/null)"
    case "$res" in *"PROBE-$2"*) printf 'yes' ;; *) printf 'no' ;; esac
}
attachment_types() { # <session> -> the sorted distinct attachment types of its transcript
    local tr; tr="$(transcript_of "$1")"
    [ -n "$tr" ] || { printf 'no-transcript'; return; }
    grep -o '"attachment":{"type":"[a-z_]*"' "$tr" 2>/dev/null | sed 's/.*"type":"//; s/"$//' | sort -u | tr '\n' ' '
}

PROMPT="Using the Bash tool, run exactly this one command once: echo hello-2824. Then reply with every piece of text starting with PROBE- that reached you from a hook or the system after the command (copy it verbatim), or the single word NONE. Do not run any other command."
sid_of() { printf 'bbbbbbbb-2824-4000-8000-0000000000%s' "$1"; }

echo "=== PostToolUse output shapes S1-S5 and the Stop shape S6 ==="
declare -A REACHED=()
for s in 1 2 3 4 5 6; do
    sid="$(sid_of "0$s")"; nonce="s${s}x2824"
    if [ "$s" = 6 ]; then write_settings Stop "$(hook S6 "$nonce")"; else write_settings PostToolUse "$(hook "S$s" "$nonce")"; fi
    run_turn "$sid" "$PROMPT"
    REACHED["S$s"]="$(reached "$sid" "$nonce")"
    echo "OBSERVED S$s: rc=${TURN_RC[$sid]} reached-model=${REACHED[S$s]} attachments=[$(attachment_types "$sid")]"
done

case_begin "normal-channel-reaches-model" "hooks/workflow-mark/emit.js"
if [ "${REACHED[S2]}" = "yes" ] || [ "${REACHED[S1]}" = "yes" ]; then
    pass "S2-or-S1-reaches-model (S2=${REACHED[S2]} S1=${REACHED[S1]})"
else
    fail "S2-or-S1-reaches-model" "neither additionalContext shape reached the model -- the normal channel has no carrier"
fi
case_end

case_begin "strong-channel-reaches-model" "hooks/workflow-mark/emit.js"
channel="$(node "$OUT_LIB" strong-channel 2>/dev/null)"
case "$channel" in
    exit2) expect "strong-channel-exit2-S4-reaches-model" "yes" "${REACHED[S4]}" "stderr + exit 2 did not reach the model; re-decide STRONG_CHANNEL (detail plan Step 0 table)" ;;
    block-decision) expect "strong-channel-block-decision-S5-reaches-model" "yes" "${REACHED[S5]}" "decision:block did not reach the model; re-decide STRONG_CHANNEL" ;;
    *) fail "strong-channel-declared" "emit.js STRONG_CHANNEL unreadable: [$channel] (not implemented)" ;;
esac
case_end

echo "=== S7 PreToolUse deny: is_error on the tool_result, PostToolUse not run ==="
case_begin "pretooluse-deny-shape" "hooks/stop-sentinel-unapplied-notice.js"
S7="$(sid_of 07)"; MARK="$(np "$BASE/s7-posttooluse-ran")"
write_settings PreToolUse "$(hook S7 s7x2824)" PostToolUse "$(hook mark "$MARK")"
run_turn "$S7" "$PROMPT"
expect "S7-cli-exited-zero" "0" "${TURN_RC[$S7]}" "a timeout (124) or crash leaves no usable transcript"
tr7="$(transcript_of "$S7")"
probe7="$(node "$TURN_PROBE" --probe --needle "echo hello-2824" "$(np "$BASE/$S7.out")" ${tr7:+"$(np "$tr7")"} 2>/dev/null)"
expect "S7-denied-call-attempted" "true" "$(printf '%s\n' "$probe7" | sed -n 's/^attempted=//p')" "the model never tried the command"
expect "S7-tool-result-is-error" "true" "$(printf '%s\n' "$probe7" | sed -n 's/^result_error=//p')" \
    "a PreToolUse deny no longer marks tool_result is_error -- switch the backstop's exclusion to the deny text (detail plan Step 0 table)"
if [ -e "$BASE/s7-posttooluse-ran" ]; then
    fail "S7-posttooluse-not-run" "PostToolUse ran for a denied Bash call"
else
    pass "S7-posttooluse-not-run"
fi
echo "OBSERVED S7: attachments=[$(attachment_types "$S7")]"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
