#!/usr/bin/env bash
# Tests: hooks/preuse-auto-approve.js, hooks/preuse-auto-approve/scratchpad-script.js
# Tags: capture-echo-guard, scratchpad-allow, pre-tool-use, hook, hook-registration, TL3, run-e2e, scope:issue-specific
# Real-wiring seam test for the scratchpad auto-approve (PreToolUse, allow-only).
# The sibling TL2 files call isAllowedScratchpadInvocation directly, so they pass even
# if the hook is registered on the wrong event, under a matcher that misses Bash, or
# emits a decision shape Claude Code ignores. The observable that survives all three is
# a SIDE EFFECT under REAL permission handling: this session runs WITHOUT
# --dangerously-skip-permissions, so a command reaches the shell only when the hook
# really returned permissionDecision "allow" for it.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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
HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/preuse-auto-approve.js"
if [ ! -f "$HOOK" ]; then
    echo "FAIL: RED-EXPECTED — hooks/preuse-auto-approve.js not found" >&2; exit 1
fi

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
# Harness: provides pass/fail/skip/marker functions/run_with_timeout; overrides
# run_with_timeout with the canonical bin/run-with-timeout.sh portable wrapper.
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

REPO="$BASE/repo"; WFDIR="$BASE/workflow"; MOCKBIN="$BASE/bin"; MARKS="$BASE/marks"
# Dual-pin per rules/test/fixture-isolation.md.
PLANSDIR="$BASE/plans"
# The allowlist base is <os-tmpdir>/claude (hooks/lib/claude-scratchpad-base.js), and
# os.tmpdir() reads TMPDIR/TEMP/TMP — so pinning the temp dir for the session moves the
# whole base into this fixture. The session id below is the directory name, matching the
# real <base>/<project-slug>/<session-uuid>/scratchpad shape.
FTMP="$BASE/tmp"
SESSION="cccccccc-0000-4000-8000-000000000001"
SP="$FTMP/claude/c--fixture-project/$SESSION/scratchpad"
mkdir -p "$REPO/.claude" "$WFDIR" "$MOCKBIN" "$PLANSDIR" "$MARKS" "$SP"
git -C "$REPO" init -q
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# SAFETY: shadow `gh` so the session cannot reach any remote.
cat > "$MOCKBIN/gh" <<'GHMOCK'
#!/usr/bin/env bash
echo "gh is disabled in this TL3 fixture" >&2
exit 1
GHMOCK
chmod +x "$MOCKBIN/gh"

MARKS_M="$(node_path "$MARKS")"
SP_M="$(node_path "$SP")"
# A script inside the scratchpad, contained per path only. It records its own
# execution with `mkdir -p`.
printf 'echo hello from the scratchpad\nmkdir -p "%s/safe-ran"\n' "$MARKS_M" > "$SP/safe.sh"
# #2402 N2: the same containment, invoked with a literal argument.
# Records $1 so T2 can assert the model passed the arg, not just the script.
printf 'echo "hello from args, arg1=$1"\nmkdir -p "%s/args-ran"\nmkdir -p "%s/args-ran-$1"\n' "$MARKS_M" "$MARKS_M" > "$SP/args.sh"

# The fixture carries the REAL PreToolUse registration lifted out of the deployable
# settings.json (round 13, C9), so a matcher or event drift in the shipped artifact is
# what fails here. real-hook-entry.js is itself covered at TL2 by part6-settings.sh E-5.
ENTRY_DRV="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2170-capture-echo-guard/real-hook-entry.js"
node "$ENTRY_DRV" --emit "preuse-auto-approve.js" > "$REPO/.claude/settings.json"
if grep -q 'NOT_REGISTERED\|SETTINGS_UNREADABLE\|BAD_MODE' "$REPO/.claude/settings.json"; then
    echo "FAIL: preuse-auto-approve.js is not registered in the real settings.json" >&2
    exit 1
fi

# Isolation made visible rather than assumed: --emit reduces the entry to the single
# hook whose command carries the needle, so no sibling PreToolUse guard is registered
# here and none can author the refusal that a suspect-turn row would attribute to
# the auto-approve decision. Asserted, because that reduction lives in another file.
N_CMDS="$(grep -c '"command"[[:space:]]*:' "$REPO/.claude/settings.json")"
case_begin "fixture-registers-only-the-hook-under-test" "hooks/preuse-auto-approve.js"
if [ "$N_CMDS" = "1" ] && grep -q 'preuse-auto-approve\.js' "$REPO/.claude/settings.json"; then
    pass "fixture-registers-only-the-hook-under-test"
else
    fail "fixture-registers-only-the-hook-under-test" "the fixture settings.json carries $N_CMDS hook command(s) — another PreToolUse guard could produce the refusal this file attributes to the auto-approve decision"
fi
case_end

unset CLAUDECODE

# run_turn <session-uuid> <prompt>
# NOTE: no --dangerously-skip-permissions. That flag is what every other TL3 file uses,
# and it is exactly what must NOT be set here: with it, the hook's decision would be
# unobservable.
# The CLI's exit code is KEPT (round 13, C9): a timeout or CLI failure must not read
# the same as a hook that refused the command.
declare -A TURN_RC=()
run_turn() {
    local rc=0
    ( cd "$REPO" && \
      unset CLAUDE_CODE_SESSION_ID; \
      PATH="$MOCKBIN:$PATH" \
      TMPDIR="$FTMP" TEMP="$FTMP" TMP="$FTMP" \
      SCRATCHPAD="$SP_M" \
      WORKFLOW_STATE_DIR="$WFDIR" \
      WORKFLOW_PLANS_DIR="$PLANSDIR" \
      run_with_timeout 180 claude -p "$2" \
        --session-id "$1" \
        --setting-sources project \
        --output-format json \
      >"$BASE/$1.out" 2>&1 ) || rc=$?
    TURN_RC["$1"]=$rc
}

# One transcript reader for this file (CPR-SSOT): tests/lib/tl3-turn-transcript.js owns
# both the is_error read and the tool_use/tool_result probe below. Its own logic is
# verified against saved fixture transcripts by tests/tests/unit-tl3-turn-transcript.sh.
PROBE="$SCRIPT_CHECKOUT_ROOT/tests/lib/tl3-turn-transcript.js"

# is_error of a --output-format json transcript, or "unreadable".
turn_is_error() {
    node "$PROBE" --is-error "$(node_path "$BASE/$1.out")" 2>/dev/null || printf 'unreadable'
}

# Every file that can carry this turn's tool_use / tool_result records: the CLI's own
# --output-format json output holds the final result record, while the per-session
# transcript Claude Code writes under its agents main root holds the tool blocks. Both are
# handed over, so the attempt assertion does not depend on which shape this CLI emits.
turn_evidence() {
    local sid="$1" root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" f
    EVIDENCE=("$(node_path "$BASE/$sid.out")")
    [ -d "$root" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] && EVIDENCE+=("$(node_path "$f")")
    done < <(find "$root" -maxdepth 2 -type f -name "$sid.jsonl" 2>/dev/null)
}
# probe_turn <session> <needle> -> key=value lines
probe_turn() {
    turn_evidence "$1"
    node "$PROBE" --probe --needle "$2" "${EVIDENCE[@]}" 2>/dev/null
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

T1="cccccccc-0000-4000-8000-00000000000a"

echo "=== A: a safe scratchpad script is auto-approved and runs ==="
case_begin "T1-safe-script-auto-approved" "hooks/preuse-auto-approve/scratchpad-script.js"
run_turn "$T1" \
  "Using the Bash tool, run exactly this one command and report verbatim what happened: bash $SP_M/safe.sh. Do not rewrite it, do not use any other form, and do not retry with a different command if it is refused."

echo ""
echo "=== the assertion: the script actually reached the shell ==="
if [ -d "$MARKS/safe-ran" ]; then
    pass "safe-scratchpad-script-was-auto-approved"
else
    fail "safe-scratchpad-script-was-auto-approved" "the safe script never ran: the hook is not registered on PreToolUse, its matcher misses Bash, or its allow decision is not being honoured"
fi

if [ -s "$BASE/$T1.out" ]; then
    pass "turn-produced-output"
else
    fail "turn-produced-output" "the turn produced no output — the marker proves nothing"
fi

# Round 13, C9: a timed-out or crashed CLI leaves exactly the marker state a correct
# deny leaves, so the turn must be shown to have COMPLETED.
if [ "${TURN_RC[$T1]}" -eq 0 ]; then
    pass "turn-$T1-cli-exited-zero"
else
    fail "turn-$T1-cli-exited-zero" "claude -p exited ${TURN_RC[$T1]} (124 = the 180s timeout fired)"
fi
got="$(turn_is_error "$T1")"
if [ "$got" = "false" ]; then
    pass "turn-$T1-transcript-is_error-false"
else
    fail "turn-$T1-transcript-is_error-false" "is_error=$got"
fi

# Round 14, C8: an absent marker is also what a turn that never TRIED the script leaves
# behind — a model that paraphrased the prompt or reached for another tool satisfies
# every assertion above while proving nothing about the hook. The attribution this file
# needs is "attempted AND approved", which is what the allow decision means.
echo ""
echo "=== the attribution: attempted, and approved ==="
A_PROBE="$(probe_turn "$T1" "safe.sh")"

got="$(field "$A_PROBE" attempted)"
if [ "$got" = "true" ]; then
    pass "safe-turn-attempted-the-script"
else
    fail "safe-turn-attempted-the-script" "no Bash tool_use carrying safe.sh was found (attempted=$got)"
fi

got="$(field "$A_PROBE" result_error)"
if [ "$got" = "false" ]; then
    pass "safe-turn-attempt-was-approved"
else
    fail "safe-turn-attempt-was-approved" "result_error=$got — the safe script's own attempt was refused, so the allow decision is not being honoured"
fi

# The other direction of the new predicate: on the allowed turn no permission refusal
# may appear, or the predicate would be reporting the session rather than the decision.
got="$(field "$A_PROBE" permission_denial)"
if [ "$got" = "false" ]; then
    pass "safe-turn-attempt-is-not-a-permission-denial"
else
    fail "safe-turn-attempt-is-not-a-permission-denial" "permission_denial=$got — the allowed turn also hit the permission system, so a scratchpad path alone was not enough to auto-approve it"
fi
case_end

T2="cccccccc-0000-4000-8000-00000000000b"
echo ""
echo "=== B (#2402 N2): a scratchpad script with a literal argument is auto-approved ==="
case_begin "T2-literal-arg-auto-approved" "hooks/preuse-auto-approve/scratchpad-script.js"
run_turn "$T2" \
  "Using the Bash tool, run exactly this one command and report verbatim what happened: bash $SP_M/args.sh some_literal_arg. Do not rewrite it, do not use any other form, and do not retry with a different command if it is refused."

if [ -d "$MARKS/args-ran" ]; then
    pass "args-scratchpad-script-was-auto-approved"
else
    fail "args-scratchpad-script-was-auto-approved" "args.sh never ran: a literal argument still blocks the auto-approve"
fi
if [ -d "$MARKS/args-ran-some_literal_arg" ]; then
    pass "args-received-the-literal-arg"
else
    fail "args-received-the-literal-arg" "args.sh ran but \$1 was not 'some_literal_arg' — model may have omitted the argument or the hook stripped it"
fi
if [ "${TURN_RC[$T2]}" -eq 0 ]; then
    pass "turn-T2-cli-exited-zero"
else
    fail "turn-T2-cli-exited-zero" "claude -p exited ${TURN_RC[$T2]} (124 = the 180s timeout fired)"
fi
got="$(turn_is_error "$T2")"
if [ "$got" = "false" ]; then
    pass "turn-T2-transcript-is_error-false"
else
    fail "turn-T2-transcript-is_error-false" "is_error=$got"
fi
B_PROBE="$(probe_turn "$T2" "args.sh some_literal_arg")"
got="$(field "$B_PROBE" attempted)"
if [ "$got" = "true" ]; then
    pass "args-turn-attempted-the-script"
else
    fail "args-turn-attempted-the-script" "no Bash tool_use carrying args.sh was found (attempted=$got)"
fi
got="$(field "$B_PROBE" result_error)"
if [ "$got" = "false" ]; then
    pass "args-turn-attempt-was-approved"
else
    fail "args-turn-attempt-was-approved" "result_error=$got — the args.sh attempt was refused"
fi
got="$(field "$B_PROBE" permission_denial)"
if [ "$got" = "false" ]; then
    pass "args-turn-attempt-is-not-a-permission-denial"
else
    fail "args-turn-attempt-is-not-a-permission-denial" "permission_denial=$got — the argument turn hit the permission system"
fi
case_end

T3="cccccccc-0000-4000-8000-00000000000c"
echo ""
echo "=== C (#2402 N1): a /c/... drive-letter scratchpad path is auto-approved ==="
case_begin "T3-posix-path-auto-approved" "hooks/preuse-auto-approve/scratchpad-script.js"
if command -v cygpath >/dev/null 2>&1 && cygpath -u "C:/" 2>/dev/null | grep -q '^/c/'; then
    # Drive-letter form built by hand: `cygpath -u` yields the /tmp mount alias here.
    SP_DRIVE="${SP_M%%:*}"
    SP_POSIX="/${SP_DRIVE,,}${SP_M#?:}"
    printf 'mkdir -p "%s/posix-ran"\n' "$MARKS_M" > "$SP/posix.sh"
    # Definition inside span: deleting this span leaves no orphaned run_turn_posix definition.
    # /c/... SCRATCHPAD. MSYS2_ENV_CONV_EXCL keeps Git Bash from rewriting it to C:/...
    # on the way into claude (MSYS_NO_PATHCONV suppresses all path conversion here).
    run_turn_posix() {
        local rc=0
        ( cd "$REPO" && \
          unset CLAUDE_CODE_SESSION_ID; \
          PATH="$MOCKBIN:$PATH" \
          TMPDIR="$FTMP" TEMP="$FTMP" TMP="$FTMP" \
          MSYS_NO_PATHCONV=1 \
          MSYS2_ENV_CONV_EXCL=SCRATCHPAD \
          SCRATCHPAD="$3" \
          WORKFLOW_STATE_DIR="$WFDIR" \
          WORKFLOW_PLANS_DIR="$PLANSDIR" \
          run_with_timeout 180 claude -p "$2" \
            --session-id "$1" \
            --setting-sources project \
            --output-format json \
          >"$BASE/$1.out" 2>&1 ) || rc=$?
        TURN_RC["$1"]=$rc
    }
    run_turn_posix "$T3" "Using the Bash tool, run exactly this one command and report verbatim what happened: bash $SP_POSIX/posix.sh. Do not rewrite it, do not use any other form, and do not retry with a different command if it is refused." "$SP_POSIX"
    if [ -d "$MARKS/posix-ran" ]; then
        pass "posix-path-scratchpad-script-ran"
    else
        fail "posix-path-scratchpad-script-ran" "posix.sh was not executed — hook did not normalize the POSIX path"
    fi
    P3_PROBE="$(probe_turn "$T3" "$SP_POSIX/posix.sh")"
    got="$(field "$P3_PROBE" attempted)"
    if [ "$got" = "true" ]; then
        pass "posix-path-turn-attempted-the-script"
    else
        fail "posix-path-turn-attempted-the-script" "no Bash tool_use carrying posix.sh was found (attempted=$got)"
    fi
    got="$(field "$P3_PROBE" result_error)"
    if [ "$got" = "false" ]; then
        pass "posix-path-turn-attempt-was-approved"
    else
        fail "posix-path-turn-attempt-was-approved" "result_error=$got — the POSIX-path script's attempt was refused"
    fi
    got="$(field "$P3_PROBE" permission_denial)"
    if [ "$got" = "false" ]; then
        pass "posix-path-turn-is-not-a-permission-denial"
    else
        fail "posix-path-turn-is-not-a-permission-denial" "permission_denial=$got — hook did not auto-approve the POSIX-path command"
    fi
else
    echo "SKIP T3 (POSIX path): MSYS-form cygpath not available"
fi
case_end

echo ""
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=${SKIP:-0}"
[ "$FAIL" -eq 0 ]
