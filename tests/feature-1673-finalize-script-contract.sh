#!/usr/bin/env bash
# tests/feature-1673-finalize-script-contract.sh
# Tests: skills/issue-close-finalize/scripts/run-loop-step.js, skills/issue-close-finalize/scripts/run-initial.sh, skills/issue-close-finalize/scripts/run-finalize-terminal.sh
# Tags: worker-dispatch, issue-close-finalize, kv-contract, argv-contract, idempotency, atomic-write, TL2, scope:issue-specific
#
# Issue #1673 — the three finalize scripts are the seam the new worker module
# spawns. This file pins THEIR side of the contract (argv arity, required env,
# the KEY=VALUE stdout shape, the state transitions and the g5_3a_completed
# idempotency guard) against the real scripts, independent of the worker.
#
# It is deliberately worker-free: if a later refactor of the worker changes what
# it passes, these assertions still describe what the scripts accept, so the
# mismatch surfaces here rather than as a silent no-op at close time.
#
# `step-g5-loop.sh` is replaced by a recording stub via FINALIZE_SCRIPTS_DIR —
# the real one talks to `gh`.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - The real step-g5-loop.sh / pre-flight.sh / gh behaviour behind the stub.
#   - run-initial.sh's happy path, which requires a real repo with a merged PR.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_F1673_SCRIPT_INNER:-}" ]; then
    _F1673_SCRIPT_INNER=1 timeout 300 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$AGENTS_DIR/skills/issue-close-finalize/scripts"
LOOP_STEP="$SCRIPTS_DIR/run-loop-step.js"
RUN_INITIAL="$SCRIPTS_DIR/run-initial.sh"
RUN_TERMINAL="$SCRIPTS_DIR/run-finalize-terminal.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

for f in "$LOOP_STEP" "$RUN_INITIAL" "$RUN_TERMINAL"; do
    [ -f "$f" ] || { fail "fixtures" "missing script: $f"; echo ""; echo "Total: PASS=$PASS FAIL=$FAIL"; exit 1; }
done

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/f1673-script-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

STUB_DIR="$TMPD/finalize-scripts"
mkdir -p "$STUB_DIR"
G5LOG="$TMPD/g5-calls.log"
cat > "$STUB_DIR/step-g5-loop.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$G5_CALL_LOG"
if [ "${1:-}" = "prepare" ]; then
    printf 'PROPOSAL_STATUS=ok\nPROPOSAL_PARENT=1500\n'
fi
exit 0
STUB
chmod +x "$STUB_DIR/step-g5-loop.sh"

STATE="$TMPD/state.json"
MKSTATE="$TMPD/mkstate.js"
cat > "$MKSTATE" <<'MKJS'
"use strict";
const fs = require("fs");
const [, , outFile, mutation] = process.argv;
const state = {
  schema_version: 3,
  root_issue_number: 1673,
  current_issue_number: 1673,
  owner_repo: "nirecom/agents",
  phase: "init_done",
  triage_action: "resume_e",
  g5_loop_iteration: 0,
  g5_history: [
    { iteration: 1, issue_number: "1673", proposal_status: "ok", proposal_parent: 1600,
      user_decision: null, g5_3a_completed: false, recursion_completed: false },
  ],
  proposal_counters: { accepted: 0, declined: 0, skipped: 0 },
};
if (mutation && mutation !== "-") new Function("s", mutation)(state);
fs.writeFileSync(outFile, JSON.stringify(state, null, 2));
MKJS

write_state() { node "$MKSTATE" "$STATE" "$1"; }
state_field() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=new Function("s","return "+process.argv[2])(s);process.stdout.write(String(v));' "$STATE" "$1"; }

LOUT=""
loop_step() {
    : > "$G5LOG"
    LOUT="$(run_with_timeout 60 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "FINALIZE_SCRIPTS_DIR=$STUB_DIR" \
        "G5_CALL_LOG=$G5LOG" \
        node "$LOOP_STEP" "$STATE" "$1" 2>&1)"
}
kv_of() { printf '%s\n' "$LOUT" | sed -n "s/^$1=//p" | head -1; }
g5_calls() { grep -c '' "$G5LOG" 2>/dev/null | tr -d ' '; }

# ===========================================================================
# Group 1 — decline / llm_declined go straight to terminal, no child work
# ===========================================================================
group_decline() {
    write_state "-"
    loop_step decline
    assert_eq "decline/status" "terminal" "$(kv_of STATUS)"
    assert_eq "decline/phase" "terminal" "$(state_field 's.phase')"
    assert_eq "decline/counter" "1" "$(state_field 's.proposal_counters.declined')"
    assert_eq "decline/user-decision" "decline" "$(state_field 's.g5_history[0].user_decision')"
    assert_eq "decline/no-g5-execute" "0" "$(g5_calls)"

    write_state "-"
    loop_step llm_declined
    assert_eq "llm-declined/status" "terminal" "$(kv_of STATUS)"
    assert_eq "llm-declined/user-decision" "llm_declined" "$(state_field 's.g5_history[0].user_decision')"
}

# ===========================================================================
# Group 2 — accept runs G.5-3a once, and the flag makes the rerun a no-op
# ===========================================================================
group_accept_idempotency() {
    write_state "-"
    loop_step accept
    assert_eq "accept/status" "awaiting_recursion" "$(kv_of STATUS)"
    assert_eq "accept/phase" "awaiting_recursion" "$(state_field 's.phase')"
    assert_eq "accept/g5-3a-completed" "true" "$(state_field 's.g5_history[0].g5_3a_completed')"
    assert_eq "accept/g5-called-once" "1" "$(g5_calls)"
    assert_eq "accept/g5-argv" "execute 1600 accept" "$(head -1 "$G5LOG")"

    # Second accept on the same state: the guard must suppress the child call.
    loop_step accept
    assert_eq "accept-again/status" "awaiting_recursion" "$(kv_of STATUS)"
    assert_eq "accept-again/no-second-g5-call" "0" "$(g5_calls)"
    assert_eq "accept-again/g5-3a-still-completed" "true" "$(state_field 's.g5_history[0].g5_3a_completed')"
}

# ===========================================================================
# Group 3 — recurse_done grows g5_history monotonically
# ===========================================================================
group_recurse() {
    write_state 's.g5_history[0].g5_3a_completed = true; s.phase = "awaiting_recursion";'
    loop_step recurse_done
    assert_eq "recurse/status" "init_done" "$(kv_of STATUS)"
    assert_eq "recurse/history-length" "2" "$(state_field 's.g5_history.length')"
    assert_eq "recurse/iteration" "1" "$(state_field 's.g5_loop_iteration')"
    assert_eq "recurse/new-entry-iteration" "1" "$(state_field 's.g5_history[1].iteration')"
    assert_eq "recurse/current-issue-advanced" "1600" "$(state_field 's.current_issue_number')"
    assert_eq "recurse/accepted-counter" "1" "$(state_field 's.proposal_counters.accepted')"
    assert_eq "recurse/recursion-completed" "true" "$(state_field 's.g5_history[0].recursion_completed')"
    # The new entry is seeded from the prepare stub's KV stdout, not from eval.
    assert_eq "recurse/new-proposal-parent" "1500" "$(state_field 's.g5_history[1].proposal_parent')"
    assert_eq "recurse/g5-prepare-argv" "prepare 1600" "$(head -1 "$G5LOG")"

    loop_step recurse_done
    assert_eq "recurse-twice/history-length" "3" "$(state_field 's.g5_history.length')"
    assert_eq "recurse-twice/iteration" "2" "$(state_field 's.g5_loop_iteration')"
}

# ===========================================================================
# Group 4 — rejects, and the atomic-write contract
# ===========================================================================
group_rejects() {
    write_state "-"
    loop_step not_a_decision
    assert_eq "unknown-decision/status" "failed" "$(kv_of STATUS)"
    assert_eq "unknown-decision/state-untouched" "init_done" "$(state_field 's.phase')"

    write_state 's.schema_version = 2;'
    loop_step accept
    assert_eq "schema-v2/status" "failed" "$(kv_of STATUS)"
    assert_eq "schema-v2/no-g5-call" "0" "$(g5_calls)"

    write_state 's.g5_history = [];'
    loop_step accept
    assert_eq "empty-history/status" "failed" "$(kv_of STATUS)"

    rm -f "$STATE"
    loop_step accept
    assert_eq "missing-state/status" "failed" "$(kv_of STATUS)"

    write_state "-"
    loop_step decline
    if [ -e "$STATE.tmp" ]; then
        fail "atomic-write/no-tmp-left-behind" "$STATE.tmp still exists"
    else
        pass "atomic-write/no-tmp-left-behind"
    fi
    # Exactly the two-line KV contract the worker parses.
    assert_eq "kv/line-count" "2" "$(printf '%s\n' "$LOUT" | grep -c '^[A-Z_][A-Z0-9_]*=')"
    assert_eq "kv/has-summary" "1" "$([ -n "$(kv_of SUMMARY)" ] && echo 1 || echo 0)"
    assert_eq "kv/exit0" "0" "$(run_with_timeout 60 env AGENTS_CONFIG_DIR="$AGENTS_DIR" FINALIZE_SCRIPTS_DIR="$STUB_DIR" G5_CALL_LOG="$G5LOG" node "$LOOP_STEP" "$STATE" decline >/dev/null 2>&1; echo $?)"
}

# ===========================================================================
# Group 5 — argv / env arity of the two bash scripts (fail-closed, non-zero)
# ===========================================================================
group_argv() {
    local rc
    rc=0; run_with_timeout 30 bash "$RUN_INITIAL" >/dev/null 2>&1 || rc=$?
    assert_eq "run-initial/no-args-rejected" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

    rc=0; run_with_timeout 30 env -u AGENTS_CONFIG_DIR -u FINALIZE_SCRIPTS_DIR -u MAIN_WORKTREE_PATH \
        bash "$RUN_INITIAL" 1673 1673 >/dev/null 2>&1 || rc=$?
    assert_eq "run-initial/missing-env-rejected" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

    rc=0; run_with_timeout 30 bash "$RUN_TERMINAL" >/dev/null 2>&1 || rc=$?
    assert_eq "run-terminal/no-args-rejected" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

    rc=0; run_with_timeout 30 env -u AGENTS_CONFIG_DIR bash "$RUN_TERMINAL" "$STATE" sid "$TMPD/oc.json" >/dev/null 2>&1 || rc=$?
    assert_eq "run-terminal/missing-acd-rejected" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

    # run-finalize-terminal.sh exports ISSUE_CLOSE_SKILL itself — the dispatcher
    # must not have to (and must not) pass it through.
    if grep -q 'export ISSUE_CLOSE_SKILL=1' "$RUN_TERMINAL"; then
        pass "run-terminal/self-exports-issue-close-skill"
    else
        fail "run-terminal/self-exports-issue-close-skill" "export missing from run-finalize-terminal.sh"
    fi
}

group_decline
group_accept_idempotency
group_recurse
group_rejects
group_argv

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
