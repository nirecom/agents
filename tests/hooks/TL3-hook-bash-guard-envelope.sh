#!/usr/bin/env bash
# Tests: hooks/bash-guard.js, hooks/lib/allow-command-list.js
# Tags: bash-guard, pre-tool-use, hook, permission-decision, envelope, TL3, run-e2e, scope:issue-specific, dup-group-keep:distinct-layer
# Live measurement of the PreToolUse envelope #2264 builds on, in a REAL permission flow:
# (b) the legacy {decision:"approve"} vs a silent exit 0; (c) how bash-guard's allow composes
# with a sibling hook's block; (a) whether a notify reaches the user (systemMessage) and the
# model (additionalContext). The TL2 suites feed bash-guard.js stdin directly, so they cannot
# see what the platform DOES with its output -- only a `claude -p` turn can.

set -uo pipefail

# TL3 gap (what even this file does NOT catch): an interactive session's dialog (here an
# `ask` is observed as the -p refusal it turns into), and hook ordering on hosts that run
# PreToolUse hooks differently from this CLI build. The day-to-day runners are the TL2
# suites tests/hooks/feature-2134-bash-guard.sh and feature-2265-allow-command-list.sh.
AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# --- skip gates (rules/test/claude-e2e.md acceptance criteria) ----------------
if [ ! -x "$AGENTS_DIR/bin/get-config-var" ]; then
    echo "SKIP: bin/get-config-var not found or not executable" >&2; exit 77
fi
if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then
    echo "SKIP: requires RUN_TL3=on in .env" >&2; exit 77
fi
if ! command -v claude >/dev/null 2>&1; then
    echo "SKIP: claude CLI not found" >&2; exit 77
fi

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- $2"; FAIL=$((FAIL + 1)); }
expect() { # <name> <want> <got> <why>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3] -- $4"; fi
}
# Label-only markers (tests/lib/harness.sh is not sourced): targets are for static grep.
case_begin() { :; }
case_end() { :; }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

STUBS="$AGENTS_DIR/tests/hooks/TL3-hook-bash-guard-envelope"
GUARD="$AGENTS_DIR/hooks/bash-guard.js"
PROBE="$AGENTS_DIR/tests/lib/tl3-turn-transcript.js"
AGENTS_M="$(node_path "$AGENTS_DIR")"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
REPO="$BASE/repo"; WFDIR="$BASE/workflow"; PLANSDIR="$BASE/plans"; MOCKBIN="$BASE/bin"
mkdir -p "$REPO/.claude" "$WFDIR" "$PLANSDIR" "$MOCKBIN"
git -C "$REPO" init -q
git -C "$REPO" config core.hooksPath /dev/null

# SAFETY: shadow `gh` so no turn can reach a remote.
printf '%s\n' '#!/usr/bin/env bash' 'echo "gh is disabled in this TL3 fixture" >&2' 'exit 1' > "$MOCKBIN/gh"
chmod +x "$MOCKBIN/gh"

# write_settings <hook-script>... : a minimal PreToolUse/Bash registration of exactly the
# given scripts and nothing else -- no permissions block (so an unlisted command asks) and
# no disableBypassPermissionsMode (rules/test/claude-e2e.md).
write_settings() {
    local hooks="" s
    for s in "$@"; do
        [ -n "$hooks" ] && hooks="$hooks,"
        hooks="$hooks{\"type\":\"command\",\"command\":\"node \\\"$(node_path "$s")\\\"\"}"
    done
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[%s]}]}}\n' "$hooks" > "$REPO/.claude/settings.json"
}

unset CLAUDECODE

# run_turn <session-uuid> <prompt> -- NO --dangerously-skip-permissions: with it, the
# permission decision under measurement would be unobservable. stream-json keeps every
# tool_use / tool_result record in the CLI output itself.
declare -A TURN_RC=()
run_turn() {
    local rc=0
    ( cd "$REPO" && \
      unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_ENV_FILE; \
      PATH="$MOCKBIN:$PATH" \
      CLAUDE_WORKFLOW_DIR="$WFDIR" WORKFLOW_PLANS_DIR="$PLANSDIR" \
      AGENTS_CONFIG_DIR="$AGENTS_M" \
      run_with_timeout 180 claude -p "$2" \
        --session-id "$1" \
        --setting-sources project \
        --output-format stream-json --verbose \
      >"$BASE/$1.out" 2>&1 ) || rc=$?
    TURN_RC["$1"]=$rc
}

# outcome <session> <needle> -> executed | refused | not-attempted | unobserved
# Two-valued on purpose (plan risk "TL3 probe environment"): the refusal wording varies by
# CLI build, so only "did the tool_result come back as an error" is judged.
outcome() {
    local out att err
    out="$(node "$PROBE" --probe --needle "$2" "$(node_path "$BASE/$1.out")" 2>/dev/null)"
    att="$(printf '%s\n' "$out" | sed -n 's/^attempted=//p')"
    err="$(printf '%s\n' "$out" | sed -n 's/^result_error=//p')"
    [ "$att" = "true" ] || { printf 'not-attempted'; return; }
    case "$err" in
        false) printf 'executed' ;;
        true)  printf 'refused' ;;
        *)     printf 'unobserved' ;;
    esac
}

# has_text <session> <needle> -> yes | no : anywhere in the raw stream of that turn.
has_text() { if grep -qF -- "$2" "$BASE/$1.out" 2>/dev/null; then printf 'yes'; else printf 'no'; fi; }

# has_system_message_field <session> <needle> -> yes | no : only a `systemMessage` field, at any
# depth of any stream record, counts. A string field that is itself JSON (a hook's raw stdout
# echoed into a record) is parsed and walked too, so the field is found in either shape.
has_system_message_field() {
    node -e '
      const fs = require("fs");
      const needle = process.argv[2];
      let t = "";
      try { t = fs.readFileSync(process.argv[1], "utf8"); } catch (e) { process.stdout.write("no"); process.exit(0); }
      const walk = (v, depth) => {
        if (depth > 64 || v === null) return false;
        if (typeof v === "string") {
          const s = v.trim();
          if (!s.startsWith("{") && !s.startsWith("[")) return false;
          try { return walk(JSON.parse(s), depth + 1); } catch (e) { return false; }
        }
        if (typeof v !== "object") return false;
        for (const [k, x] of Object.entries(v)) {
          if (k === "systemMessage" && typeof x === "string" && x.includes(needle)) return true;
          if (walk(x, depth + 1)) return true;
        }
        return false;
      };
      for (const l of t.split("\n")) {
        let o; try { o = JSON.parse(l); } catch (e) { continue; }
        if (walk(o, 0)) { process.stdout.write("yes"); process.exit(0); }
      }
      process.stdout.write("no");
    ' "$(node_path "$BASE/$1.out")" "$2" 2>/dev/null || printf 'no'
}

# final_result <session> -> the model's final answer text, from the stream's result record.
final_result() {
    node -e '
      const fs = require("fs");
      let t = "";
      try { t = fs.readFileSync(process.argv[1], "utf8"); } catch (e) { process.exit(0); }
      for (const l of t.split("\n")) {
        let o; try { o = JSON.parse(l); } catch (e) { continue; }
        if (o && o.type === "result" && typeof o.result === "string") process.stdout.write(o.result);
      }
    ' "$(node_path "$BASE/$1.out")" 2>/dev/null
}

cli_ok() { # <session> <label>
    expect "turn-$2-cli-exited-zero" "0" "${TURN_RC[$1]}" "a timeout (124) or CLI crash leaves the same trace as a refusal"
}

RUN_CMD_PROMPT="Using the Bash tool, run exactly this one command and report verbatim what happened:"
NO_RETRY="Do not rewrite it, do not use any other form, and do not retry with a different command if it is refused."

# =============================================================================
# (b) HARD GATE G-b -- legacy approve vs silence. `git --version` is outside every allow
# list and has no side effect. Expected branch (b1): BOTH refused, i.e. the legacy approve
# never bypassed the prompt, so passThrough may go silent without adding any prompt.
echo "=== (b) legacy approve vs silent exit 0 ==="
case_begin "probe-b-legacy-approve" "hooks/bash-guard.js"
B1="bbbbbbbb-2264-4000-8000-0000000000b1"
B2="bbbbbbbb-2264-4000-8000-0000000000b2"
write_settings "$STUBS/approve-stub.js"
run_turn "$B1" "$RUN_CMD_PROMPT git --version. $NO_RETRY"
write_settings "$STUBS/silent-stub.js"
run_turn "$B2" "$RUN_CMD_PROMPT git --version. $NO_RETRY"
cli_ok "$B1" B1
cli_ok "$B2" B2
expect "B2-silent-hook-leaves-the-prompt (fixture precondition)" "refused" "$(outcome "$B2" "git --version")" \
    "(b3) a silent hook did not end in the permission refusal -- the fixture grants the command some other way; fix the probe, do not implement"
expect "B1-legacy-approve-did-not-bypass-the-prompt (G-b)" "refused" "$(outcome "$B1" "git --version")" \
    "(b2) the legacy approve ran the command without a prompt -- Step 7's fallback envelope applies and the silence decision goes to the user"
case_end

# =============================================================================
# (c) HARD GATE G-c -- composition with a sibling block. The probe command is a real,
# read-only allow-list entry (bin/workflow-plans-dir only prints a path), so even a block
# that loses is harmless. The absolute spelling is used because the fixture cwd is not the
# agents root, where a relative spelling is never allowed.
echo ""
echo "=== (c) bash-guard allow vs a companion hook's block ==="
case_begin "probe-c-allow-composition" "hooks/lib/allow-command-list.js"
MARK="BG_PROBE_BLOCK_MARKER"
C_CMD="bash $AGENTS_M/bin/workflow-plans-dir $MARK"
C1="cccccccc-2264-4000-8000-0000000000c1"
C2="cccccccc-2264-4000-8000-0000000000c2"
C3="cccccccc-2264-4000-8000-0000000000c3"
if [ ! -f "$AGENTS_DIR/hooks/lib/allow-command-list.js" ]; then
    fail "C-precondition" "RED-EXPECTED -- hooks/lib/allow-command-list.js not found; the allow path is not implemented yet"
fi
write_settings "$GUARD"
run_turn "$C1" "$RUN_CMD_PROMPT $C_CMD $NO_RETRY"
write_settings "$STUBS/companion-blocker.js"
run_turn "$C2" "$RUN_CMD_PROMPT $C_CMD $NO_RETRY"
write_settings "$GUARD" "$STUBS/companion-blocker.js"
run_turn "$C3" "$RUN_CMD_PROMPT $C_CMD $NO_RETRY"
cli_ok "$C1" C1
cli_ok "$C2" C2
cli_ok "$C3" C3
expect "C1-bash-guard-allow-runs-the-entry-without-a-prompt (precondition)" "executed" "$(outcome "$C1" "$MARK")" \
    "(c3) bash-guard alone did not auto-approve a listed entry -- the allow path itself is not in effect"
expect "C2-companion-blocker-blocks (precondition)" "refused" "$(outcome "$C2" "$MARK")" \
    "(c3) the stand-in guard does not block on its own -- fix the stub before reading C3"
expect "C2-refusal-is-the-companion's" "yes" "$(has_text "$C2" "BG_PROBE_COMPANION_BLOCKED")" \
    "the refusal does not carry the stub's reason token, so it cannot be attributed to the block"
expect "C3-block-beats-allow (G-c)" "refused" "$(outcome "$C3" "$MARK")" \
    "(c2) bash-guard's allow overrode a sibling hook's block -- stop the allow output and the spelling removal, write a risk-signal"
case_end

# =============================================================================
# (a) notify channels. The L1 form is a bare sentinel issued AS a command: bash-guard's
# SENTINEL_NO_ECHO notify. systemMessage is the user-facing channel; additionalContext is
# judged by the model repeating the code it was handed. (a2) = only systemMessage arrives.
echo ""
echo "=== (a) notify: systemMessage and additionalContext ==="
case_begin "probe-a-notify-channels" "hooks/bash-guard.js"
A1="aaaaaaaa-2264-4000-8000-0000000000a1"
NOTIFY_CODE="BG-NOTIFY-SENTINEL-NO-ECHO"
write_settings "$GUARD"
run_turn "$A1" "Using the Bash tool, run exactly this one command: \"<<WORKFLOW_MARK_STEP_probe_complete>>\". $NO_RETRY Then answer with the full verbatim text of any additional context a hook gave you about that command, or NONE if there was none."
cli_ok "$A1" A1
expect "A-sentinel-command-was-attempted (precondition)" "yes" \
    "$( [ "$(outcome "$A1" "WORKFLOW_MARK_STEP_probe_complete")" = "not-attempted" ] && printf 'no' || printf 'yes')" \
    "the model never issued the sentinel, so neither channel below was exercised"
expect "A-systemMessage-carries-the-notify-code (a)" "yes" "$(has_system_message_field "$A1" "$NOTIFY_CODE")" \
    "no systemMessage field in the turn carries the notify code -- the user-facing channel did not fire"
expect "A-additionalContext-reaches-the-model (a1 vs a2)" "yes" \
    "$(final_result "$A1" | grep -qF -- "$NOTIFY_CODE" && printf 'yes' || printf 'no')" \
    "(a2) the model could not repeat the code -- send notify through systemMessage only"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
