#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-gate-behavior.sh
# Tests: bin/worker-dispatch/workers/session-close-gate.js, bin/worker-dispatch.js
# Tags: worker-dispatch, session-close-gate, decision-table, table-driven, TL1, TL2, scope:issue-specific
#
# Issue #1643 — session-close-gate answers one question: may the caller run SC-6,
# or must it halt? Wrong in the yield direction wedges a session; wrong in the
# proceed direction closes a session while a supervisor review is still owed. The
# output-contract suite only proves the three lines are shaped right, so this file
# pins the DECISION: every row of the SC-5 / SC-5b table, the SC-4 observation
# derivation, and the gate JSON artifact the caller actually reads.
#
# The decision tables run as pure functions (TL1) because wall-clock timeout
# branches cannot be reached by waiting; the end-to-end rows go through the real
# dispatcher (TL2) with the supervisor CLIs canned via
# tests/feature-1643-worker-dispatch-lib/spawn-stub.js.
#
# TL3 gap (what this TL1+TL2 test does NOT catch):
#   - The real bin/supervisor-write-alert / -write-audit CLIs rejecting the argv
#     this worker builds, or not actually clearing the phase. Only a run against
#     the real CLIs shows that.
#   - A real supervisor-state.json whose schema has drifted from these fixtures.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_GATE_INNER:-}" ]; then
    _WD1643_GATE_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
WORKER_JS="$AGENTS_DIR/bin/worker-dispatch/workers/session-close-gate.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_has() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "want substring '$needle' in '$hay'" ;;
    esac
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$WORKER_JS" ] || [ ! -f "$PRELOAD" ]; then
    fail "0: fixture prerequisites missing" "worker=$WORKER_JS stub=$PRELOAD"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-gate-$$")"
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
WORKER_M="$(nodepath "$WORKER_JS")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"
printf '%s' '[{}]' > "$CANNED"

NOW=1900000000000        # fixed clock, so no test depends on the wall time it ran at
RECENT="$(node -e 'process.stdout.write(new Date(Number(process.argv[1])-60000).toISOString())' "$NOW")"
STALE="$(node -e 'process.stdout.write(new Date(Number(process.argv[1])-1200000).toISOString())' "$NOW")"

# Group 1 (TL1) — severityFor / scanOutcome: what counts as an observation
group_severity() {
    local desc value want got
    while IFS='|' read -r desc value want; do
        [ -z "${desc// }" ] && continue
        desc="${desc%"${desc##*[![:space:]]}"}"
        got="$(node -e 'process.stdout.write(String(require(process.argv[1]).severityFor(JSON.parse(process.argv[2]))));' \
            "$WORKER_M" "$value")" || got="<crash>"
        assert_eq "severity/$desc" "$want" "$got"
    done <<'TABLE'
failed-is-a-warning        |"failed"              |warning
skipped-is-a-notice        |"skipped"             |notice
skipped-underscore-variant |"skipped_admin_close" |notice
skipped-hyphen-variant     |"skipped-no-history"  |notice
clean-value-is-silent      |"appended"            |null
closed-is-silent           |"closed"              |null
non-string-is-silent       |7                     |null
null-is-silent             |null                  |null
TABLE
}

group_scan_outcome() {
    local outcome got
    outcome='{"issues":[
      {"issueNumber":11,"state":"closed","historyEntry":"failed","issueClosed":"closed",
       "sentinelsPosted":"skipped_admin_close","wipCleared":"cleared"},
      {"issueNumber":12,"state":"closed","historyEntry":"appended","issueClosed":"closed",
       "sentinelsPosted":"posted","wipCleared":"cleared"}
    ]}'
    got="$(node -e 'const f=require(process.argv[1]).scanOutcome(JSON.parse(process.argv[2]));
process.stdout.write(f.length+"|"+f.map((x)=>x.severity).join(",")+"|"+f.map((x)=>x.detail).join(" ;; "));' \
        "$WORKER_M" "$outcome")"
    assert_eq "scan/counts-only-non-clean-fields" "2" "${got%%|*}"
    assert_has "scan/severities-in-field-order" "|warning,notice|" "$got"
    assert_has "scan/detail-names-the-issue" "#11: historyEntry=failed" "$got"
    assert_has "scan/detail-names-the-skip-field" "#11: sentinelsPosted=skipped_admin_close" "$got"
    # A clean issue contributes nothing — otherwise every close would look noisy.
    case "$got" in
        *'#12'*) fail "scan/clean-issue-contributes-nothing" "$got" ;;
        *) pass "scan/clean-issue-contributes-nothing" ;;
    esac

    got="$(node -e 'process.stdout.write(String(require(process.argv[1]).scanOutcome(JSON.parse(process.argv[2])).length));' \
        "$WORKER_M" 'null')"
    assert_eq "scan/absent-outcome-is-zero-findings" "0" "$got"
    got="$(node -e 'process.stdout.write(require(process.argv[1]).scanOutcome({issues:[{state:"failed"}]}).map((x)=>x.detail).join(""));' \
        "$WORKER_M")"
    assert_has "scan/missing-issue-number-still-reported" "(issue number missing)" "$got"
}

# Group 2 (TL1) — the SC-5 / SC-5b decision tables, every row
eval_phase() {
    node -e 'const m=require(process.argv[1]);
const r=(process.argv[2]==="alert"?m.evaluateAlert:m.evaluateAudit)(JSON.parse(process.argv[3]),Number(process.argv[4]));
process.stdout.write([r.gateAction,r.phase,r.findings.length,r.repair].map(String).join("|"));' "$WORKER_M" "$1" "$2" "$NOW"
}

# Both phases are driven from one table: the alert and audit sides are symmetric
# except that only the alert side owns the proceed verdict (SC-5b never proceeds
# on its own), so the want column differs per kind and is spelled out per row.
group_phase_tables() {
    local kind desc state want got
    while IFS='@' read -r kind desc state want; do
        [ -z "${kind// }" ] && continue
        state="${state//RECENT/$RECENT}"; state="${state//STALE/$STALE}"
        got="$(eval_phase "$kind" "$state")" || got="<crash>"
        assert_eq "$kind/$desc" "$want" "$got"
    done <<'TABLE'
alert@absent-alert-object@{}@proceed|null|0|null
alert@phase-done@{"alert":{"alert_phase":"done"}}@proceed|done|0|null
alert@pending-armed-recent@{"alert":{"alert_phase":"pending","alert_armed_at":"RECENT"}}@yield|pending|0|null
alert@pending-armed-stale@{"alert":{"alert_phase":"pending","alert_armed_at":"STALE"}}@proceed|pending|1|null
alert@pending-armed-garbage@{"alert":{"alert_phase":"pending","alert_armed_at":"not-a-date"}}@proceed|pending|1|null
alert@pending-armed-null@{"alert":{"alert_phase":"pending","alert_armed_at":null}}@proceed|pending|1|null
alert@pending-but-already-ran@{"alert":{"alert_phase":"pending","alert_armed_at":"RECENT","last_run_at":"RECENT"}}@proceed|pending|1|alert
audit@absent-audit-object@{}@null|null|0|null
audit@phase-done@{"audit":{"audit_phase":"done"}}@null|done|0|null
audit@pending-armed-recent@{"audit":{"audit_phase":"pending","audit_armed_at":"RECENT"}}@yield|pending|0|null
audit@pending-armed-stale@{"audit":{"audit_phase":"pending","audit_armed_at":"STALE"}}@null|pending|1|null
audit@pending-armed-garbage@{"audit":{"audit_phase":"pending","audit_armed_at":"not-a-date"}}@null|pending|1|null
audit@pending-but-already-ran@{"audit":{"audit_phase":"pending","audit_armed_at":"RECENT","audit_last_run_at":"RECENT"}}@null|pending|1|audit
TABLE
}

# Group 3 (TL2) — end-to-end through the real dispatcher
DOUT=""; DRC=0
field_of() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1; }
gate_action_of() { node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).gate_action));}
catch(e){process.stdout.write("<unreadable>");}' "$(nodepath "$1")"; }
calls_for() { grep -c "\"script\":\"$1\"" "$CALLLOG" 2>/dev/null | tr -d ' '; }

# dispatch_gate <session-id> <state-json-or-RAW-or-empty> [outcome-json]
dispatch_gate() {
    local sid="$1" state="$2" outcome="${3:-}"
    local payload="{\"session_id\":\"$sid\",\"plans_dir\":\"$PLANS\",\"artifact_dir\":\"$PLANS\""
    if [ -n "$state" ]; then printf '%s' "$state" > "$PLANS_RAW/$sid-supervisor-state.json"; fi
    if [ -n "$outcome" ]; then
        printf '%s' "$outcome" > "$PLANS_RAW/$sid-outcome.json"
        payload="$payload,\"outcome_json_path\":\"$PLANS/$sid-outcome.json\""
    fi
    printf '%s}' "$payload" > "$PLANS_RAW/$sid-payload.json"
    : > "$CALLLOG"
    DRC=0
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
        "WD_SPAWN_MODULE=$(nodepath "$AGENTS_DIR/bin/worker-dispatch/spawn.js")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" \
        session-close-gate "$MAIN" "$PLANS/$sid-payload.json" 2>/dev/null)" || DRC=$?
}

group_no_state() {
    dispatch_gate sess-none ""
    assert_eq "nostate/exit0" "0" "$DRC"
    assert_eq "nostate/status" "complete" "$(field_of status)"
    assert_has "nostate/summary-proceeds" "gate_action=proceed" "$(field_of summary)"
    assert_has "nostate/summary-marks-alert-absent" "SC-5 alert_phase: (absent)" "$(field_of summary)"
    assert_has "nostate/summary-marks-audit-absent" "SC-5b audit_phase: (absent)" "$(field_of summary)"
    assert_eq "nostate/artifact-is-the-gate-json" "sess-none-session-close-gate.json" \
        "$(basename "$(field_of artifact_path)")"
    assert_eq "nostate/gate-json-says-proceed" "proceed" \
        "$(gate_action_of "$PLANS_RAW/sess-none-session-close-gate.json")"
    assert_eq "nostate/nothing-reported" "0" "$(calls_for report)"
}

group_yield_alert() {
    dispatch_gate sess-ya "{\"alert\":{\"alert_phase\":\"pending\",\"alert_armed_at\":\"$(node -e 'process.stdout.write(new Date().toISOString())')\"}}"
    assert_eq "yieldalert/exit0" "0" "$DRC"
    assert_has "yieldalert/summary-yields" "gate_action=yield" "$(field_of summary)"
    assert_eq "yieldalert/gate-json-says-yield" "yield" \
        "$(gate_action_of "$PLANS_RAW/sess-ya-session-close-gate.json")"
    assert_eq "yieldalert/no-repair-attempted" "0" "$(calls_for writeAlert)"
}

# The asymmetry the spec fixes: a live audit yields even though the alert side
# said proceed. If the two were OR-ed the wrong way this row would read proceed.
group_yield_audit_over_alert() {
    dispatch_gate sess-yb "{\"alert\":{\"alert_phase\":\"done\"},\"audit\":{\"audit_phase\":\"pending\",\"audit_armed_at\":\"$(node -e 'process.stdout.write(new Date().toISOString())')\"}}"
    assert_has "yieldaudit/summary-yields" "gate_action=yield" "$(field_of summary)"
    assert_has "yieldaudit/alert-phase-reported-as-done" "SC-5 alert_phase: done" "$(field_of summary)"
    assert_eq "yieldaudit/gate-json-says-yield" "yield" \
        "$(gate_action_of "$PLANS_RAW/sess-yb-session-close-gate.json")"
}

group_repair() {
    local ts
    ts="$(node -e 'process.stdout.write(new Date().toISOString())')"
    dispatch_gate sess-rep "{\"alert\":{\"alert_phase\":\"pending\",\"alert_armed_at\":\"$ts\",\"last_run_at\":\"$ts\"}}"
    assert_has "repair/proceeds-instead-of-wedging" "gate_action=proceed" "$(field_of summary)"
    assert_eq "repair/gate-json-says-proceed" "proceed" \
        "$(gate_action_of "$PLANS_RAW/sess-rep-session-close-gate.json")"
    assert_eq "repair/write-alert-called-once" "1" "$(calls_for writeAlert)"
    assert_eq "repair/audit-side-untouched" "0" "$(calls_for writeAudit)"
    assert_eq "repair/argv-clears-the-stale-phase" "--session-id sess-rep --set-alert-phase done --clear-alert-armed-at" \
        "$(node -e 'const rows=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map((l)=>JSON.parse(l));
const r=rows.find((x)=>x.script==="writeAlert");
process.stdout.write(r?r.args.join(" "):"<no writeAlert call>");' "$(nodepath "$CALLLOG")")"
    # The repair notice is itself an SC-4 observation and must be on the record.
    assert_eq "repair/notice-reported" "1" "$(calls_for report)"
}

group_sc4_reporting() {
    dispatch_gate sess-sc4 "" '{"issues":[{"issueNumber":21,"state":"closed","historyEntry":"failed","issueClosed":"closed","sentinelsPosted":"skipped","wipCleared":"cleared"}]}'
    assert_has "sc4/summary-counts-two-findings" "SC-4 findings: 2" "$(field_of summary)"
    assert_eq "sc4/one-report-per-finding" "2" "$(calls_for report)"
    assert_has "sc4/severity-reaches-the-cli" '"--severity","warning"' "$(cat "$CALLLOG")"
    assert_has "sc4/session-id-reaches-the-cli" '"--session-id","sess-sc4"' "$(cat "$CALLLOG")"
    assert_has "sc4/reporter-is-this-worker" '"--reporter","session-close-gate"' "$(cat "$CALLLOG")"
    # SC-4 is an audit trail, not a gate input: findings alone must not yield.
    assert_has "sc4/findings-do-not-change-the-gate" "gate_action=proceed" "$(field_of summary)"
}

# A malformed outcome file must not take the gate down — the SC-5/SC-5b decision
# does not read it. But it must not be silently equated with a clean one either:
# zero observations scanned out of a file that never parsed is a different fact
# from zero observations in a file that parsed and was clean, and only the first
# means the audit trail has a hole in it.
group_malformed_outcome() {
    dispatch_gate sess-bado "" '{"issues": [ this is not json'
    assert_eq "badoutcome/exit0" "0" "$DRC"
    assert_eq "badoutcome/status" "complete" "$(field_of status)"
    # Exactly one finding, and it is the one naming the unreadable file — which
    # is also how "zero ISSUE-derived observations" is pinned: had the scan
    # invented an entry from an unparsed file, the count would be 2.
    assert_has "badoutcome/one-finding-for-the-unreadable-file" "SC-4 findings: 1" "$(field_of summary)"
    assert_eq "badoutcome/one-report-per-finding" "1" "$(calls_for report)"
    assert_has "badoutcome/finding-names-the-unreadable-outcome" \
        "issue-close outcome JSON unreadable or malformed" "$(cat "$CALLLOG")"
    assert_has "badoutcome/finding-is-a-warning" '"--severity","warning"' "$(cat "$CALLLOG")"
    # No per-issue observation may be fabricated from a file that never parsed.
    assert_eq "badoutcome/no-issue-derived-observations" "0" \
        "$(grep -c 'issue-close outcome #' "$CALLLOG" 2>/dev/null | tr -d ' ')"
    # SC-4 is an audit trail, not a gate input — the verdict is untouched.
    assert_has "badoutcome/gate-unaffected" "gate_action=proceed" "$(field_of summary)"
    assert_eq "badoutcome/gate-json-says-proceed" "proceed" \
        "$(gate_action_of "$PLANS_RAW/sess-bado-session-close-gate.json")"
}

# A corrupt supervisor state file is NOT an absent one, and the gate treats them
# as opposite verdicts. The gate exists to withhold the Final Report while a
# supervisor review is still owed; a file it cannot read cannot prove there is
# none, so it fails CLOSED. Yielding costs a re-run, proceeding loses the review.
#
# Every way a state file can be unreadable is driven separately, because they
# arrive through different code paths: a truncated file throws in JSON.parse,
# while `null` / a number / a bare string all parse cleanly and only fail the
# "is it an object with phase fields" test afterwards. The absent control at the
# end is the other half of the pin — without it a regression that yielded
# unconditionally would still look green.
group_corrupt_state() {
    local desc raw sid
    while IFS='@' read -r desc raw; do
        [ -z "${desc// }" ] && continue
        desc="$(echo "$desc" | xargs)"
        raw="${raw#"${raw%%[![:space:]]*}"}"
        sid="sess-badstate-$desc"
        dispatch_gate "$sid" "$raw"
        assert_eq "badstate/$desc/exit0" "0" "$DRC"
        assert_eq "badstate/$desc/status" "complete" "$(field_of status)"
        assert_has "badstate/$desc/summary-yields" "gate_action=yield" "$(field_of summary)"
        assert_eq "badstate/$desc/gate-json-says-yield" "yield" \
            "$(gate_action_of "$PLANS_RAW/$sid-session-close-gate.json")"
        assert_has "badstate/$desc/warning-names-the-unreadable-state" \
            "supervisor state file unreadable or malformed" "$(cat "$CALLLOG")"
        assert_has "badstate/$desc/warning-names-the-state-path" \
            "$sid-supervisor-state.json" "$(cat "$CALLLOG")"
        assert_has "badstate/$desc/warning-says-fail-closed" "fail-closed" "$(cat "$CALLLOG")"
        assert_has "badstate/$desc/warning-severity" '"--severity","warning"' "$(cat "$CALLLOG")"
        # The log has to record WHICH fact it saw, or an operator reading it
        # cannot tell a wedged session from a corrupted one.
        assert_has "badstate/$desc/log-records-corrupt" "state file: (corrupt)" \
            "$(cat "$PLANS_RAW/$sid-session-close-worker.log" 2>/dev/null)"
    done <<'TABLE'
truncated-json @ {"alert": {"alert_phase": "pend
parses-to-null @ null
parses-to-number @ 7
parses-to-string @ "supervisor state went missing"
TABLE

    # Symmetric control: ABSENT is the other verdict. Both are pinned so neither
    # direction can regress into the other unnoticed.
    dispatch_gate sess-badstate-absent-control ""
    assert_has "badstate/absent-control/summary-proceeds" "gate_action=proceed" "$(field_of summary)"
    assert_eq "badstate/absent-control/gate-json-says-proceed" "proceed" \
        "$(gate_action_of "$PLANS_RAW/sess-badstate-absent-control-session-close-gate.json")"
    assert_has "badstate/absent-control/log-records-absent" "state file: (absent)" \
        "$(cat "$PLANS_RAW/sess-badstate-absent-control-session-close-worker.log" 2>/dev/null)"
    assert_eq "badstate/absent-control/nothing-reported" "0" "$(calls_for report)"
}

for _g in group_severity group_scan_outcome group_phase_tables group_no_state group_yield_alert     group_yield_audit_over_alert group_repair group_sc4_reporting group_malformed_outcome group_corrupt_state; do
    "$_g"
done

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
