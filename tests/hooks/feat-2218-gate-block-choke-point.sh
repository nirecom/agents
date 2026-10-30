#!/usr/bin/env bash
# tests/hooks/feat-2218-gate-block-choke-point.sh
# Tests: hooks/workflow-gate/handoff-record.js, hooks/workflow-gate.js
# Tags: workflow-gate, handoff, choke-point, gate-block, fail-open, regression-2218, state-handoff-record, regression-2652, regression-2578, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 10 — a blocked gate is exactly the kind of event that never survives a compaction, and workflow-gate.js has twelve call sites for it. Recording inside block() itself (round1-fix C7) is what makes "every block is remembered" true by construction instead of by twelve separate edits that drift apart.
# Issue #2652 (S2-3) moved the record into the session's state file as a state handoff record (class C, key gate:block, origin gate-block): a block before the workflow starts — no state file, or workflow_init not complete — is not recorded; a block after it is recorded even during NEXT_STEP_PAUSE (#2578); the block response itself never changes. hooks/lib/handoff-artifact.js left the Tests: line with the file; the writer it now reaches is covered by the js entry tests of hooks/lib/state-handoff-record.js.

# TL3 gap: a real PreToolUse dispatch from Claude Code, and the block sites that need a live git repo (unstaged / size / extraction), are not driven here — the scenarios below reach block() through the same choke point, which is what the recording depends on. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): the recording cases FAIL because block() still writes <sid>.control/handoff.md and nothing reaches the state file; C1's no-state half and C5 stay GREEN (they assert what must not happen).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
GATE="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate.js"

# isolation (#2512): pin state and plans dirs file-wide; the per-call pins below still override them.
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
mkdir -p "$_ISOLATION_TMP_ROOT/transcripts" "$_ISOLATION_TMP_ROOT/js"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$_ISOLATION_TMP_ROOT/transcripts")"
export AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")"
unset CLAUDE_CODE_SESSION_ID
cd "$_ISOLATION_TMP_ROOT" || exit 1
JS="$_ISOLATION_TMP_ROOT/js"

# seed.js <sid> [active|pending] — active: workflow_init complete; pending: the workflow has not started.
cat > "$JS/seed.js" <<'JS'
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const sid = process.argv[2];
S.writeState(sid, S.createInitialState(sid, { cwd: '/gate/fixture', git_branch: 'feature/gate' }));
if (process.argv[3] !== 'pending') S.markStep(sid, 'workflow_init', 'complete');
JS

# recs.js <sid> — the gate:block records as "<count>|<cls,origin,provenance per record>|<summaries in seq order>|<seq ascending>".
cat > "$JS/recs.js" <<'JS'
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
let raw = null;
try { raw = S.readRawState(process.argv[2]); } catch (e) { raw = null; }
const list = ((raw && raw.events) || []).filter((e) => e && e.kind === 'state_handoff_record' && e.record_key === 'gate:block');
const shape = [...new Set(list.map((e) => [e.cls, e.origin, e.provenance].join(',')))].join(';');
const asc = list.every((e, i) => i === 0 || e.seq > list[i - 1].seq);
process.stdout.write([list.length, shape, list.map((e) => e.summary).join(' / '), asc].join('|'));
JS

# pause.js <sid> — declare NEXT_STEP_PAUSE for the session's current step.
cat > "$JS/pause.js" <<'JS'
const A = process.env.AGENTS;
const sid = process.argv[2];
const step = require(A + '/hooks/workflow-state/current-step').resolveCurrentEffectiveStep(sid);
require(A + '/hooks/lib/next-step-pause-marker').writePauseMarker(sid, { reason: '[for=' + step + '] long-running fixture work' });
process.stdout.write('paused');
JS

# in_env <node-dir> <cmd...> — run a command against <node-dir>/wf with no ambient session id.
in_env() {
    local tn="$1"
    shift
    env -u CLAUDE_CODE_SESSION_ID ENFORCE_WORKTREE=off \
        WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 "$@"
}

seed_state() { in_env "$(np "$1")" node "$(np "$JS/seed.js")" "$2" "${3:-active}" >/dev/null 2>&1; }
count_entries() { in_env "$(np "$1")" node "$(np "$JS/recs.js")" "$2" 2>&1; }

# Drive the gate as Claude Code does: one hook input on stdin. tool_name Bash
# keeps runEarlyGate (Edit/Write only) out of the way, so the scenario reaches
# the block site the case is actually about. Sets GO (stdout), GE (stderr), GR (exit).
run_gate() {
    local tmp="$1" sid="$2" cmd="$3" tn
    tn="$(np "$tmp")"
    printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s","cwd":"%s"}}' "$sid" "$cmd" "$tn" > "$tmp/in.json"
    GO=$(in_env "$tn" node "$GATE" < "$tmp/in.json" 2>"$tmp/gate-err")
    GR=$?
    GE="$(cat "$tmp/gate-err" 2>/dev/null)"
}

new_fixture() { FT="$(make_tmp)"; mkdir -p "$FT/wf" "$FT/home"; }

CHAIN_CMD='echo \"<<WORKFLOW_RESEARCH_NOT_NEEDED: docs only>>\" && ls'

# blocked <label> — appends to $problems unless the last run_gate was a block with exit 0.
blocked() {
    [ "$GR" -eq 0 ] || problems="$problems $1-exit:$GR"
    case "$GO" in *'"decision":"block"'*) : ;; *) problems="$problems $1-not-blocked:'${GO:0:120}'" ;; esac
}

# C1 — the choke point, table driven. Block sites that need no git repo: the
# sentinel-chain guard and the merge gate with user_verification pending
# record once the workflow has started; the merge gate with no state file and
# a block before workflow_init completes still block but record nothing.
run_C1() {
    local problems="" n
    new_fixture
    seed_state "$FT" "chain-sid"
    seed_state "$FT" "uv-sid"
    seed_state "$FT" "early-sid" pending
    run_gate "$FT" "chain-sid" "$CHAIN_CMD"
    blocked sentinel-chain
    n="$(count_entries "$FT" "chain-sid")"
    [ "${n%%|*}" = "1" ] || problems="$problems sentinel-chain-records:'$n'"
    run_gate "$FT" "uv-sid" "gh pr merge 123 --squash"
    blocked merge-uv
    n="$(count_entries "$FT" "uv-sid")"
    [ "${n%%|*}" = "1" ] || problems="$problems merge-uv-records:'$n'"
    run_gate "$FT" "nostate-sid" "gh pr merge 123 --squash"
    blocked merge-nostate
    n="$(count_entries "$FT" "nostate-sid")"
    [ "${n%%|*}" = "0" ] || problems="$problems merge-nostate-recorded:'$n'"
    [ -e "$FT/wf/nostate-sid.json" ] && problems="$problems merge-nostate-created-a-state-file"
    run_gate "$FT" "early-sid" "$CHAIN_CMD"
    blocked before-init
    n="$(count_entries "$FT" "early-sid")"
    [ "${n%%|*}" = "0" ] || problems="$problems before-init-recorded:'$n'"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C1: two block sites each record one gate:block record after workflow_init; a block with no state file or before workflow_init still blocks and records nothing"
    else
        fail "C1: —$problems"
    fi
}

# C2 — one fixed key, append-only history (round2-fix C6). Two blocks with
# different reasons both belong under gate:block, class C, origin gate-block,
# in the order they happened. Showing only the newest is the state handoff reader's job.
run_C2() {
    local problems="" n
    new_fixture
    seed_state "$FT" "two-sid"
    run_gate "$FT" "two-sid" "$CHAIN_CMD"
    run_gate "$FT" "two-sid" "gh pr merge 77 --squash"
    n="$(count_entries "$FT" "two-sid")"
    case "$n" in
        "2|C,gate-block,observed|"*"|true") : ;;
        *) problems="$problems want-2-class-C-gate-block-records-in-seq-order-got:'$n'" ;;
    esac
    local summaries="${n#*|*|}"; summaries="${summaries%|*}"
    case "$summaries" in *" / "*) [ "${summaries%% / *}" != "${summaries##* / }" ] || problems="$problems two-reasons-share-one-summary" ;; esac
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C2: two different reasons append two class C gate-block records under the fixed key gate:block, oldest first"
    else
        fail "C2: —$problems"
    fi
}

# C3 — the same block twice is not news. noop-identical keeps a retry loop from
# filling the state file with one repeated record.
run_C3() {
    local problems="" n
    new_fixture
    seed_state "$FT" "same-sid"
    run_gate "$FT" "same-sid" "gh pr merge 55 --squash"
    run_gate "$FT" "same-sid" "gh pr merge 55 --squash"
    run_gate "$FT" "same-sid" "gh pr merge 55 --squash"
    blocked third-repeat
    n="$(count_entries "$FT" "same-sid")"
    [ "${n%%|*}" = "1" ] || problems="$problems repeated-identical-block-wrote:'$n'"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C3: an identical block repeated three times stays one record (noop-identical)"
    else
        fail "C3: —$problems"
    fi
}

# C4 — #2578: NEXT_STEP_PAUSE does not close the recording period. A block while
# paused is recorded, and its response matches the same block of an unpaused session.
run_C4() {
    local problems="" n paused ref_out ref_rc
    new_fixture
    seed_state "$FT" "ref-sid"
    seed_state "$FT" "pause-sid"
    # The sentinel-chain guard: the merge gate answers a paused session through
    # other checks, so only a block site that ignores PAUSE can be compared.
    run_gate "$FT" "ref-sid" "$CHAIN_CMD"
    ref_out="${GO//ref-sid/SID}"; ref_rc="$GR"
    paused="$(in_env "$(np "$FT")" node "$(np "$JS/pause.js")" "pause-sid" 2>&1)"
    [ "$paused" = "paused" ] || problems="$problems fixture-could-not-pause:'$paused'"
    run_gate "$FT" "pause-sid" "$CHAIN_CMD"
    blocked paused
    [ "$GR" = "$ref_rc" ] || problems="$problems exit-differs-while-paused:$GR/$ref_rc"
    [ "${GO//pause-sid/SID}" = "$ref_out" ] || problems="$problems response-differs-while-paused"
    n="$(count_entries "$FT" "pause-sid")"
    [ "${n%%|*}" = "1" ] || problems="$problems paused-block-records:'$n'"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C4: a block during NEXT_STEP_PAUSE is recorded and answers exactly as the unpaused block does"
    else
        fail "C4: —$problems"
    fi
}

# C5 — the parse-failure block fires BEFORE _gateReportCtx has a session id, so
# the recorder is called with undefined. It must neither crash the hook nor
# invent a state file under some placeholder name.
run_C5() {
    local problems="" files
    new_fixture
    printf 'this is not json' > "$FT/in.json"
    GO=$(in_env "$(np "$FT")" node "$GATE" < "$FT/in.json" 2>/dev/null)
    GR=$?
    blocked parse-failure
    files="$(find "$FT/wf" -type f 2>/dev/null)"
    [ -z "$files" ] || problems="$problems sessionless-block-created:'$files'"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C5: the sessionless parse-failure block still blocks, exits 0, and creates no state file"
    else
        fail "C5: —$problems"
    fi
}

# C6 — the invariant that makes this safe to put inside block(): a record that
# cannot be written must not change the verdict. A corrupt state file is the
# cheapest unwritable target now that the record lives in it; it stays untouched.
run_C6() {
    local problems=""
    new_fixture
    printf '{ not json' > "$FT/wf/corrupt-sid.json"
    run_gate "$FT" "corrupt-sid" "gh pr merge 99 --squash"
    blocked corrupt-state
    [ "$(cat "$FT/wf/corrupt-sid.json")" = "{ not json" ] || problems="$problems corrupt-state-file-rewritten"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C6: a record that cannot be written leaves the block verdict, the exit code, and the corrupt state file intact"
    else
        fail "C6: —$problems"
    fi
}

case_begin "block-sites-record-after-init" "hooks/workflow-gate/handoff-record.js"
run_C1
case_end

case_begin "fixed-key-keeps-history" "hooks/workflow-gate/handoff-record.js"
run_C2
case_end

case_begin "identical-block-recorded-once" "hooks/workflow-gate/handoff-record.js"
run_C3
case_end

case_begin "block-recorded-while-paused" "hooks/workflow-gate/handoff-record.js"
run_C4
case_end

case_begin "sessionless-block-creates-nothing" "hooks/workflow-gate.js"
run_C5
case_end

case_begin "failed-record-keeps-verdict" "hooks/workflow-gate.js"
run_C6
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
