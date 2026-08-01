#!/usr/bin/env bash
# tests/feature-1673-finalize-state-validation.sh
# Tests: bin/worker-dispatch/workers/issue-close-finalize/state.js, bin/worker-dispatch/workers/issue-close-finalize.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, issue-close-finalize, state-file, untrusted-input, session-rebinding, security, TL2, scope:issue-specific
#
# Issue #1673 / D3 — the durable state file is a plain JSON file in PLANS_DIR and
# is therefore attacker-reachable, exactly like the payload. The LLM worker it
# replaces checked only `schema_version` and then fed `owner_repo`,
# `current_issue_number`, `triage_action` and `proposal_parent` straight into
# `gh`. A swapped state file was a swapped forge target.
#
# The property under test is not "an error is reported" — it is that NO CHILD
# PROCESS EVER STARTS for a non-conforming state. Reporting a failure after
# `gh issue close` ran against the wrong repo is worthless, so every row asserts
# the spawn counter is 0 as well as the status.
#
# Row (ok) is the non-vacuity control: with an untampered state and a matching
# binding record the same harness DOES reach the child. Without it, every reject
# row would also hold for a worker that never runs anything at all.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - A real `gh` mutation being avoided: the process seam is canned, so this
#     proves the child is not started, not that the forge is untouched.
#   - Concurrent sessions racing on one PLANS_DIR.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_F1673_STATE_INNER:-}" ]; then
    _F1673_STATE_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"

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
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$PRELOAD" ]; then
    fail "fixtures" "dispatcher=$DISPATCH_JS stub=$PRELOAD"
    echo ""; echo "Total: PASS=$PASS FAIL=$FAIL"; exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/f1673-state-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
ACD="$(nodepath "$AGENTS_DIR")"
SID="f1673state"
ROOT=1673
STATE_RAW="$PLANS_RAW/$SID-finalize-state-$ROOT.json"
BIND_RAW="$PLANS_RAW/$SID-finalize-binding-$ROOT.json"
STATE="$(nodepath "$STATE_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"

# --- fixture writers -------------------------------------------------------
MKSTATE="$TMPD/mkstate.js"
cat > "$MKSTATE" <<'MKJS'
"use strict";
const fs = require("fs");
const [, , outFile, kind, acd, mainPath, statePath, sid, mutation] = process.argv;
const state = {
  schema_version: 3,
  root_issue_number: 1673,
  current_issue_number: 1673,
  owner_repo: "nirecom/agents",
  agents_config_dir: acd,
  main_worktree_path: mainPath,
  merge_commit: "0123456789abcdef0123456789abcdef01234567",
  phase: "init_done",
  triage_action: "resume_e",
  g5_loop_iteration: 0,
  g5_history: [
    {
      iteration: 1,
      issue_number: "1673",
      proposal_status: "ok",
      proposal_parent: 1600,
      user_decision: null,
      g5_3a_completed: false,
      recursion_completed: false,
    },
  ],
  proposal_counters: { accepted: 0, declined: 0, skipped: 0 },
};
const binding = {
  session_id: sid,
  root_issue_number: 1673,
  owner_repo: "nirecom/agents",
  main_worktree_path: mainPath,
  state_file_path: statePath,
  created_at: "2026-07-30T00:00:00Z",
};
const obj = kind === "binding" ? binding : state;
if (mutation && mutation !== "-") new Function("s", mutation)(obj);
fs.writeFileSync(outFile, JSON.stringify(obj, null, 2));
MKJS

write_state()   { node "$MKSTATE" "$STATE_RAW" state   "$ACD" "$MAIN" "$STATE" "$SID" "$1"; }
write_binding() { node "$MKSTATE" "$BIND_RAW"  binding "$ACD" "$MAIN" "$STATE" "$SID" "$1"; }

DOUT=""; DRC=0
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}
call_count() { grep -c '' "$CALLLOG" 2>/dev/null | tr -d ' '; }

PAYLOAD_RAW="$PLANS_RAW/$SID-worker-issue-close-finalize-1.json"
printf '%s' "{\"phase\":\"loop_step\",\"root_issue_number\":$ROOT,\"owner_repo\":\"nirecom/agents\",\"state_file_path\":\"$STATE\",\"g5_decision\":\"accept\",\"session_id\":\"$SID\",\"artifact_dir\":\"$PLANS\"}" > "$PAYLOAD_RAW"
PAYLOAD="$(nodepath "$PAYLOAD_RAW")"

dispatch_loop_step() {
    printf '%s' '[{"stdout":"STATUS=awaiting_recursion\nSUMMARY=g5 accept: G.5-3a done, awaiting recursion\n"}]' > "$CANNED"
    : > "$CALLLOG"
    DRC=0
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
        "WD_SPAWN_MODULE=$(nodepath "$AGENTS_DIR/bin/worker-dispatch/spawn.js")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" \
        issue-close-finalize "$MAIN" "$PAYLOAD" 2>/dev/null)" || DRC=$?
}

# ===========================================================================
# Table: 1 control (ok) + the 8 D3 tamper variants
#   col1 name | col2 state mutation | col3 binding mutation | col4 expectation
#   binding mutation DELETE removes the binding record entirely.
# ===========================================================================
run_table() {
    local name smut bmut want
    while IFS='|' read -r name smut bmut want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        want="$(echo "$want" | xargs)"
        smut="${smut#"${smut%%[![:space:]]*}"}"; smut="${smut%"${smut##*[![:space:]]}"}"
        bmut="${bmut#"${bmut%%[![:space:]]*}"}"; bmut="${bmut%"${bmut##*[![:space:]]}"}"

        write_state "$smut"
        rm -f "$BIND_RAW"
        [ "$bmut" = "DELETE" ] || write_binding "$bmut"

        dispatch_loop_step
        assert_eq "$name/exit0" "0" "$DRC"
        if [ "$want" = "ok" ]; then
            # Pinned to the exact canned mapping, not merely "not failed": an
            # empty status would otherwise satisfy the control row too.
            assert_eq "$name/status" "awaiting_recursion" "$(field_of status)"
            assert_eq "$name/child-was-spawned" "1" "$([ "$(call_count)" -ge 1 ] && echo 1 || echo 0)"
            assert_eq "$name/child-is-run-loop-step" "1" \
                "$(grep -q 'runLoopStep' "$CALLLOG" && echo 1 || echo 0)"
        else
            assert_eq "$name/status" "failed" "$(field_of status)"
            assert_eq "$name/no-child-spawned" "0" "$(call_count)"
        fi
    done <<'TABLE'
control-untampered           | -                                              | -                                             | ok
a-schema-version-tampered    | s.schema_version = 2;                          | -                                             | failed
b-owner-repo-swapped         | s.owner_repo = "attacker/other-repo";          | -                                             | failed
c-root-issue-swapped         | s.root_issue_number = 9999;                    | -                                             | failed
d-current-issue-non-integer  | s.current_issue_number = "not-a-number";       | -                                             | failed
e-triage-action-unknown      | s.triage_action = "close_everything";          | -                                             | failed
f-proposal-parent-stringified| s.g5_history[0].proposal_parent = "1600";      | -                                             | failed
g-unknown-top-level-key      | s.exec_hook = "rm -rf /";                      | -                                             | failed
h1-binding-deleted           | -                                              | DELETE                                        | failed
h2-binding-cross-session     | -                                              | s.session_id = "someoneelsesession";          | failed
h3-binding-path-swapped      | -                                              | s.state_file_path = "/tmp/elsewhere.json";    | failed
h4-binding-owner-repo-swapped| -                                              | s.owner_repo = "attacker/other-repo";         | failed
TABLE
}

# ===========================================================================
# Extra: unknown key inside a g5_history element is refused the same way
# (CPR-5 — the top-level fail-closed rule has a symmetric member here)
# ===========================================================================
group_history_element() {
    write_state 's.g5_history[0].shell_command = "id";'
    write_binding "-"
    dispatch_loop_step
    assert_eq "g5-history-unknown-key/status" "failed" "$(field_of status)"
    assert_eq "g5-history-unknown-key/no-child-spawned" "0" "$(call_count)"

    write_state 's.g5_history[0].user_decision = "approve_all";'
    write_binding "-"
    dispatch_loop_step
    assert_eq "g5-history-bad-enum/status" "failed" "$(field_of status)"
    assert_eq "g5-history-bad-enum/no-child-spawned" "0" "$(call_count)"

    write_state 's.proposal_counters.accepted = -1;'
    write_binding "-"
    dispatch_loop_step
    assert_eq "proposal-counters-negative/status" "failed" "$(field_of status)"
    assert_eq "proposal-counters-negative/no-child-spawned" "0" "$(call_count)"

    # ACD / main-root in the state are echoes of anchors, not inputs: a value that
    # disagrees with the resolved anchor is a swapped checkout.
    write_state 's.agents_config_dir = "/tmp/not-the-acd";'
    write_binding "-"
    dispatch_loop_step
    assert_eq "acd-mismatch/status" "failed" "$(field_of status)"
    assert_eq "acd-mismatch/no-child-spawned" "0" "$(call_count)"

    # Malformed JSON is the degenerate case of the same rule.
    printf '%s' '{"schema_version": 3, ' > "$STATE_RAW"
    write_binding "-"
    dispatch_loop_step
    assert_eq "malformed-json/status" "failed" "$(field_of status)"
    assert_eq "malformed-json/no-child-spawned" "0" "$(call_count)"
}

run_table
group_history_element

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
