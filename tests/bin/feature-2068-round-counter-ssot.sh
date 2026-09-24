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

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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

# --- #2357 exit-9 gate for review-plan-security ---
# The #2276 fingerprint auto-clear lets a caller edit the plan to clear an exit-6
# marker and re-open a fresh 2+1 budget. The exit-9 gate must fire (keeping the
# marker) when PREV_RC==6 and no accept marker exists; an accept marker sanctions it.
echo ""
echo "--- ssot-P: #2357 exit-9 gate on review-plan-security ---"
SCRIPT_PLAN="$AGENTS_ROOT/skills/review-plan-security/scripts/run-codex-review-loop.sh"
RWT_PLAN="$AGENTS_ROOT/bin/run-with-timeout.sh"

# rps_fake — a config dir with only the two bin scripts the plan wrapper shells to.
rps_fake() {
    local fake; fake="$(mktemp -d)"
    mkdir -p "$fake/bin"
    printf '#!/usr/bin/env bash\nexit "${STUB_RC:-0}"\n' > "$fake/bin/run-codex-review-loop"
    printf '#!/usr/bin/env bash\necho /dev/null\nexit 0\n' > "$fake/bin/resolve-accepted-tradeoffs-file"
    chmod +x "$fake/bin/run-codex-review-loop" "$fake/bin/resolve-accepted-tradeoffs-file"
    printf '%s' "$fake"
}

# rps_plans — a plans dir seeded with the draft plan the wrapper fingerprints.
rps_plans() {
    local plans; plans="$(mktemp -d)"
    printf '# Detail plan v1\n' > "$plans/sid1361-detail.md"
    printf '%s' "$plans"
}

# run_loop_plan <plans> <fake> <stub_rc> → prints exit code (git hash-object needs no git CWD)
run_loop_plan() {
    local plans="$1" fake="$2" rc="$3" ec
    ( AGENTS_CONFIG_DIR="$fake" SESSION_ID="sid1361" PLANS_DIR="$plans" \
        EXTENSIONS_USED=0 STUB_RC="$rc" "$RWT_PLAN" 40 bash "$SCRIPT_PLAN" >/dev/null 2>&1 )
    ec=$?
    printf '%s' "$ec"
}

if command -v git >/dev/null 2>&1; then
    # (plan-a) exit 6 arm → plan change (fingerprint change) → exit 9, marker retained.
    {
        _p="$(rps_plans)"; _f="$(rps_fake)"
        _term="$_p/sid1361-security-plan-terminal.txt"
        run_loop_plan "$_p" "$_f" 6 >/dev/null            # arm exit-6 marker
        printf '# Detail plan v2 (edited)\n' > "$_p/sid1361-detail.md"   # flip fingerprint
        _rc="$(run_loop_plan "$_p" "$_f" 1)"
        if [ "$_rc" = "9" ] && [ -f "$_term" ]; then
            pass "(plan-a) exit-6 marker + plan change → exit 9, marker retained (bypass blocked)"
        else
            fail "(plan-a) RED-EXPECTED (exit-9 gate absent): rc=$_rc (want 9), marker present=$([ -f "$_term" ] && echo yes || echo no)"
        fi
        rm -rf "$_p" "$_f" 2>/dev/null || true
    }
    # (plan-b) exit 6 arm + accept marker → plan change → NOT exit 9 (sanctioned).
    {
        _p="$(rps_plans)"; _f="$(rps_fake)"
        _accept="$_p/sid1361-review-plan-security-exit6-accepted.txt"
        run_loop_plan "$_p" "$_f" 6 >/dev/null            # arm exit-6 marker
        printf 'accepted\n' > "$_accept"                  # sanction the residual HIGH
        printf '# Detail plan v2 (edited)\n' > "$_p/sid1361-detail.md"
        _term="$_p/sid1361-security-plan-terminal.txt"
        _rc="$(run_loop_plan "$_p" "$_f" 1)"
        if [ "$_rc" = "1" ] && [ ! -f "$_term" ]; then
            pass "(plan-b) exit-6 marker + accept file → rc=$_rc, marker deleted (guard stood down, accept path cleared marker)"
        elif [ "$_rc" = "1" ]; then
            fail "(plan-b) rc=1 but terminal marker was not deleted on accept path"
        else
            fail "(plan-b) accept file must let review through with rc=1 (got rc=$_rc, over-blocking or stub bypassed)"
        fi
        rm -rf "$_p" "$_f" 2>/dev/null || true
    }
    # (plan-c) PREV_RC=2 + plan change → NOT exit 9, marker auto-cleared (exit-9 gate is exit-6-specific).
    # Arm via real exit-2 run (arm_terminal_guard fires on 2|6|7), then change fingerprint.
    {
        _p="$(rps_plans)"; _f="$(rps_fake)"
        _term="$_p/sid1361-security-plan-terminal.txt"
        run_loop_plan "$_p" "$_f" 2 >/dev/null             # arm exit-2 marker
        if [ ! -f "$_term" ]; then
            fail "(plan-c-arm) exit-2 did not write terminal marker — setup failed"
            rm -rf "$_p" "$_f" 2>/dev/null || true
        else
            printf '# Detail plan v2 (edited)\n' > "$_p/sid1361-detail.md"  # fingerprint change
            _rc="$(run_loop_plan "$_p" "$_f" 1)"
            if [ "$_rc" != "9" ] && [ ! -f "$_term" ]; then
                pass "(plan-c) exit-2 arm + plan change → NOT exit 9, marker auto-cleared (rc=$_rc)"
            elif [ "$_rc" = "9" ]; then
                fail "(plan-c) exit-9 fired for non-exit-6 terminal (over-blocking): rc=$_rc"
            else
                fail "(plan-c) marker not deleted after auto-clear path (rc=$_rc)"
            fi
            rm -rf "$_p" "$_f" 2>/dev/null || true
        fi
    }
    # (plan-c2) PREV_RC=7 + plan change → NOT exit 9, marker auto-cleared.
    {
        _p="$(rps_plans)"; _f="$(rps_fake)"
        _term="$_p/sid1361-security-plan-terminal.txt"
        run_loop_plan "$_p" "$_f" 7 >/dev/null             # arm exit-7 marker
        if [ ! -f "$_term" ]; then
            fail "(plan-c2-arm) exit-7 did not write terminal marker — setup failed"
            rm -rf "$_p" "$_f" 2>/dev/null || true
        else
            printf '# Detail plan v2 (edited)\n' > "$_p/sid1361-detail.md"
            _rc="$(run_loop_plan "$_p" "$_f" 1)"
            if [ "$_rc" != "9" ] && [ ! -f "$_term" ]; then
                pass "(plan-c2) exit-7 arm + plan change → NOT exit 9, marker auto-cleared (rc=$_rc)"
            elif [ "$_rc" = "9" ]; then
                fail "(plan-c2) exit-9 fired for exit-7 terminal (over-blocking): rc=$_rc"
            else
                fail "(plan-c2) marker not deleted after auto-clear path (rc=$_rc)"
            fi
            rm -rf "$_p" "$_f" 2>/dev/null || true
        fi
    }
else
    echo "SKIP: (plan-a/plan-b) git unavailable — cannot exercise the plan-fingerprint seam"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
