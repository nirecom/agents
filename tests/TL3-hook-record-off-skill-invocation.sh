#!/usr/bin/env bash
# tests/TL3-hook-record-off-skill-invocation.sh
# Tests: hooks/record-off-skill-invocation.js, hooks/workflow-mark.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js
# Tags: off-clearance, emergency-off, provenance, hook, userpromptsubmit, posttooluse, TL3, run-e2e, scope:common
# The sibling TL2 feeds the recorder synthetic stdin, so it cannot show that the
# runtime fires UserPromptSubmit for a typed slash command at all, nor hands the
# hook that typed text (#1780 M-2). A live session shows both, the marker the
# real hook writes, and (turn C) the consumer reading it in the SAME turn.
# TL3 gap: `claude -p` delivers the prompt UNEXPANDED (measured), so the
# interactive client's <command-name> wrapper is unreachable here; that shape and
# the near-miss set are pinned by tests/enforce-off-emergency-provenance.sh P1.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- skip gates (claude-e2e.md acceptance criteria) --------------------------
if [ ! -x "$AGENTS_DIR/bin/get-config-var" ]; then
    echo "SKIP: bin/get-config-var not found or not executable" >&2; exit 77
fi
if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then
    echo "SKIP: requires RUN_TL3=on in .env" >&2; exit 77
fi
if ! command -v claude >/dev/null 2>&1; then
    echo "SKIP: claude CLI not found" >&2; exit 77
fi
HOOK="$AGENTS_DIR/hooks/record-off-skill-invocation.js"
if [ ! -f "$HOOK" ]; then
    echo "FAIL: hooks/record-off-skill-invocation.js missing - provenance is unrecorded" >&2; exit 1
fi
SKILL_SRC="$AGENTS_DIR/skills/enforce-workflow-off"
if [ ! -d "$SKILL_SRC" ]; then
    echo "FAIL: skills/enforce-workflow-off missing - the CLI would not register the slash command" >&2; exit 1
fi

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 - $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

BASE="$(mktemp -d)"
if [ -z "$BASE" ] || [ ! -d "$BASE" ]; then
    echo "FAIL: mktemp -d failed - refusing to derive fixture paths from an empty BASE" >&2; exit 1
fi
trap 'rm -rf "$BASE"' EXIT

# Dual-pin (rules/test/fixture-isolation.md): without WORKFLOW_PLANS_DIR the
# supervisor emitter still resolves the developer's real ~/.workflow-plans/.
REPO="$BASE/repo"; WFDIR="$BASE/workflow"; PLANSDIR="$BASE/plans"; MOCKBIN="$BASE/bin"
mkdir -p "$REPO/.claude/skills" "$WFDIR" "$PLANSDIR" "$MOCKBIN"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" config core.hooksPath /dev/null

# Required, not incidental: an unregistered command is never expanded, so without
# this copy the runtime would deliver bare text and the payload assertion below
# would be testing nothing.
cp -r "$SKILL_SRC" "$REPO/.claude/skills/enforce-workflow-off"

# SAFETY: shadow `gh` so the session cannot reach any remote.
cat > "$MOCKBIN/gh" <<'GHMOCK'
#!/usr/bin/env bash
echo "gh is disabled in this TL3 fixture" >&2
exit 1
GHMOCK
chmod +x "$MOCKBIN/gh"

SID="7a11bb22-cc33-dd44-ee55-66778899aa01"
SID2="7a11bb22-cc33-dd44-ee55-66778899aa02"
SID3="7a11bb22-cc33-dd44-ee55-66778899aa03"

# ASSEMBLED, never written literally: a test file carrying an emittable EMERGENCY
# sentinel would arm the real hook whenever it is read, pasted or grepped into a
# transcript (same discipline as tests/enforce-off-emergency-provenance.sh).
_S_OPEN="<<"; _S_CLOSE=">>"
EMERG_REASON="TL3 consumer seam check"
EMERG_CMD="echo \"${_S_OPEN}WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: ${EMERG_REASON}${_S_CLOSE}\""

# Derived from the SSOT, never spelled out: a renamed kind constant must break
# this test loudly rather than let the fixture drift into asserting a dead name.
MARKER_KIND=$(run_with_timeout 20 node -e \
    "process.stdout.write(require(process.argv[1]).EMERGENCY_PROVENANCE_MARKER_KIND)" \
    "$(node_path "$AGENTS_DIR/hooks/lib/protected-basenames.js")" 2>/dev/null)
if [ -z "$MARKER_KIND" ]; then
    echo "FAIL: EMERGENCY_PROVENANCE_MARKER_KIND not exported by hooks/lib/protected-basenames.js" >&2
    exit 1
fi
MARKER="$WFDIR/$SID.$MARKER_KIND"
MARKER2="$WFDIR/$SID2.$MARKER_KIND"
MARKER3="$WFDIR/$SID3.$MARKER_KIND"
# The CONSUMER-side artifacts: off-clearance.js writes the override marker into the
# workflow dir and appends the audit record via supervisor-state-writer, which
# resolves WORKFLOW_PLANS_DIR - a different directory, hence both are pinned.
OVERRIDE_MARKER3="$WFDIR/$SID3.workflow-off"
AUDIT3="$PLANSDIR/$SID3-supervisor-state.json"

PARTS_DIR="$AGENTS_DIR/tests/TL3-hook-record-off-skill-invocation"
# The capture wrapper, the Bash guard, the project settings.json that registers
# them next to the real consumer, and the environment the live turns run under.
# shellcheck source=./TL3-hook-record-off-skill-invocation/fixture-hooks.sh
. "$PARTS_DIR/fixture-hooks.sh"

# run_turn <session-id> <prompt> - one real `claude -p` turn in the fixture repo.
# The CLI's own status is kept in LAST_STATUS: a turn that died (timeout, crash,
# nested-session refusal) produces no marker either, so a discarded status would
# let a dead run masquerade as a clean negative result.
# Trailing args go to the CLI: the turns differ in WHICH TOOLS exist, and that is
# not cosmetic. `--tools ""` makes a producer-only turn deterministic - with the
# consumer registered below, a session free to run Bash may follow the skill it was
# handed, emit the OFF sentinel itself and consume its own marker, so the
# producer-only assertions would fail for a reason that is not a producer defect.
LAST_STATUS=0
run_turn() {
    local sid="$1" prompt="$2"; shift 2
    ( cd "$REPO" && \
      run_with_timeout 180 claude -p "$prompt" \
        --session-id "$sid" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format json \
        "$@" \
      >"$BASE/$sid.out" 2>&1 )
    LAST_STATUS=$?
    return 0
}
# assert_turn_ok <label> - the turn's CLI status, checked on its own terms.
assert_turn_ok() {
    if [ "$LAST_STATUS" -eq 0 ]; then pass "$1"
    else fail "$1" "claude -p exited $LAST_STATUS; the turn did not complete, so its side effects prove nothing: $(head -c 400 "$2" 2>/dev/null)"; fi
}
# assert_hook_fired_for <label> <session-id> - the capture file is appended by the
# wrapper on EVERY UserPromptSubmit, match or no match, so it is the independent
# signal that the hook infrastructure ran for this turn at all.
assert_hook_fired_for() {
    if [ -f "$CAPTURE" ] && grep -qF -- "\"session_id\":\"$2\"" "$CAPTURE"; then pass "$1"
    else fail "$1" "no captured UserPromptSubmit payload names session $2 - an absent marker for this turn would prove nothing"; fi
}
# assert_recorder_exit_clean <label> <session-id> - EVERY invocation the recorder
# made for this session ended on its own terms (exit 0, no signal, no spawn
# error). A crash that produced no marker is not the same claim as a hook that
# chose not to write one, and only this ledger separates them.
assert_recorder_exit_clean() {
    local total clean
    if [ ! -f "$STATUS" ]; then
        fail "$1" "no recorder status ledger at $STATUS - the wrapper never ran"; return
    fi
    total=$(grep -cF -- "\"sid\":\"$2\"" "$STATUS" 2>/dev/null)
    clean=$(grep -cF -- "\"sid\":\"$2\",\"status\":0,\"signal\":null,\"error\":null" "$STATUS" 2>/dev/null)
    if [ "${total:-0}" -gt 0 ] && [ "${total:-0}" = "${clean:-0}" ]; then pass "$1"
    else fail "$1" "recorder invocations for $2: ${total:-0} total, ${clean:-0} clean - $(grep -F -- "\"sid\":\"$2\"" "$STATUS" 2>/dev/null | head -c 400)"; fi
}

# shellcheck source=./TL3-hook-record-off-skill-invocation/cases-turn-a-invocation.sh
. "$PARTS_DIR/cases-turn-a-invocation.sh"
# shellcheck source=./TL3-hook-record-off-skill-invocation/cases-turn-b-negative-control.sh
. "$PARTS_DIR/cases-turn-b-negative-control.sh"
# shellcheck source=./TL3-hook-record-off-skill-invocation/cases-turn-c-consumption.sh
. "$PARTS_DIR/cases-turn-c-consumption.sh"

run_turn_A_invocation
run_production_command_fidelity
run_turn_B_negative_control
run_turn_C_consumption

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
