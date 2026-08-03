#!/usr/bin/env bash
# tests/feature-1673-finalize-multipass.sh
# Tests: bin/worker-dispatch/workers/issue-close-finalize.js, bin/worker-dispatch/workers/issue-close-finalize/state.js, skills/issue-close-finalize/SKILL.md
# Tags: worker-dispatch, issue-close-finalize, multi-pass, state-machine, payload-seq, atomic-write, TL2, scope:issue-specific
#
# Issue #1673 — one dispatch advances exactly one pass. The loop, the LLM
# judgement and the AskUserQuestion stay in the calling main context; the
# dispatcher holds no memory between passes, so the durable state file is the
# only thing connecting them.
#
# Ported from tests/feature-644-agent-delegation/phase3-finalize-multipass.sh and
# phase3-state-file-contract.sh, which asserted the same contract against the
# agents/*.md prompt by grep. The contract is now executable, so it is asserted
# on behaviour instead of on prose.
#
# Groups 1-4 can the process seam (spawn-stub.js) so the argv each pass builds is
# recorded rather than inferred. Group 5 drops the stub and lets the REAL
# run-loop-step.js run: the `decline` branch is the one state transition that
# spawns no child of its own, so it is the one that can be exercised end-to-end
# without touching `gh`.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - The real run-initial.sh / run-finalize-terminal.sh, both of which call `gh`
#     against a live repo (covered at the single-seam tier by
#     tests/TL3-worker-dispatch-issue-close-finalize.sh).
#   - skills/issue-close-finalize/SKILL.md actually emitting -1/-2/-3 payloads in
#     a real session.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_F1673_MP_INNER:-}" ]; then
    _F1673_MP_INNER=1 timeout 420 bash "$0" "$@"
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
assert_has() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in *"$needle"*) pass "$name" ;; *) fail "$name" "want substring '$needle' in '$hay'" ;; esac
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

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/f1673-mp-$$")"
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
SID="f1673mp"
ROOT=1673
STATE_RAW="$PLANS_RAW/$SID-finalize-state-$ROOT.json"
BIND_RAW="$PLANS_RAW/$SID-finalize-binding-$ROOT.json"
STATE="$(nodepath "$STATE_RAW")"
OUTCOME="$PLANS/$SID-outcome.json"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"

DOUT=""; DRC=0
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}
call_count() { grep -c '' "$CALLLOG" 2>/dev/null | tr -d ' '; }
call_args()  { node -e 'const fs=require("fs");const t=fs.readFileSync(process.argv[1],"utf8").trim();if(t===""){process.stdout.write("(no-call)");process.exit(0);}const c=JSON.parse(t.split("\n")[0]);process.stdout.write([c.script||"",...c.args].join(" "));' "$(nodepath "$CALLLOG")"; }
sha_of()     { node -e 'const fs=require("fs"),c=require("crypto");try{process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));}catch(e){process.stdout.write("MISSING");}' "$1"; }
json_field() { node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(new Function("s","return "+process.argv[2])(s)));}catch(e){process.stdout.write("READ_ERROR");}' "$1" "$2"; }

# write_payload <seq> <json> → absolute payload path (never overwritten: WD-2 -<seq>)
write_payload() {
    local f="$PLANS_RAW/$SID-worker-issue-close-finalize-$1.json"
    printf '%s' "$2" > "$f"
    nodepath "$f"
}

# dispatch <payload-path> <canned-json> [preload:on|off]
dispatch() {
    printf '%s' "$2" > "$CANNED"
    : > "$CALLLOG"
    DRC=0
    if [ "${3:-on}" = "off" ]; then
        DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
            node "$(nodepath "$DISPATCH_JS")" issue-close-finalize "$MAIN" "$1" 2>/dev/null)" || DRC=$?
    else
        DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
            "WD_SPAWN_MODULE=$(nodepath "$AGENTS_DIR/bin/worker-dispatch/spawn.js")" \
            "WD_CANNED=$(nodepath "$CANNED")" \
            "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
            node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" \
            issue-close-finalize "$MAIN" "$1" 2>/dev/null)" || DRC=$?
    fi
}

INIT_KV='STATUS=init_done\nOWNER_REPO=nirecom/agents\nTRIAGE_ACTION=resume_e\nNEXT_STEPS=G,J\nPR_NUMBER=1711\nMERGE_COMMIT=a29ad788\nPROPOSAL_STATUS=ok\nPROPOSAL_PARENT=1600\nSUMMARY=init_done for #1673\n'
INITIAL_PAYLOAD="{\"phase\":\"initial\",\"issue_number\":$ROOT,\"root_issue_number\":$ROOT,\"owner_repo\":\"nirecom/agents\",\"state_file_path\":\"$STATE\",\"main_worktree_path\":\"$MAIN\",\"session_id\":\"$SID\",\"artifact_dir\":\"$PLANS\"}"

# ===========================================================================
# Group 1 — the initial pass writes the state file AND the binding record
# ===========================================================================
group_initial() {
    rm -f "$STATE_RAW" "$BIND_RAW"
    local p
    p="$(write_payload 1 "$INITIAL_PAYLOAD")"
    dispatch "$p" "[{\"stdout\":\"$INIT_KV\"}]"
    assert_eq "initial/exit0" "0" "$DRC"
    assert_eq "initial/status" "init_done" "$(field_of status)"
    assert_has "initial/child-is-run-initial" "runInitial" "$(call_args)"
    assert_has "initial/child-argv-issue-numbers" "1673 1673" "$(call_args)"

    assert_eq "initial/state-file-created" "1" "$([ -f "$STATE_RAW" ] && echo 1 || echo 0)"
    assert_eq "initial/schema-version" "3" "$(json_field "$STATE_RAW" 's.schema_version')"
    assert_eq "initial/phase" "init_done" "$(json_field "$STATE_RAW" 's.phase')"
    assert_eq "initial/owner-repo-from-child-stdout" "nirecom/agents" "$(json_field "$STATE_RAW" 's.owner_repo')"
    assert_eq "initial/triage-action" "resume_e" "$(json_field "$STATE_RAW" 's.triage_action')"
    assert_eq "initial/merge-commit" "a29ad788" "$(json_field "$STATE_RAW" 's.merge_commit')"
    assert_eq "initial/history-seeded" "1" "$(json_field "$STATE_RAW" 's.g5_history.length')"
    assert_eq "initial/proposal-parent-is-int" "number" "$(json_field "$STATE_RAW" 'typeof s.g5_history[0].proposal_parent')"
    assert_eq "initial/g5-3a-not-completed" "false" "$(json_field "$STATE_RAW" 's.g5_history[0].g5_3a_completed')"
    assert_eq "initial/loop-iteration-zero" "0" "$(json_field "$STATE_RAW" 's.g5_loop_iteration')"
    assert_eq "initial/no-tmp-left-behind" "0" "$([ -e "$STATE_RAW.tmp" ] && echo 1 || echo 0)"

    assert_eq "initial/binding-created" "1" "$([ -f "$BIND_RAW" ] && echo 1 || echo 0)"
    assert_eq "initial/binding-session" "$SID" "$(json_field "$BIND_RAW" 's.session_id')"
    assert_eq "initial/binding-root" "$ROOT" "$(json_field "$BIND_RAW" 's.root_issue_number')"
    assert_eq "initial/binding-owner-repo" "nirecom/agents" "$(json_field "$BIND_RAW" 's.owner_repo')"
    assert_eq "initial/binding-has-state-path" "1" "$([ "$(json_field "$BIND_RAW" 's.state_file_path')" != "READ_ERROR" ] && echo 1 || echo 0)"
    assert_eq "initial/binding-has-main-worktree" "1" "$([ "$(json_field "$BIND_RAW" 's.main_worktree_path')" != "READ_ERROR" ] && echo 1 || echo 0)"
}

# ===========================================================================
# Group 2 — the child's OWNER_REPO must agree with the payload's, or nothing
# is written at all (cross-repo mix-up detection)
# ===========================================================================
group_owner_mismatch() {
    rm -f "$STATE_RAW" "$BIND_RAW"
    local p kv
    kv='STATUS=init_done\nOWNER_REPO=someoneelse/other-repo\nTRIAGE_ACTION=resume_e\nNEXT_STEPS=G\nSUMMARY=init_done\n'
    p="$(write_payload 1b "$INITIAL_PAYLOAD")"
    dispatch "$p" "[{\"stdout\":\"$kv\"}]"
    assert_eq "owner-mismatch/status" "failed" "$(field_of status)"
    assert_eq "owner-mismatch/no-state-written" "0" "$([ -f "$STATE_RAW" ] && echo 1 || echo 0)"
    assert_eq "owner-mismatch/no-binding-written" "0" "$([ -f "$BIND_RAW" ] && echo 1 || echo 0)"
}

# ===========================================================================
# Group 3 — meta_pending_subs omits g5_history (existing contract preserved)
# ===========================================================================
group_meta_pending() {
    rm -f "$STATE_RAW" "$BIND_RAW"
    local p kv
    kv='STATUS=init_done\nOWNER_REPO=nirecom/agents\nTRIAGE_ACTION=meta_pending_subs\nNEXT_STEPS=\nSUMMARY=meta parent has open subs\n'
    p="$(write_payload 1c "$INITIAL_PAYLOAD")"
    dispatch "$p" "[{\"stdout\":\"$kv\"}]"
    assert_eq "meta/status" "init_done" "$(field_of status)"
    assert_eq "meta/triage-action" "meta_pending_subs" "$(json_field "$STATE_RAW" 's.triage_action')"
    assert_eq "meta/g5-history-omitted" "undefined" "$(json_field "$STATE_RAW" 'typeof s.g5_history')"
}

# ===========================================================================
# Group 4 — initial → loop_step ×2 → finalize_terminal, one pass per dispatch
# ===========================================================================
group_sequence() {
    rm -f "$STATE_RAW" "$BIND_RAW"
    local p1 p2 p3 p4 s1 s2 s3 h_before h_after
    p1="$(write_payload 1 "$INITIAL_PAYLOAD")"
    dispatch "$p1" "[{\"stdout\":\"$INIT_KV\"}]"
    assert_eq "seq/1-initial-status" "init_done" "$(field_of status)"
    s1="$(sha_of "$PLANS_RAW/$SID-worker-issue-close-finalize-1.json")"
    h_before="$(json_field "$STATE_RAW" 's.g5_history.length')"

    p2="$(write_payload 2 "{\"phase\":\"loop_step\",\"root_issue_number\":$ROOT,\"owner_repo\":\"nirecom/agents\",\"state_file_path\":\"$STATE\",\"g5_decision\":\"accept\",\"session_id\":\"$SID\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch "$p2" '[{"stdout":"STATUS=awaiting_recursion\nSUMMARY=g5 accept: G.5-3a done, awaiting recursion\n"}]'
    assert_eq "seq/2-loop-status" "awaiting_recursion" "$(field_of status)"
    assert_has "seq/2-child-is-run-loop-step" "runLoopStep" "$(call_args)"
    assert_has "seq/2-child-argv-decision" "accept" "$(call_args)"
    assert_eq "seq/2-one-child-only" "1" "$(call_count)"
    s2="$(sha_of "$PLANS_RAW/$SID-worker-issue-close-finalize-2.json")"

    # The real run-loop-step.js grows g5_history on recurse_done; the seam is
    # canned here, so the growth is applied to the fixture the same way before
    # the next pass reads it.
    node -e '
      const fs = require("fs");
      const p = process.argv[1];
      const s = JSON.parse(fs.readFileSync(p, "utf8"));
      s.g5_history[0].g5_3a_completed = true;
      s.g5_history[0].recursion_completed = true;
      s.g5_loop_iteration = 1;
      s.current_issue_number = 1600;
      s.g5_history.push({ iteration: 1, issue_number: "1600", proposal_status: "skipped",
        proposal_parent: null, user_decision: null, g5_3a_completed: false, recursion_completed: false });
      s.proposal_counters.accepted = 1;
      fs.writeFileSync(p, JSON.stringify(s, null, 2));
    ' "$STATE_RAW"
    h_after="$(json_field "$STATE_RAW" 's.g5_history.length')"
    assert_eq "seq/g5-history-monotonic" "1" "$([ "${h_after:-0}" -gt "${h_before:-0}" ] 2>/dev/null && echo 1 || echo 0)"

    p3="$(write_payload 3 "{\"phase\":\"loop_step\",\"root_issue_number\":$ROOT,\"owner_repo\":\"nirecom/agents\",\"state_file_path\":\"$STATE\",\"g5_decision\":\"recurse_done\",\"session_id\":\"$SID\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch "$p3" '[{"stdout":"STATUS=init_done\nSUMMARY=recurse_done: advanced to #1600\n"}]'
    assert_eq "seq/3-loop-status" "init_done" "$(field_of status)"
    s3="$(sha_of "$PLANS_RAW/$SID-worker-issue-close-finalize-3.json")"

    p4="$(write_payload 4 "{\"phase\":\"finalize_terminal\",\"root_issue_number\":$ROOT,\"owner_repo\":\"nirecom/agents\",\"state_file_path\":\"$STATE\",\"session_id\":\"$SID\",\"outcome_file_path\":\"$OUTCOME\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch "$p4" '[{"stdout":"STATUS=terminal\nSUMMARY=Steps H/I/J/K complete for #1600\n"}]'
    # STATUS=terminal from the script maps to `complete` in the worker contract.
    assert_eq "seq/4-terminal-status" "complete" "$(field_of status)"
    assert_has "seq/4-child-is-run-finalize-terminal" "runTerminal" "$(call_args)"
    assert_has "seq/4-child-argv-session-id" "$SID" "$(call_args)"
    assert_eq "seq/4-one-child-only" "1" "$(call_count)"

    # WD-2: each pass gets its own payload file; none is rewritten in place.
    assert_eq "seq/payload-1-unmodified" "$s1" "$(sha_of "$PLANS_RAW/$SID-worker-issue-close-finalize-1.json")"
    assert_eq "seq/payload-2-unmodified" "$s2" "$(sha_of "$PLANS_RAW/$SID-worker-issue-close-finalize-2.json")"
    assert_eq "seq/payload-3-unmodified" "$s3" "$(sha_of "$PLANS_RAW/$SID-worker-issue-close-finalize-3.json")"
    assert_eq "seq/payloads-are-distinct-files" "4" \
        "$(ls "$PLANS_RAW" | grep -c "^$SID-worker-issue-close-finalize-[1-4]\.json$")"
}

# ===========================================================================
# Group 5 — real seam: `decline` is the one transition with no child of its own,
# so the REAL run-loop-step.js runs here and the state transition is observed
# for real (atomic, no .tmp, phase advanced).
# ===========================================================================
group_real_decline() {
    rm -f "$STATE_RAW" "$BIND_RAW"
    local p
    p="$(write_payload 1 "$INITIAL_PAYLOAD")"
    dispatch "$p" "[{\"stdout\":\"$INIT_KV\"}]"
    if [ ! -f "$STATE_RAW" ] || [ ! -f "$BIND_RAW" ]; then
        fail "real-decline/prereq" "initial pass did not produce state+binding"
        return
    fi
    p="$(write_payload 5 "{\"phase\":\"loop_step\",\"root_issue_number\":$ROOT,\"owner_repo\":\"nirecom/agents\",\"state_file_path\":\"$STATE\",\"g5_decision\":\"decline\",\"session_id\":\"$SID\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch "$p" '[]' off
    assert_eq "real-decline/status" "terminal" "$(field_of status)"
    assert_eq "real-decline/phase-written" "terminal" "$(json_field "$STATE_RAW" 's.phase')"
    assert_eq "real-decline/declined-counter" "1" "$(json_field "$STATE_RAW" 's.proposal_counters.declined')"
    assert_eq "real-decline/no-tmp-left-behind" "0" "$([ -e "$STATE_RAW.tmp" ] && echo 1 || echo 0)"
}

group_initial
group_owner_mismatch
group_meta_pending
group_sequence
group_real_decline

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
