#!/usr/bin/env bash
# tests/hooks/feat-2218-handoff-artifact.sh
# Tests: bin/workflow/handoff-append
# Tags: handoff, handoff-artifact, plans-dir, append-only, latest-wins, regression-2218, state-handoff-record, state-file, overflow, regression-2652, scope:issue-specific, pwsh-not-required, TL2

# Issue #2218 Steps 1-2 — the procedure-point writer contract, driven through the real CLI subprocess against real files under a pinned state dir: a unit test with a mocked fs cannot catch an append that lands in the wrong file, an overflow that deletes history, or a CLI default that resolves wsid instead of sid (detail.md round1-fix C1/C6).
# Issue #2652 moved the record from <sid>.control/handoff.md into the session's own state file as `state_handoff_record` events, so every case reads the state file back. The module-level cases (gate-block / auto-record origins, lock-timeout, byte budget, concurrency) moved with hooks/lib/handoff-artifact.js to the js entry tests of hooks/lib/state-handoff-record.js (detail S1-4): a bash file may not carry a js module target (rules/test.md "Test Language"). Retired with the old file: H1 (getHandoffPath — no handoff.md path exists any more), H6 (markdown delimiter escaping — the record is a JSON event), H7 (handoff_schema_version — reading old handoff.md belongs to the state handoff reader's legacy part).

# TL3 gap: the skills that issue this CLI inside a live Claude Code session are not exercised here — only the CLI they all call. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

# TDD (write_code has not run): the record cases FAIL because the CLI still writes handoff.md, and H19 / H18 FAIL because flush is still accepted and the non-write reasons still print `WRITTEN=0 REASON=inactive`, until S2 is implemented.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

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

CLI="bin/workflow/handoff-append"
RESERVED_KEY="state-handoff:overflow"

# Fixture helpers: they read and seed the state file through state-io only, never through the writer.
cat > "$JS/pre.js" <<'JS'
const fs = require('fs');
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const seed = (sid) => {
  S.writeState(sid, S.createInitialState(sid, { cwd: '/work/fixture', git_branch: 'feature/h' }));
  S.markStep(sid, 'workflow_init', 'complete');
};
const seedPending = (sid) => S.writeState(sid, S.createInitialState(sid, { cwd: '/work/fixture', git_branch: 'feature/h' }));
const recs = (sid, key) => {
  let raw = null;
  try { raw = S.readRawState(sid); } catch (e) { return []; }
  return ((raw && raw.events) || []).filter((e) => e && e.kind === 'state_handoff_record' && (key === undefined || e.record_key === key));
};
// seedFull: an active session already holding n records, appended with contiguous seq as the writer would.
const seedFull = (sid, n) => {
  seed(sid);
  const p = S.getStatePath(sid);
  const st = JSON.parse(fs.readFileSync(p, 'utf8'));
  let seq = st.events.length;
  for (let i = 0; i < n; i++) {
    seq += 1;
    st.events.push({ kind: 'state_handoff_record', cls: 'A', at_step: 'write_code', record_key: 'k' + i,
      summary: 'entry number ' + i, pointer: '-', origin: 'procedure-point', provenance: 'declared',
      at: new Date(Date.UTC(2026, 0, 1, 0, 0, i)).toISOString(), seq });
  }
  fs.writeFileSync(p, JSON.stringify(st, null, 2));
};
module.exports = { fs, S, seed, seedPending, seedFull, recs };
JS

# seed.js <sid> [active|pending|full] — active: workflow_init complete; pending: not started; full: active + 300 records.
cat > "$JS/seed.js" <<'JS'
const P = require('./pre.js');
const mode = process.argv[3] || 'active';
if (mode === 'pending') P.seedPending(process.argv[2]);
else if (mode === 'full') P.seedFull(process.argv[2], 300);
else P.seed(process.argv[2]);
process.stdout.write('seeded');
JS

# recs.js <sid> [key] — "<count>" plus the newest record's fields.
cat > "$JS/recs.js" <<'JS'
const P = require('./pre.js');
const list = P.recs(process.argv[2], process.argv[3]);
const e = list[list.length - 1];
process.stdout.write(String(list.length) + (e ? '|' + [e.cls, e.at_step, e.origin, e.summary, e.pointer].join('|') : ''));
JS

# shape.js <sid> — every record carries the stored field set, and seq grows.
cat > "$JS/shape.js" <<'JS'
const P = require('./pre.js');
const list = P.recs(process.argv[2]);
const problems = [];
if (list.length !== 2) problems.push('record-count:' + list.length);
list.forEach((e, i) => {
  for (const f of ['cls', 'at_step', 'record_key', 'summary', 'pointer', 'origin']) if (typeof e[f] !== 'string') problems.push(f + '[' + i + ']:' + e[f]);
  if (e.provenance !== 'declared') problems.push('provenance[' + i + ']:' + e.provenance);
  if (typeof e.at !== 'string' || isNaN(Date.parse(e.at))) problems.push('at[' + i + ']:' + e.at);
  if (typeof e.seq !== 'number') problems.push('seq[' + i + ']:' + e.seq);
  if (e.step !== undefined || e.key !== undefined) problems.push('carries-step-or-key[' + i + ']');
});
if (list.length === 2 && !(list[1].seq > list[0].seq)) problems.push('seq-order');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
JS

# overflow.js <sid> — own records, reserved-key records (count:cls), and whether entry 0 survived.
cat > "$JS/overflow.js" <<'JS'
const P = require('./pre.js');
const all = P.recs(process.argv[2]);
const marks = all.filter((e) => e.record_key === 'state-handoff:overflow');
const own = all.filter((e) => e.record_key !== 'state-handoff:overflow');
process.stdout.write(own.length + '|' + marks.length + ':' + marks.map((e) => e.cls).join(',') + '|' + own.some((e) => e.summary === 'entry number 0'));
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
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 "$@"
}

# seed_active <node-dir> <sid> [mode] — the CLI writes only inside the recording period.
seed_active() { in_env "$1" node "$(np "$JS/seed.js")" "$2" "${3:-active}" >/dev/null 2>&1; }

# count_recs <node-dir> <sid> [key] — recs.js output for that state dir.
count_recs() { in_env "$1" node "$(np "$JS/recs.js")" "$2" ${3:+"$3"} 2>&1; }

# cli <node-dir> <tmp> <args...> — run the CLI; sets CO (stdout), CE (stderr), CR (exit), CN (non-blank stderr lines).
cli() {
    local tn="$1" tmp="$2"
    shift 2
    CO=$(in_env "$tn" node "$SCRIPT_CHECKOUT_ROOT/$CLI" "$@" 2>"$tmp/cli-err")
    CR=$?
    CE="$(cat "$tmp/cli-err" 2>/dev/null)"
    CN="$(printf '%s\n' "$CE" | grep -c '[^[:space:]]')"
}

# new_fixture — sets FT (tmp) / FN (node path) with an empty state and home dir.
new_fixture() { FT="$(make_tmp)"; FN="$(np "$FT")"; mkdir -p "$FT/wf" "$FT/home"; }

# H2 — a procedure-point call lands in the state file as a state_handoff_record
# event carrying the stored field set; no handoff.md appears anywhere.
run_H2() {
    local problems="" got shape md
    new_fixture
    seed_active "$FN" "sess-h2"
    cli "$FN" "$FT" --session sess-h2 --class D --step write_tests --key k0 --summary "observation 0" --pointer - --origin procedure-point
    [ "$CR" -eq 0 ] || problems="$problems [first call exit $CR: $CE]"
    case "$CO" in *"WRITTEN=1"*) : ;; *) problems="$problems [first call printed '${CO:-<empty>}']" ;; esac
    got="$(count_recs "$FN" "sess-h2" "k0")"
    [ "$got" = "1|D|write_tests|procedure-point|observation 0|-" ] || problems="$problems [record k0: '$got']"
    cli "$FN" "$FT" --session sess-h2 --class E --step - --key k1 --summary "observation 1" --pointer plans/x.md --origin procedure-point
    got="$(count_recs "$FN" "sess-h2" "k1")"
    [ "$got" = "1|E|-|procedure-point|observation 1|plans/x.md" ] || problems="$problems [record k1: '$got']"
    shape="$(in_env "$FN" node "$(np "$JS/shape.js")" "sess-h2" 2>&1)"
    [ "$shape" = "OK" ] || problems="$problems [$shape]"
    md="$(find "$FT" -name '*handoff.md' 2>/dev/null)"
    [ -z "$md" ] || problems="$problems [handoff.md written: $md]"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "H2: handoff-append records procedure-point entries in the state file (fields, declared provenance, at, growing seq) and writes no handoff.md"
    else
        fail "H2: —$problems"
    fi
}

# H3 — latest-wins (round1-fix C6) at the storage layer: the same key with
# DIFFERENT content keeps both records in order. Rendering only the newest
# belongs to renderStateHandoffForResume (the state handoff reader's tests).
run_H3() {
    local problems="" got
    new_fixture
    seed_active "$FN" "sess-h3"
    cli "$FN" "$FT" --session sess-h3 --class D --step run_tests --key run-tests:flaky --summary "first reason" --pointer - --origin procedure-point
    cli "$FN" "$FT" --session sess-h3 --class D --step run_tests --key run-tests:flaky --summary "second reason" --pointer - --origin procedure-point
    [ "$CR" -eq 0 ] || problems="$problems [second call exit $CR: $CE]"
    got="$(count_recs "$FN" "sess-h3" "run-tests:flaky")"
    [ "$got" = "2|D|run_tests|procedure-point|second reason|-" ] || problems="$problems [history: '$got', want 2 records with the second newest]"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "H3: two observations under one key are both kept in the state file, the later one last"
    else
        fail "H3: —$problems"
    fi
}

# H4 — noop-identical: a repeat identical to the previous record OF THE SAME cls
# is reported, not written; changed content and another cls both append.
run_H4() {
    local problems="" got
    new_fixture
    seed_active "$FN" "sess-h4"
    cli "$FN" "$FT" --session sess-h4 --class C --step review_tests --key rv --summary "same reason" --pointer - --origin procedure-point
    cli "$FN" "$FT" --session sess-h4 --class C --step review_tests --key rv --summary "same reason" --pointer - --origin procedure-point
    [ "$CR" -eq 0 ] || problems="$problems [repeat exit $CR]"
    [ "$CN" = "1" ] || problems="$problems [repeat stderr lines $CN]"
    case "$CO$CE" in *noop-identical*) : ;; *) problems="$problems [repeat names no noop-identical: '$CO$CE']" ;; esac
    got="$(count_recs "$FN" "sess-h4" "rv")"
    [ "${got%%|*}" = "1" ] || problems="$problems [repeat written: '$got']"
    cli "$FN" "$FT" --session sess-h4 --class C --step review_tests --key rv --summary "different reason" --pointer - --origin procedure-point
    cli "$FN" "$FT" --session sess-h4 --class D --step review_tests --key rv --summary "different reason" --pointer - --origin procedure-point
    got="$(count_recs "$FN" "sess-h4" "rv")"
    [ "$got" = "3|D|review_tests|procedure-point|different reason|-" ] || problems="$problems [changed content / other cls: '$got']"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "H4: an identical repeat is noop-identical (one stderr line, exit 0); changed content and another cls append"
    else
        fail "H4: —$problems"
    fi
}

# H5 — overflow. A session already at the 300-record budget refuses the next
# append, leaves exactly one record under the reserved key, deletes nothing,
# and the CLI says so on one stderr line with exit 0 — every time.
run_H5() {
    local problems="" got
    new_fixture
    seed_active "$FN" "sess-h5" full
    cli "$FN" "$FT" --session sess-h5 --class A --step write_code --key after-cap --summary s --pointer - --origin procedure-point
    [ "$CR" -eq 0 ] || problems="$problems [exit $CR]"
    [ "$CN" = "1" ] || problems="$problems [stderr lines $CN: '$CE']"
    case "$CO$CE" in *overflow*) : ;; *) problems="$problems [overflow not named: '$CO$CE']" ;; esac
    cli "$FN" "$FT" --session sess-h5 --class A --step write_code --key after-cap-2 --summary s --pointer - --origin procedure-point
    [ "$CR" -eq 0 ] || problems="$problems [second exit $CR]"
    got="$(in_env "$FN" node "$(np "$JS/overflow.js")" "sess-h5" 2>&1)"
    [ "$got" = "300|1:B|true" ] || problems="$problems [own|reserved:cls|entry0 = '$got', want '300|1:B|true']"
    cli "$FN" "$FT" --session sess-h5 --class B --step - --key "$RESERVED_KEY" --summary forged --pointer - --origin procedure-point
    case "$CO" in *"WRITTEN=1"*) problems="$problems [caller-supplied reserved key written]" ;; esac
    got="$(in_env "$FN" node "$(np "$JS/overflow.js")" "sess-h5" 2>&1)"
    [ "$got" = "300|1:B|true" ] || problems="$problems [after forged key: '$got']"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "H5: at the 300-record budget the CLI reports overflow on one stderr line with exit 0, one class B reserved-key record remains, nothing is deleted, and the reserved key cannot be forged"
    else
        fail "H5: —$problems"
    fi
}

# H8 — a corrupt state file and every invalid field are refused without a
# record (detail.md Risks #9/#10): the side-effect writer can never rewrite a
# file it cannot read or store an entry it should not.
run_H8() {
    local problems="" got row before after
    new_fixture
    mkdir -p "$FT/wf"
    printf '{ not json' > "$FT/wf/sess-h8-corrupt.json"
    cli "$FN" "$FT" --session sess-h8-corrupt --class A --step detail --key k --summary s --pointer - --origin procedure-point
    case "$CO" in *"WRITTEN=1"*) problems="$problems [corrupt state claimed written]" ;; esac
    [ "$(cat "$FT/wf/sess-h8-corrupt.json")" = "{ not json" ] || problems="$problems [corrupt state file rewritten]"
    seed_active "$FN" "sess-h8"
    for row in "--class Z" "--step not_a_step" "--key BAD_KEY_WITH SPACE" "--key $RESERVED_KEY"; do
        local flag="${row%% *}" val="${row#* }"
        local -a args=(--session sess-h8 --class A --step detail --key k --summary s --pointer - --origin procedure-point)
        local i
        for i in "${!args[@]}"; do [ "${args[$i]}" = "$flag" ] && args[i+1]="$val"; done
        cli "$FN" "$FT" "${args[@]}"
        case "$CO" in *"WRITTEN=1"*) problems="$problems [$flag '$val' written]" ;; esac
    done
    got="$(count_recs "$FN" "sess-h8")"
    [ "$got" = "0" ] || problems="$problems [invalid entries recorded: '$got']"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "H8: a corrupt state file is left as is, and an invalid class, step, key, or the reserved key records nothing"
    else
        fail "H8: —$problems"
    fi
}

# H9 — the CLI wrapper. --session defaults to resolveSessionId() (CC-native
# sid), NOT resolveWorkflowSessionId(): when the two diverge, a wsid default
# makes writer and reader look at different state files (round1-fix C1).
run_H9() {
    local out rc got decoy
    new_fixture
    # A decoy wsid: if the CLI defaulted to the plans-dir prefix heuristic it
    # would record under this session instead of the CC-native sid.
    printf '# decoy\n' > "$FT/wf/wsid-decoy-intent.md"
    seed_active "$FN" "wsid-decoy"
    seed_active "$FN" "cli-sid-h9"
    out=$(env CLAUDE_CODE_SESSION_ID="cli-sid-h9" \
        WORKFLOW_STATE_DIR="$FN/wf" WORKFLOW_PLANS_DIR="$FN/wf" \
        HOME="$FN/home" USERPROFILE="$FN/home" \
        "$RWT" 60 node "$SCRIPT_CHECKOUT_ROOT/$CLI" --class E --step write_tests --key write-tests:not-needed --summary "no test surface" --pointer - --origin procedure-point 2>&1)
    rc=$?
    got="$(count_recs "$FN" "cli-sid-h9" "write-tests:not-needed")"
    decoy="$(count_recs "$FN" "wsid-decoy")"
    if [ "$rc" -ne 0 ]; then
        fail "H9: CLI exited $rc (expected 0). Output: ${out:-<empty>}"
    elif [ "$got" != "1|E|write_tests|procedure-point|no test surface|-" ]; then
        fail "H9: expected one class E record in cli-sid-h9's state file, got '$got' (--session default must be resolveSessionId(), not wsid)"
    elif [ "$decoy" != "0" ]; then
        fail "H9: CLI recorded under the wsid decoy ('$decoy') — --session default resolved the wrong session id"
    else
        pass "H9: handoff-append defaults --session to the CC-native sid and records in that sid's state file"
    fi
    rm -rf "$FT" 2>/dev/null || true
}

# H10 — the CLI validates before it writes: an unknown --origin is rejected with
# a non-zero exit and the (recordable) session gains no record.
run_H10() {
    local got
    new_fixture
    seed_active "$FN" "cli-sid-h10"
    cli "$FN" "$FT" --session cli-sid-h10 --class E --step write_tests --key k --summary s --pointer - --origin bogus-origin
    got="$(count_recs "$FN" "cli-sid-h10")"
    if [ "$CR" -eq 0 ]; then
        fail "H10: CLI accepted --origin bogus-origin (expected non-zero exit). Output: ${CO:-<empty>}"
    elif [ "$got" != "0" ]; then
        fail "H10: CLI recorded '$got' despite rejecting the arguments"
    else
        pass "H10: handoff-append rejects an out-of-vocabulary --origin without recording"
    fi
    rm -rf "$FT" 2>/dev/null || true
}

# H11 — CLI-level path traversal (finding 2, CWE-22): a hostile --session value
# is rejected before any write; no file appears at a composed escaping path.
run_H11() {
    local parent
    new_fixture
    parent="$(dirname "$FT")"
    cli "$FN" "$FT" --session "../../evil" --class E --step write_tests --key k --summary s --pointer - --origin procedure-point
    if [ "$CR" -eq 0 ]; then
        fail "H11: CLI accepted a path-traversal --session (expected non-zero exit). Output: ${CO:-<empty>}"
    elif [ -e "$parent/evil.json" ] || [ -e "$FT/evil.json" ]; then
        fail "H11: CLI escaped the state dir and wrote evil.json"
    elif [ -n "$(find "$FT/wf" -type f 2>/dev/null)" ]; then
        fail "H11: CLI created a file inside the state dir despite the hostile --session"
    else
        pass "H11: handoff-append rejects a path-traversal --session without writing anywhere"
    fi
    rm -rf "$FT" 2>/dev/null || true
}

# H18 — S2-2: a session with no state file or outside the recording period is
# reported on one stderr line with exit 0, so a skill's recording call never
# fails its step; and nothing is created or recorded.
run_H18() {
    local problems="" row sid want
    new_fixture
    seed_active "$FN" "h18-pending" pending
    for row in "h18-absent:no-state" "h18-pending:outside-period"; do
        sid="${row%%:*}" want="${row##*:}"
        cli "$FN" "$FT" --session "$sid" --class D --step - --key h18 --summary same --pointer - --origin procedure-point
        [ "$CR" -eq 0 ] || problems="$problems [$want:exit $CR]"
        [ "$CN" = "1" ] || problems="$problems [$want:stderr-lines $CN]"
        case "$CO$CE" in *"$want"*) : ;; *) problems="$problems [$want:reason not named: '$CO$CE']" ;; esac
    done
    [ -e "$FT/wf/h18-absent.json" ] && problems="$problems [no-state:state-file-created]"
    [ "$(count_recs "$FN" "h18-pending")" = "0" ] || problems="$problems [outside-period:recorded]"
    rm -rf "$FT" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "H18: no-state and outside-period each print one stderr line naming the reason and exit 0, creating and recording nothing"
    else
        fail "H18: —$problems"
    fi
}

# H20 — #2578: NEXT_STEP_PAUSE does not close the recording period, so the
# procedure-point call still records while the session is paused.
run_H20() {
    local got paused
    new_fixture
    seed_active "$FN" "sess-h20"
    paused="$(in_env "$FN" node "$(np "$JS/pause.js")" "sess-h20" 2>&1)"
    cli "$FN" "$FT" --session sess-h20 --class D --step - --key h20 --summary "while paused" --pointer - --origin procedure-point
    got="$(count_recs "$FN" "sess-h20" "h20")"
    rm -rf "$FT" 2>/dev/null || true
    if [ "$paused" != "paused" ]; then
        fail "H20: fixture could not declare NEXT_STEP_PAUSE: '$paused'"
    elif [ "$got" = "1|D|-|procedure-point|while paused|-" ]; then
        pass "H20: handoff-append records during NEXT_STEP_PAUSE"
    else
        fail "H20: expected one record while paused, got '$got' (exit $CR, stdout '$CO', stderr '$CE')"
    fi
}

# H12-H17, H19 (CLI UX) live in a sibling fragment (rules/coding/file-split.md Pattern A).
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feat-2218-handoff-artifact/cli-ux.sh"

case_begin "procedure-point-lands-in-state-file" "bin/workflow/handoff-append"
run_H2
case_end

case_begin "same-key-history-is-kept" "bin/workflow/handoff-append"
run_H3
case_end

case_begin "noop-identical-per-class" "bin/workflow/handoff-append"
run_H4
case_end

case_begin "overflow-keeps-history-and-marks-once" "bin/workflow/handoff-append"
run_H5
case_end

case_begin "refusals-record-nothing" "bin/workflow/handoff-append"
run_H8
case_end

case_begin "cli-defaults-to-native-sid" "bin/workflow/handoff-append"
run_H9
case_end

case_begin "cli-rejects-bad-origin" "bin/workflow/handoff-append"
run_H10
case_end

case_begin "cli-rejects-traversal-sid" "bin/workflow/handoff-append"
run_H11
case_end

case_begin "cli-reports-non-write-reasons" "bin/workflow/handoff-append"
run_H18
case_end

case_begin "cli-records-while-paused" "bin/workflow/handoff-append"
run_H20
case_end

case_begin "cli-ux" "bin/workflow/handoff-append"
run_H12
run_H13
run_H14
run_H15
run_H16
run_H17
run_H19
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
