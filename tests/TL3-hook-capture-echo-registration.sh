#!/usr/bin/env bash
# Tests: hooks/block-capture-echo.js, settings.json
# Tags: capture-echo-guard, pre-tool-use, hook, hook-registration, security, TL3, run-e2e, scope:issue-specific
# Real-wiring seam test for block-capture-echo.js (PreToolUse). The sibling TL2 files
# assert the classifier verdict and the process contract; both still pass if the hook
# is registered on the wrong event, under a matcher that misses Bash, or if the
# harness ignores a "deny" for the tool. The observable that survives all three is a
# SIDE EFFECT: a blocked capture-then-echo never runs, so the marker file its target
# would have created is absent. Layer: TL3 (live claude -p, real PreToolUse dispatch).

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
HOOK="$AGENTS_DIR/hooks/block-capture-echo.js"
if [ ! -f "$HOOK" ]; then
    echo "FAIL: RED-EXPECTED — hooks/block-capture-echo.js not yet created" >&2; exit 1
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
mkdir -p "$REPO/.claude" "$WFDIR" "$MOCKBIN" "$PLANSDIR" "$MARKS"
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

# Two identical scripts differing only in the marker they touch. The capture-echo turn
# targets `captured.sh`; the control turn runs `control.sh` as a plain bare command.
MARKS_M="$(node_path "$MARKS")"
printf '#!/usr/bin/env bash\nprintf ran > "%s/captured"\nprintf value\n' "$MARKS_M" > "$REPO/captured.sh"
printf '#!/usr/bin/env bash\nprintf ran > "%s/control"\nprintf value\n' "$MARKS_M" > "$REPO/control.sh"
chmod +x "$REPO/captured.sh" "$REPO/control.sh"

# The fixture carries the REAL PreToolUse registration lifted out of the deployable
# settings.json (round 13, C9): a hand-written matcher would test this file's author,
# not the artifact that ships. real-hook-entry.js itself is covered at TL2 by
# tests/feature-2170-capture-echo-guard/part6-settings.sh E-5.
ENTRY_DRV="$AGENTS_DIR/tests/feature-2170-capture-echo-guard/real-hook-entry.js"
AGENTS_DIR="$AGENTS_DIR" node "$ENTRY_DRV" --emit "block-capture-echo.js" > "$REPO/.claude/settings.json"
if grep -q 'NOT_REGISTERED\|SETTINGS_UNREADABLE\|BAD_MODE' "$REPO/.claude/settings.json"; then
    echo "FAIL: block-capture-echo.js is not registered in the real settings.json" >&2
    exit 1
fi

unset CLAUDECODE

# run_turn <session-uuid> <prompt> — the CLI's exit code is KEPT (round 13, C9): a
# timeout or CLI failure must not be indistinguishable from a hook-refused turn.
declare -A TURN_RC=()
run_turn() {
    local rc=0
    ( cd "$REPO" && \
      PATH="$MOCKBIN:$PATH" \
      CLAUDE_WORKFLOW_DIR="$WFDIR" \
      WORKFLOW_PLANS_DIR="$PLANSDIR" \
      AGENTS_CONFIG_DIR="$(node_path "$AGENTS_DIR")" \
      run_with_timeout 180 claude -p "$2" \
        --session-id "$1" \
        --setting-sources project \
        --dangerously-skip-permissions \
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
# probe_turn <session> <needle> <marker> -> key=value lines
probe_turn() {
    turn_evidence "$1"
    node "$PROBE" --probe --needle "$2" --marker "$3" "${EVIDENCE[@]}" 2>/dev/null
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

T1="bbbbbbbb-0000-4000-8000-000000000001"
T2="bbbbbbbb-0000-4000-8000-000000000002"

echo "=== A: capture-then-echo must never reach the shell ==="
run_turn "$T1" \
  "Using the Bash tool, run exactly this one command and report verbatim what happened: OUTPUT=\$(bash ./captured.sh); echo \"\$OUTPUT\". Do not rewrite it into two commands, do not use any other form, and do not retry with a different command if it is refused."

echo "=== B: positive control — the same script as a bare command ==="
run_turn "$T2" \
  "Using the Bash tool, run exactly this one command and report what happened: bash ./control.sh"

echo ""
echo "=== the assertion: the blocked form left no side effect ==="
if [ -f "$MARKS/captured" ]; then
    fail "captured-script-never-ran" "the capture-then-echo command executed through a real session"
else
    pass "captured-script-never-ran"
fi

# Positive control: without it, an absent marker proves only that nothing ran at all —
# a broken harness and a working hook look identical.
if [ -f "$MARKS/control" ]; then
    pass "control-script-did-run"
else
    fail "control-script-did-run" "the bare command produced no side effect — the hook may be over-blocking, or Bash never dispatched, making the assertion above vacuous"
fi

if [ -s "$BASE/$T1.out" ] && [ -s "$BASE/$T2.out" ]; then
    pass "both-turns-produced-output"
else
    fail "both-turns-produced-output" "a turn produced no output — the missing marker proves nothing"
fi

# Round 13, C9: a timed-out or crashed CLI leaves the same absent marker as a hook that
# refused the command. Both turns must have COMPLETED for the assertion above to mean
# anything, so the exit code and the transcript's is_error flag are asserted explicitly.
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


# Round 14, C8: an absent marker is also what a turn that never TRIED the command
# leaves behind — a model that paraphrased the prompt, refused on its own, or reached
# for a different tool satisfies every assertion above while proving nothing about the
# hook. These two rows close that: the targeted command must appear as a real Bash
# tool_use, and its result must carry the capture guard's OWN wording, so the denial is
# attributable to hooks/block-capture-echo.js rather than to an error or a timeout.
echo ""
echo "=== the attribution: the command was attempted, and THIS guard refused it ==="
GUARD_MARK="Capture-then-display rejected"
A_PROBE="$(probe_turn "$T1" "captured.sh" "$GUARD_MARK")"
B_PROBE="$(probe_turn "$T2" "control.sh" "$GUARD_MARK")"

got="$(field "$A_PROBE" attempted)"
if [ "$got" = "true" ]; then
    pass "blocked-turn-attempted-the-command"
else
    fail "blocked-turn-attempted-the-command" "no Bash tool_use carrying ./captured.sh was found (attempted=$got) — the absent marker proves nothing about the hook"
fi

got="$(field "$A_PROBE" marker)"
if [ "$got" = "true" ]; then
    pass "blocked-turn-denial-is-the-capture-guards"
else
    fail "blocked-turn-denial-is-the-capture-guards" "the attempt's tool_result does not carry \"$GUARD_MARK\" (marker=$got) — the command may have failed for an unrelated reason"
fi

got="$(field "$A_PROBE" result_error)"
if [ "$got" = "true" ]; then
    pass "blocked-turn-attempt-result-is-an-error"
else
    fail "blocked-turn-attempt-result-is-an-error" "result_error=$got — a denied tool call must come back as an error result"
fi

# CPR-ORTH with TL3-hook-scratchpad-auto-approve.sh, which attributes a refusal to the
# permission system. This turn runs with --dangerously-skip-permissions, so a permission
# refusal here would mean the deny came from the prompt path and not from the guard —
# a second, independent way for the attribution above to be wrong.
got="$(field "$A_PROBE" permission_denial)"
if [ "$got" = "false" ]; then
    pass "blocked-turn-denial-is-not-a-permission-refusal"
else
    fail "blocked-turn-denial-is-not-a-permission-refusal" "permission_denial=$got — the refusal came from the permission system, not from the capture guard"
fi

# Both-direction control (CPR-ORTH): the positive-control turn must ALSO have attempted
# its command, and must NOT carry the guard's wording — otherwise a probe that answered
# "attributed" for every turn would satisfy the rows above.
got="$(field "$B_PROBE" attempted)"
if [ "$got" = "true" ]; then
    pass "control-turn-attempted-the-command"
else
    fail "control-turn-attempted-the-command" "no Bash tool_use carrying ./control.sh was found (attempted=$got)"
fi

got="$(field "$B_PROBE" marker)"
if [ "$got" = "false" ]; then
    pass "control-turn-not-refused-by-the-capture-guard"
else
    fail "control-turn-not-refused-by-the-capture-guard" "marker=$got — the bare command was refused by the capture guard, which is over-blocking"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
