#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: codex-review-loop, round-counter, ssot, fail-closed, concurrency, TL2, scope:issue-specific
# Serial: allocates a round-counter lock directory and races two wrappers against it
#
# #2068: the round number was managed twice — each stage wrapper incremented its
# own file AND the shared wrapper took whatever --round it was handed. Two owners
# means the number can disagree with the rounds actually reviewed, which is how a
# HIGH round got scored as final. The counter now has one owner
# (bin/run-codex-review-loop); this suite pins that ownership.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
# shellcheck source=./lib/codex-loop-fixture.sh
. "$AGENTS_ROOT/tests/lib/codex-loop-fixture.sh"

# Fixture isolation (rules/test/fixture-isolation.md).
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
cd "$TMPDIR_BASE" || exit 1

ROOT="$TMPDIR_BASE/agents"
clf_make_root "$ROOT" "$AGENTS_ROOT"
clf_stub_reviewer "$ROOT"
STAGE_DETAIL="$AGENTS_ROOT/skills/make-detail-plan/scripts/run-codex-review-loop.sh"
FORMAT="detail-plan"

# rcs_env <name> — a plans dir named the way the detail stage wrapper expects,
# plus a per-case log of every --round the reviewer stub was handed.
RCS_P=""; RCS_SID=""; RCS_LOG=""
rcs_env() {
    RCS_SID="rcs$1"
    RCS_P="$TMPDIR_BASE/rcs-$1"
    RCS_LOG="$TMPDIR_BASE/rcs-$1-rounds.txt"
    mkdir -p "$RCS_P/workflow-state"
    printf '# Detail\n' > "$RCS_P/$RCS_SID-detail.md"
    printf '# Outline\n' > "$RCS_P/$RCS_SID-outline.md"
    : > "$RCS_LOG"
    export CLF_ROUND_LOG="$RCS_LOG"
}

# rcs_stage [extensions-used] — the real per-stage wrapper, which is the path a
# skill actually takes. Sets RCS_RC / RCS_OUT / RCS_ERR.
rcs_stage() {
    local errf="$TMPDIR_BASE/rcs-stage-err.txt"
    RCS_RC=0
    RCS_OUT="$(
        AGENTS_CONFIG_DIR="$ROOT" SESSION_ID="$RCS_SID" PLANS_DIR="$RCS_P" \
            EXTENSIONS_USED="${1:-0}" bash "$STAGE_DETAIL" 2>"$errf"
    )" || RCS_RC=$?
    RCS_ERR="$(cat "$errf" 2>/dev/null)"
}

# rcs_direct [args...] — the shared wrapper on its own, for the argument guards
# a stage wrapper has no way to express. Sets RCS_RC / RCS_OUT / RCS_ERR.
rcs_direct() {
    local errf="$TMPDIR_BASE/rcs-direct-err.txt"
    RCS_RC=0
    RCS_OUT="$(
        AGENTS_CONFIG_DIR="$ROOT" bash "$ROOT/bin/run-codex-review-loop" \
            --format "$FORMAT" --session-id "$RCS_SID" --plans-dir "$RCS_P" \
            --draft-file "$RCS_P/$RCS_SID-detail.md" \
            --accepted-tradeoffs "$RCS_P/$RCS_SID-outline.md" \
            --cap 2 --max-extensions 1 --extensions-used 0 "$@" 2>"$errf"
    )" || RCS_RC=$?
    RCS_ERR="$(cat "$errf" 2>/dev/null)"
}

rcs_counter() { clf_round_path "$RCS_P" "$RCS_SID" "$FORMAT"; }
rcs_last()    { clf_last_round_path "$RCS_P" "$RCS_SID" "$FORMAT"; }
rcs_delta()   { clf_delta_path "$RCS_P" "$RCS_SID" "$FORMAT" "$1" review-plan-codex; }
rcs_lock()    { printf '%s.lock' "$(rcs_counter)"; }

# rcs_rounds_seen — the round numbers the reviewer stub was handed, in order.
rcs_rounds_seen() { tr -d '\r' < "$RCS_LOG" | tr '\n' ' ' | sed 's/ *$//'; }

# rcs_delta_rounds — which round-numbered deltas exist, ascending. The names are
# the audit trail: one per round, never reused.
rcs_delta_rounds() {
    ls "$RCS_P" 2>/dev/null | sed -n "s/^$RCS_SID-$FORMAT-round-\([0-9]*\)-delta-.*/\1/p" \
        | sort -n | tr '\n' ' ' | sed 's/ *$//'
}

# rcs_seed <value> — put the counter directly into a state a case needs, since
# reaching round 3 through real reviews costs three subprocess rounds.
rcs_seed() { printf '%s\n' "$1" > "$(rcs_counter)"; }

# rcs_seed_delta <round> — a delta from a round that already happened.
rcs_seed_delta() { printf 'seeded round %s delta\n' "$1" > "$(rcs_delta "$1")"; }

. "$AGENTS_ROOT/tests/feature-2068-round-counter-ssot/counter-ownership.sh"
. "$AGENTS_ROOT/tests/feature-2068-round-counter-ssot/round-argument-guards.sh"
. "$AGENTS_ROOT/tests/feature-2068-round-counter-ssot/fail-close-and-concurrency.sh"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
