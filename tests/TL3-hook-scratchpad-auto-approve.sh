#!/usr/bin/env bash
# Tests: hooks/preuse-auto-approve.js, hooks/preuse-auto-approve/scratchpad-script.js, hooks/preuse-auto-approve/script-body-scan.js
# Tags: capture-echo-guard, scratchpad-allow, pre-tool-use, hook, hook-registration, script-body-scan, TL3, run-e2e, scope:issue-specific
# Real-wiring seam test for the scratchpad auto-approve (PreToolUse, allow-only).
# The sibling TL2 files call isAllowedScratchpadInvocation directly, so they pass even
# if the hook is registered on the wrong event, under a matcher that misses Bash, or
# emits a decision shape Claude Code ignores. The observable that survives all three is
# a SIDE EFFECT under REAL permission handling: this session runs WITHOUT
# --dangerously-skip-permissions, so a command reaches the shell only when the hook
# really returned permissionDecision "allow" for it.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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
HOOK="$AGENTS_DIR/hooks/preuse-auto-approve.js"
if [ ! -f "$HOOK" ]; then
    echo "FAIL: RED-EXPECTED — hooks/preuse-auto-approve.js not found" >&2; exit 1
fi

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

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
# Two scripts in the SAME scratchpad, differing only in whether their BODY is scannable
# as safe. Each records its own execution with `mkdir -p`, which the body scan clears —
# so the marker line never changes a script's verdict, only reports that it ran.
printf 'echo hello from the scratchpad\nmkdir -p "%s/safe-ran"\n' "$MARKS_M" > "$SP/safe.sh"
# The suspect line is an alternate-shell invocation of a path that does not exist: the
# scan must refuse the script on the SPELLING alone, and if the hook wrongly allows it,
# the failing line still lets the marker line below run — so the marker is present
# exactly when the wrong decision was made, and nothing harmful happens either way.
printf 'zsh /nonexistent/never-here.sh\nmkdir -p "%s/suspect-ran"\n' "$MARKS_M" > "$SP/suspect.sh"

# The fixture carries the REAL PreToolUse registration lifted out of the deployable
# settings.json (round 13, C9), so a matcher or event drift in the shipped artifact is
# what fails here. real-hook-entry.js is itself covered at TL2 by part6-settings.sh E-5.
ENTRY_DRV="$AGENTS_DIR/tests/feature-2170-capture-echo-guard/real-hook-entry.js"
AGENTS_DIR="$AGENTS_DIR" node "$ENTRY_DRV" --emit "preuse-auto-approve.js" > "$REPO/.claude/settings.json"
if grep -q 'NOT_REGISTERED\|SETTINGS_UNREADABLE\|BAD_MODE' "$REPO/.claude/settings.json"; then
    echo "FAIL: preuse-auto-approve.js is not registered in the real settings.json" >&2
    exit 1
fi

# Isolation made visible rather than assumed: --emit reduces the entry to the single
# hook whose command carries the needle, so no sibling PreToolUse guard is registered
# here and none can author the refusal that the suspect-turn row below attributes to
# the auto-approve decision. Asserted, because that reduction lives in another file.
N_CMDS="$(grep -c '"command"[[:space:]]*:' "$REPO/.claude/settings.json")"
if [ "$N_CMDS" = "1" ] && grep -q 'preuse-auto-approve\.js' "$REPO/.claude/settings.json"; then
    pass "fixture-registers-only-the-hook-under-test"
else
    fail "fixture-registers-only-the-hook-under-test" "the fixture settings.json carries $N_CMDS hook command(s) — another PreToolUse guard could produce the refusal this file attributes to the auto-approve decision"
fi

unset CLAUDECODE

# run_turn <session-uuid> <prompt>
# NOTE: no --dangerously-skip-permissions. That flag is what every other TL3 file uses,
# and it is exactly what must NOT be set here: with it, both turns would run and the
# hook's decision would be unobservable.
# The CLI's exit code is KEPT (round 13, C9): a timeout or CLI failure must not read
# the same as a hook that refused the command.
declare -A TURN_RC=()
run_turn() {
    local rc=0
    ( cd "$REPO" && \
      PATH="$MOCKBIN:$PATH" \
      TMPDIR="$FTMP" TEMP="$FTMP" TMP="$FTMP" \
      SCRATCHPAD="$SP_M" \
      CLAUDE_SESSION_ID="$SESSION" \
      CLAUDE_WORKFLOW_DIR="$WFDIR" \
      WORKFLOW_PLANS_DIR="$PLANSDIR" \
      AGENTS_CONFIG_DIR="$(node_path "$AGENTS_DIR")" \
      run_with_timeout 180 claude -p "$2" \
        --session-id "$1" \
        --setting-sources project \
        --output-format json \
      >"$BASE/$1.out" 2>&1 ) || rc=$?
    TURN_RC["$1"]=$rc
}

# One transcript reader for this file (CPR-SSOT): tests/lib/tl3-turn-transcript.js owns
# both the is_error read and the tool_use/tool_result probe below. Its own logic is
# verified against saved fixture transcripts by tests/unit-tl3-turn-transcript.sh.
PROBE="$AGENTS_DIR/tests/lib/tl3-turn-transcript.js"

# is_error of a --output-format json transcript, or "unreadable".
turn_is_error() {
    node "$PROBE" --is-error "$(node_path "$BASE/$1.out")" 2>/dev/null || printf 'unreadable'
}

# Every file that can carry this turn's tool_use / tool_result records: the CLI's own
# --output-format json output holds the final result record, while the per-session
# transcript Claude Code writes under its config dir holds the tool blocks. Both are
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
T2="cccccccc-0000-4000-8000-00000000000b"

echo "=== A: a safe scratchpad script is auto-approved and runs ==="
run_turn "$T1" \
  "Using the Bash tool, run exactly this one command and report verbatim what happened: bash $SP_M/safe.sh. Do not rewrite it, do not use any other form, and do not retry with a different command if it is refused."

echo "=== B: a scratchpad script whose body does not scan clean is not auto-approved ==="
run_turn "$T2" \
  "Using the Bash tool, run exactly this one command and report verbatim what happened: bash $SP_M/suspect.sh. Do not rewrite it, do not use any other form, and do not retry with a different command if it is refused."

echo ""
echo "=== the assertions: which script actually reached the shell ==="
# Positive control FIRST: without it, an absent suspect marker proves only that nothing
# ran at all — a hook that denies everything and a broken harness look identical.
if [ -d "$MARKS/safe-ran" ]; then
    pass "safe-scratchpad-script-was-auto-approved"
else
    fail "safe-scratchpad-script-was-auto-approved" "the safe script never ran: the hook is not registered on PreToolUse, its matcher misses Bash, or its allow decision is not being honoured"
fi

if [ -d "$MARKS/suspect-ran" ]; then
    fail "suspect-scratchpad-script-not-auto-approved" "the suspect script reached the shell — a scratchpad path alone was enough to auto-approve it"
else
    pass "suspect-scratchpad-script-not-auto-approved"
fi

if [ -s "$BASE/$T1.out" ] && [ -s "$BASE/$T2.out" ]; then
    pass "both-turns-produced-output"
else
    fail "both-turns-produced-output" "a turn produced no output — the markers prove nothing"
fi

# Round 13, C9: a timed-out or crashed CLI leaves exactly the marker state a correct
# deny leaves, so both turns must be shown to have COMPLETED. Turn B is expected to end
# with the tool refused, which is a completed turn, not a CLI error.
for t in "$T1" "$T2"; do
    if [ "${TURN_RC[$t]}" -eq 0 ]; then
        pass "turn-$t-cli-exited-zero"
    else
        fail "turn-$t-cli-exited-zero" "claude -p exited ${TURN_RC[$t]} (124 = the 180s timeout fired)"
    fi
    got="$(turn_is_error "$t")"
    if [ "$got" = "false" ]; then
        pass "turn-$t-transcript-is_error-false"
    else
        fail "turn-$t-transcript-is_error-false" "is_error=$got"
    fi
done


# Round 14, C8: an absent suspect marker is also what a turn that never TRIED the
# script leaves behind — a model that paraphrased the prompt or reached for another
# tool satisfies every assertion above while proving nothing about the hook. The
# attribution this file needs is "ATTEMPTED but NOT approved": the suspect script must
# appear as a real Bash tool_use, and that attempt must come back refused. Its twin on
# the safe turn is "attempted AND approved", which is what the allow decision means.
echo ""
echo "=== the attribution: attempted, and approved or not ==="
A_PROBE="$(probe_turn "$T1" "safe.sh")"
B_PROBE="$(probe_turn "$T2" "suspect.sh")"

got="$(field "$B_PROBE" attempted)"
if [ "$got" = "true" ]; then
    pass "suspect-turn-attempted-the-script"
else
    fail "suspect-turn-attempted-the-script" "no Bash tool_use carrying suspect.sh was found (attempted=$got) — the absent marker proves nothing about the hook"
fi

# `result_error=true` alone would be a false green: a script crash, a timeout, or a
# different guard's deny all raise that flag. This hook is allow-only, so the one
# outcome that is attributable to it NOT allowing is the permission system's own
# refusal — the turn runs without --dangerously-skip-permissions, so a call the hook
# declines to pre-approve falls through to a prompt no non-interactive session answers.
got="$(field "$B_PROBE" permission_denial)"
if [ "$got" = "true" ]; then
    pass "suspect-turn-attempt-was-not-approved"
else
    fail "suspect-turn-attempt-was-not-approved" "permission_denial=$got — no permission refusal is linked to the suspect attempt, so a scratchpad path alone was enough to auto-approve it"
fi

# Corollary of the row above, kept separate so a CLI that reworded its refusal fails
# only the attributing row and this one still reports whether the attempt errored.
got="$(field "$B_PROBE" result_error)"
if [ "$got" = "true" ]; then
    pass "suspect-turn-attempt-result-is-an-error"
else
    fail "suspect-turn-attempt-result-is-an-error" "result_error=$got — the suspect attempt came back successful"
fi

# Both-direction control (CPR-ORTH): the safe script must have been attempted too, and
# its attempt must have SUCCEEDED. Without it, a session that refused every tool call
# would satisfy the two rows above.
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
    fail "safe-turn-attempt-is-not-a-permission-denial" "permission_denial=$got — the allowed turn also hit the permission system, so the suspect-turn attribution cannot separate the two"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
