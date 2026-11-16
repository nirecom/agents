#!/usr/bin/env bash
# Tests: hooks/gate-reset-from-sentinel.js, settings.json
# Tags: TL3, run-e2e, hooks, pretooluse, reset-from, reset-allowance, permission, settings-registration, scope:issue-specific, pwsh-not-required, test-lang-exception:e2e
# The RESET_FROM PreToolUse hook copied from settings.json, in a REAL `claude -p` permission flow:
# (A) within the reset allowance the canonical echo runs with no prompt and PostToolUse records
# the reset, (B) with the allowance spent the hook asks, so the non-interactive turn refuses the
# echo with the hook's own reason and no reset is recorded. No no-hook control: the host
# auto-allows a read-only echo by itself, so a control could not refuse it.
set -uo pipefail

# TL3 gap (what even this file does NOT catch): runInTerminal / runCommands cannot be started from
# `claude -p`, and an interactive ask dialog is never shown here; the TL2
# tests/hooks/feature-2852-reset-from-gate.js covers the decision for every tool shape.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# isolation (rules/test/fixture-isolation.md): pin state and plans dirs once, at top level.
BASE="$(mktemp -d)"; readonly BASE
trap 'rm -rf "$BASE"' EXIT
harness_isolate "$BASE/iso"
unset CLAUDE_CODE_SESSION_ID

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
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

HELPERS="$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-reset-from-gate"
PROBE="$(node_path "$SCRIPT_CHECKOUT_ROOT/tests/lib/tl3-turn-transcript.js")"
SEED="$(node_path "$HELPERS/seed.js")"
AGENTS_M="$(node_path "$SCRIPT_CHECKOUT_ROOT")"
TIMEOUT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
NO_TRANSCRIPTS="$BASE/transcripts"; MOCKBIN="$BASE/bin"
mkdir -p "$NO_TRANSCRIPTS" "$MOCKBIN"

make_repo() { # <dir>
    mkdir -p "$1/.claude"
    git -C "$1" init -q
    git -C "$1" config core.hooksPath /dev/null
}
REPO="$BASE/repo"
make_repo "$REPO"

# SAFETY: shadow `gh` so no turn can reach a remote.
printf '%s\n' '#!/usr/bin/env bash' 'echo "gh is disabled in this TL3 fixture" >&2' 'exit 1' > "$MOCKBIN/gh"
chmod +x "$MOCKBIN/gh"

unset CLAUDECODE

seed() { "$TIMEOUT" 30 node "$SEED" --seed "$1" "$(node_path "$2")" "$3"; }
reset_reasons() { "$TIMEOUT" 30 node "$SEED" --reset-reasons "$1"; }
reset_count() { reset_reasons "$1" | grep -c . ; }
has_reason() { if reset_reasons "$1" | grep -qF -- "$2"; then printf 'yes'; else printf 'no'; fi; }

declare -A TURN_RC=()
run_turn() { # <session-uuid> <prompt>; no --dangerously-skip-permissions: the decision is measured
    local rc=0
    ( cd "$REPO" && \
      PATH="$MOCKBIN:$PATH" AGENTS_MAIN_ROOT="$AGENTS_M" CLAUDE_TRANSCRIPT_BASE_DIR="$NO_TRANSCRIPTS" \
      "$TIMEOUT" 180 claude -p "$2" \
        --session-id "$1" \
        --setting-sources project \
        --output-format stream-json --verbose \
      >"$BASE/$1.out" 2>&1 ) || rc=$?
    TURN_RC["$1"]=$rc
}
transcript_of() { find "$HOME/.claude/projects" -name "$1.jsonl" -type f 2>/dev/null | head -n 1; }
probe_key() { # <session> <needle> <key> [marker] -> the probe's value for <key>, stream and transcript
    local tr
    tr="$(transcript_of "$1")"
    node "$PROBE" --probe --needle "$2" ${4:+--marker "$4"} "$(node_path "$BASE/$1.out")" ${tr:+"$(node_path "$tr")"} 2>/dev/null | sed -n "s/^$3=//p"
}
outcome() { # <session> <needle> -> executed | refused | not-attempted | unobserved
    [ "$(probe_key "$1" "$2" attempted)" = "true" ] || { printf 'not-attempted'; return; }
    case "$(probe_key "$1" "$2" result_error)" in false) printf 'executed' ;; true) printf 'refused' ;; *) printf 'unobserved' ;; esac
}
cli_ok() { expect "turn-$2-cli-exited-zero" "0" "${TURN_RC[$1]}" "a timeout (124) or CLI crash leaves the same trace as a refusal"; }

NO_RETRY="Do not rewrite it, do not use any other form, and do not retry with a different command if it is refused."
sentinel_prompt() { # <reason>
    printf 'Using the Bash tool, run exactly this one command and report verbatim what happened: echo "<<WORKFLOW_RESET_FROM_write_code: %s>>" %s' "$1" "$NO_RETRY"
}
NEEDLE="WORKFLOW_RESET_FROM_write_code"
SA="eeeeeeee-2852-4000-8000-0000000000a1"
SB="eeeeeeee-2852-4000-8000-0000000000b1"
WHY_A="tl3 within allowance"; WHY_B="tl3 allowance spent"
ASK_MARKER="needs your approval"

case_begin "reset-from-gate-live" "hooks/gate-reset-from-sentinel.js"
COUNTS="$(node "$(node_path "$HELPERS/write-settings.js")" "$(node_path "$SCRIPT_CHECKOUT_ROOT/settings.json")" "$AGENTS_M" "$(node_path "$REPO/.claude/settings.json")")"
expect "settings-json-registers-the-gate-once (precondition)" "1" "${COUNTS%% *}" \
    "settings.json does not register hooks/gate-reset-from-sentinel.js on PreToolUse exactly once"
expect "settings-json-keeps-workflow-mark (precondition)" "yes" "$( [ "${COUNTS##* }" -ge 1 ] 2>/dev/null && printf 'yes' || printf 'no')" \
    "settings.json no longer registers hooks/workflow-mark.js on PostToolUse, so a reset could not be recorded"

seed "$SA" "$REPO" 0
seed "$SB" "$REPO" 2
expect "fixture-seeded (precondition)" "0 2" "$(reset_count "$SA") $(reset_count "$SB")" \
    "the fixture state files were not written with the intended reset history"

run_turn "$SA" "$(sentinel_prompt "$WHY_A")"
run_turn "$SB" "$(sentinel_prompt "$WHY_B")"
cli_ok "$SA" A
cli_ok "$SB" B

expect "A-echo-was-attempted (precondition)" "true" "$(probe_key "$SA" "$NEEDLE" attempted)" \
    "the model never issued the sentinel echo"
expect "A-echo-runs-without-a-prompt" "executed" "$(outcome "$SA" "$NEEDLE")" \
    "within the allowance the echo was refused or prompted -- the hook blocked a reset it should let through"
expect "A-reset-is-recorded" "yes" "$(has_reason "$SA" "$WHY_A")" \
    "the echo ran but PostToolUse workflow-mark did not record the reset"
expect "B-echo-was-attempted (precondition)" "true" "$(probe_key "$SB" "$NEEDLE" attempted)" \
    "the model never issued the sentinel echo, so the ask was not exercised"
expect "B-echo-is-refused-by-the-hook-ask" "true" "$(probe_key "$SB" "$NEEDLE" marker "$ASK_MARKER")" \
    "the spent-allowance echo's result does not carry the hook's ask reason -- the hook's ask did not reach the host"
expect "B-no-reset-is-recorded" "2 no" "$(reset_count "$SB") $(has_reason "$SB" "$WHY_B")" \
    "a reset was recorded although the hook asked in a non-interactive turn"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
