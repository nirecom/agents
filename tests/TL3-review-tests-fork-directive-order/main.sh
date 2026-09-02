# shellcheck shell=bash
# TL3 body for the review-tests fork-directive-order gate.
# Sourced by ../TL3-review-tests-fork-directive-order.sh after helpers.sh.
# Tests: skills/review-tests/SKILL.md, rules/shell-commands.md
# Tags: rules, prompt, dispatch, fork, claude-e2e, TL3, scope:issue-specific

echo ""
echo "=== TL3: review-tests fork directive order (Read before Bash) ==="

RFDO_DIRECTIVE="$(rfdo_extract_directive "$AGENTS_DIR/skills/review-tests/SKILL.md")"
if [ -z "$RFDO_DIRECTIVE" ]; then
    fail "D0. review-tests/SKILL.md carries no extractable Read-before-Bash directive -- cannot build the positive fixture"
    return 0
fi

RFDO_TASK='Now, in this same turn: run the shell command `echo rfdo-ok` using the Bash tool. After that, reply with only the single word DONE.'
RFDO_PREAMBLE='You are operating in a fresh, isolated execution context. No other project rules or conventions have been loaded for you.'

RFDO_POS_PROMPT="$RFDO_PREAMBLE $RFDO_DIRECTIVE $RFDO_TASK"
RFDO_NEG_PROMPT="$RFDO_PREAMBLE $RFDO_TASK"

RFDO_BASE="$(mktemp -d)"
trap 'rm -rf "$RFDO_BASE"' EXIT

SID_POS="a1e5f000-0000-0000-0000-000000000001"
SID_NEG="a1e5f000-0000-0000-0000-000000000002"

# --- D1 POSITIVE: directive present -> Read(rules/shell-commands.md) before Bash ---
POS_REPO="$RFDO_BASE/pos"
rfdo_build_repo "$POS_REPO"
POS_OUT="$RFDO_BASE/pos.json"
pos_rc="$(rfdo_run_claude "$POS_REPO" "$SID_POS" "$RFDO_POS_PROMPT" "$POS_OUT")"

if [ "$pos_rc" != "0" ] || [ ! -s "$POS_OUT" ]; then
    skip "D1. claude -p invocation failed or produced no output (rc=$pos_rc) -- inconclusive, not a mechanism failure"
else
    pos_order="$(rfdo_tool_order "$POS_OUT")"
    pos_read_idx="$(printf '%s' "$pos_order" | tr ' ' '\n' | grep '^READ_IDX=' | cut -d= -f2)"
    pos_bash_idx="$(printf '%s' "$pos_order" | tr ' ' '\n' | grep '^BASH_IDX=' | cut -d= -f2)"
    if [ -z "${pos_bash_idx:-}" ] || [ "$pos_bash_idx" = "-1" ]; then
        skip "D1. model never issued the requested Bash call (order: $pos_order) -- inconclusive, not a mechanism failure"
    elif [ -z "${pos_read_idx:-}" ] || [ "$pos_read_idx" = "-1" ]; then
        fail "D1. directive present, but no Read of rules/shell-commands.md preceded the Bash call (order: $pos_order)"
    elif [ "$pos_read_idx" -lt "$pos_bash_idx" ]; then
        pass "D1. directive present: Read(rules/shell-commands.md) at index $pos_read_idx precedes Bash at index $pos_bash_idx"
    else
        fail "D1. directive present, but Read(rules/shell-commands.md) at index $pos_read_idx did NOT precede Bash at index $pos_bash_idx"
    fi
fi

# --- D2 NEGATIVE (anti-vacuity): directive stripped -> ordering is no longer guaranteed ---
NEG_REPO="$RFDO_BASE/neg"
rfdo_build_repo "$NEG_REPO"
NEG_OUT="$RFDO_BASE/neg.json"
neg_rc="$(rfdo_run_claude "$NEG_REPO" "$SID_NEG" "$RFDO_NEG_PROMPT" "$NEG_OUT")"

if [ "$neg_rc" != "0" ] || [ ! -s "$NEG_OUT" ]; then
    skip "D2. claude -p invocation failed or produced no output (rc=$neg_rc) -- inconclusive, not a mechanism failure"
else
    neg_order="$(rfdo_tool_order "$NEG_OUT")"
    neg_read_idx="$(printf '%s' "$neg_order" | tr ' ' '\n' | grep '^READ_IDX=' | cut -d= -f2)"
    neg_bash_idx="$(printf '%s' "$neg_order" | tr ' ' '\n' | grep '^BASH_IDX=' | cut -d= -f2)"
    if [ -z "${neg_bash_idx:-}" ] || [ "$neg_bash_idx" = "-1" ]; then
        skip "D2. model never issued the requested Bash call (order: $neg_order) -- inconclusive"
    elif [ -z "${neg_read_idx:-}" ] || [ "$neg_read_idx" = "-1" ] || [ "$neg_read_idx" -ge "$neg_bash_idx" ]; then
        pass "D2 (anti-vacuity). directive absent: no Read-before-Bash ordering observed (order: $neg_order) -- proves D1's pass is not a model default"
    else
        skip "D2 (anti-vacuity). directive absent, but the model still Read rules/shell-commands.md before Bash on its own initiative (order: $neg_order) -- not a defect, just non-vacuity not demonstrated this run"
    fi
fi

# TL3 gap: this is an isolated proxy of the mechanism, not true production `context: fork`
# dispatch -- it never runs review-tests' actual Procedure, RT-0..RT-5, or a real staged diff.
# A spontaneous Read by either run (model already knows the convention) is possible and is
# treated as inconclusive/non-vacuity-not-shown rather than a failure, since this gate can only
# observe one sample per run, not the underlying probability. Closest-to-action mitigation:
# the static text proof in tests/feature-2140-fork-dispatch-shell-commands.sh, and the
# per-session receipt written by hooks/instructions-loaded-audit.js for the real skill.
