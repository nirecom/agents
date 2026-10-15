# shellcheck shell=bash
# tests/bin/feature-2431-baseline-evidence/accept.sh
# Tests: bin/workflow/run-tests-baseline-evidence, bin/workflow/lib/run-tests-baseline-evidence.js
# Tags: run-tests, baseline, evidence, accept, workflow, dispatch-outcome, scope:issue-specific, pwsh-not-required, TL2
# Sourced by ../feature-2431-baseline-evidence.sh after its #2544 helpers; never run standalone.
# #2517 `accept --session <sid>`: completes run_tests as baseline-user-accepted only while the
# user's grant (baseline_accept) still names the current run, and the run is either
# undetermined-only or carries no failing list. Without a grant it exits 6 and writes nothing.

ACC_FORM="WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED"
ACC_PAIR='["tests/a.sh","tests/b.sh"]'

# acc_seed <sid> <run_outcome> <failing-json|null> <unrunnable-count|-> [<classification-json>]
# A `-` count leaves unrunnable_count unrecorded.
acc_seed() {
  local cls="" unr=""
  [ -n "${5:-}" ] && cls=",$BOS_EV_RT\"baseline_classification\",\"value\":$5}"
  [ "$4" = "-" ] || unr=",$BOS_EV_RT\"unrunnable_count\",\"value\":$4}"
  bos_ck "fixture: state seeded ($1)" "" "$(bos_tool seed "$1" "[{\"kind\":\"step_status\",\"step\":\"run_tests\",\"status\":\"pending\"},$BOS_EV_RT\"run_outcome\",\"value\":\"$2\"},$BOS_EV_RT\"failing_tests\",\"value\":$3}$unr$cls]")"
}

# acc_cls <path:class:detail>... — a classification annotation value.
acc_cls() {
  local out="" e p c d
  for e in "$@"; do
    IFS=: read -r p c d <<<"$e"
    out="$out${out:+,}{\"path\":\"$p\",\"class\":\"$c\",\"detail\":\"$d\"}"
  done
  printf '{"base":"abc123","entries":[%s]}' "$out"
}

# acc_ann <sid> <key> <json> — one run_tests annotation; updated_seq does not move.
acc_ann() { bos_ck "fixture: $2 seeded ($1)" "" "$(bos_tool seed "$1" "[$BOS_EV_RT\"$2\",\"value\":$3}]")"; }

# acc_grant <sid> <kind> <accepted_run_outcome> [<outcome_source-json>] — bound to the current seq.
acc_grant() {
  acc_ann "$1" baseline_accept "{\"reason\":\"fails on main too\",\"kind\":\"$2\",\"run_seq\":$(bos_seq_of "$1"),\"outcome_source\":${4:-null},\"accepted_run_outcome\":\"$3\"}"
}

# acc_run <sid> — sets ACC_RC, ACC_OUT, ACC_ERR; runs from a neutral directory.
acc_run() {
  ACC_RC=0
  ACC_OUT="$(cd "$TMPROOT" && run_with_timeout 30 "$EVIDENCE_CLI" accept --session "$1" 2>"$TMPROOT/acc-err")" || ACC_RC=$?
  ACC_OUT="$(printf '%s' "$ACC_OUT" | tr -d '\r')"
  ACC_ERR="$(tr -d '\r' <"$TMPROOT/acc-err" 2>/dev/null || true)"
}

# acc_cli_err <arg>... — the evidence CLI's stderr alone, run from a neutral directory.
acc_cli_err() { (cd "$TMPROOT" && run_with_timeout 30 "$EVIDENCE_CLI" "$@" 2>&1 >/dev/null) | tr -d '\r'; }

# acc_snap <sid> — what a refused accept must leave untouched: run_outcome, grant, event count.
acc_snap() {
  printf 'outcome=%s grant=%s events=%s' "$(bos_tool field "$1" run_tests run_outcome)" \
    "$(bos_tool field "$1" run_tests baseline_accept)" "$(bos_tool count "$1")"
}

# acc_refused <label> <sid> <want-exit> — the exit, run_tests left pending with no basis, and
# run_outcome, the grant and the event stream unchanged.
acc_refused() {
  local before
  before="$(acc_snap "$2")"
  acc_run "$2"
  bos_ck "$1: accept exits $3" "$3" "$ACC_RC"
  bos_ck "$1: run_tests stays pending" "pending" "$(bos_tool field "$2" run_tests status)"
  bos_ck "$1: no completion_basis" "(absent)" "$(bos_tool field "$2" run_tests completion_basis)"
  bos_ck "$1: run_outcome, grant and event stream unchanged" "$before" "$(acc_snap "$2")"
}

# acc_completed <label> <sid> <kind> — exit 0, the RECORDED line and the completed shape.
acc_completed() {
  acc_run "$2"
  bos_ck "$1: accept exits 0" "0" "$ACC_RC"
  bos_ck "$1: RECORDED line" "RECORDED completion_basis=baseline-user-accepted kind=$3" "$ACC_OUT"
  bos_ck "$1: run_tests complete" "complete" "$(bos_tool field "$2" run_tests status)"
  bos_ck "$1: completion_basis" "baseline-user-accepted" "$(bos_tool field "$2" run_tests completion_basis)"
  bos_ck "$1: run_outcome pass" "pass" "$(bos_tool field "$2" run_tests run_outcome)"
}

cat >"$TMPROOT/acc-newrun.js" <<'EOF'
// <agents> <sid> — one new failing Bash-stdout run through the hook's only writer.
const [agents, sid] = process.argv.slice(2);
require(agents + "/hooks/workflow-run-tests/record-run").recordRun({ sessionId: sid, exitCode: 1,
  outcomeInput: {}, failingTests: ["tests/a.sh"], triggerCommand: "bash tests/run-all.sh" });
process.stdout.write("ok");
EOF

case_begin "accept-without-grant-is-absent" "bin/workflow/lib/run-tests-baseline-evidence.js"
SID="$(bos_sid acc-absent)"
acc_seed "$SID" fail "$ACC_PAIR" 0 "$(acc_cls tests/a.sh:undetermined:home-claude-ref tests/b.sh:preexisting:)"
acc_refused "no-grant" "$SID" 6
bos_ck "no-grant: prints nothing on stdout" "" "$ACC_OUT"
case_end

case_begin "accept-undetermined-every-reason" "bin/workflow/lib/run-tests-baseline-evidence.js"
# The undetermined detail is never inspected: every reason the CLI can emit completes the same way.
for why in home-claude-ref budget-exhausted timeout-at-base ambiguous-exit-137; do
  SID="$(bos_sid "acc-u-$why")"
  acc_seed "$SID" fail "$ACC_PAIR" 0 "$(acc_cls "tests/a.sh:undetermined:$why" tests/b.sh:preexisting:)"
  acc_grant "$SID" undetermined fail
  acc_completed "undetermined $why" "$SID" undetermined
  bos_ck "undetermined $why: grant survives completion" "fail" \
    "$(bos_tool path "$SID" run_tests baseline_accept accepted_run_outcome)"
done
case_end

case_begin "accept-failing-list-unrecorded" "bin/workflow/lib/run-tests-baseline-evidence.js"
# The exit-3 entry: no failing list, so nothing to classify; the grant alone completes it.
for ro in fail timeout runner-error; do
  SID="$(bos_sid "acc-nl-$ro")"
  acc_seed "$SID" "$ro" null 0
  acc_grant "$SID" failing-list-unrecorded "$ro"
  acc_completed "no-list $ro" "$SID" failing-list-unrecorded
done
SID="$(bos_sid acc-nl-empty)"
acc_seed "$SID" fail '[]' 0
acc_grant "$SID" failing-list-unrecorded fail
acc_completed "empty failing list" "$SID" failing-list-unrecorded
case_end

case_begin "accept-is-idempotent" "bin/workflow/lib/run-tests-baseline-evidence.js"
# A second accept after a completion writes nothing: no second step_status, basis kept.
SID="$(bos_sid acc-idem)"
acc_seed "$SID" fail "$ACC_PAIR" 0 "$(acc_cls tests/a.sh:undetermined:home-claude-ref tests/b.sh:preexisting:)"
acc_grant "$SID" undetermined fail
acc_completed "first accept" "$SID" undetermined
idem_before="$(bos_tool count "$SID"):$(bos_seq_of "$SID")"
acc_run "$SID"
bos_ck "second accept: exits non-zero" "yes" "$([ "$ACC_RC" -ne 0 ] && echo yes || echo "no(rc=$ACC_RC)")"
bos_ck "second accept: no RECORDED line" "" "$(printf '%s\n' "$ACC_OUT" | grep '^RECORDED')"
bos_ck "second accept: event count and seq unchanged" "$idem_before" "$(bos_tool count "$SID"):$(bos_seq_of "$SID")"
bos_ck "second accept: still complete" "complete" "$(bos_tool field "$SID" run_tests status)"
bos_ck "second accept: basis kept" "baseline-user-accepted" "$(bos_tool field "$SID" run_tests completion_basis)"
case_end

case_begin "accept-undetermined-needs-an-exact-zero-unrunnable" "bin/workflow/lib/run-tests-baseline-evidence.js"
# The undetermined kind requires unrunnable_count === 0, as record() does: absent or negative refuses.
for unr in - -1; do
  SID="$(bos_sid "acc-unr0-${unr#-}x")"
  acc_seed "$SID" fail "$ACC_PAIR" "$unr" "$(acc_cls tests/a.sh:undetermined:home-claude-ref tests/b.sh:preexisting:)"
  acc_grant "$SID" undetermined fail
  acc_refused "unrunnable_count [$unr]" "$SID" 1
done
case_end

case_begin "accept-refuses-a-stale-or-wrong-grant" "bin/workflow/lib/run-tests-baseline-evidence.js"
SID="$(bos_sid acc-broken)"
acc_seed "$SID" fail "$ACC_PAIR" 0 "$(acc_cls tests/a.sh:undetermined:timeout-at-base tests/b.sh:preexisting:)"
acc_grant "$SID" undetermined fail
acc_ann "$SID" baseline_classification "$(acc_cls tests/a.sh:undetermined:timeout-at-base tests/b.sh:broken:)"
acc_refused "broken after grant" "$SID" 1
SID="$(bos_sid acc-cover)"
acc_seed "$SID" fail "$ACC_PAIR" 0 "$(acc_cls tests/a.sh:undetermined:home-claude-ref)"
acc_grant "$SID" undetermined fail
acc_refused "cover incomplete" "$SID" 1
SID="$(bos_sid acc-seq)"
acc_seed "$SID" fail "$ACC_PAIR" 0 "$(acc_cls tests/a.sh:undetermined:home-claude-ref tests/b.sh:preexisting:)"
acc_grant "$SID" undetermined fail
seq0="$(bos_seq_of "$SID")"
bos_tool seed "$SID" '[{"kind":"step_status","step":"run_tests","status":"pending"}]' >/dev/null
bos_ck "fixture: pending sentinel moved the seq" "yes" "$([ "$(bos_seq_of "$SID")" != "$seq0" ] && echo yes || echo no)"
acc_refused "seq advanced after grant" "$SID" 1
SID="$(bos_sid acc-ro)"
acc_seed "$SID" fail "$ACC_PAIR" 0 "$(acc_cls tests/a.sh:undetermined:home-claude-ref tests/b.sh:preexisting:)"
acc_grant "$SID" undetermined timeout
acc_refused "accepted_run_outcome differs" "$SID" 1
SID="$(bos_sid acc-kind)"
acc_seed "$SID" fail "$ACC_PAIR" 0 "$(acc_cls tests/a.sh:undetermined:home-claude-ref tests/b.sh:preexisting:)"
acc_grant "$SID" failing-list-unrecorded fail
acc_refused "kind differs from state" "$SID" 1
SID="$(bos_sid acc-unr)"
acc_seed "$SID" fail "$ACC_PAIR" 2 "$(acc_cls tests/a.sh:undetermined:home-claude-ref tests/b.sh:preexisting:)"
acc_grant "$SID" undetermined fail
acc_refused "unrunnable_count positive" "$SID" 1
case_end

case_begin "accept-new-run-tombstones-the-grant" "hooks/workflow-run-tests/record-run.js"
SID="$(bos_sid acc-newrun)"
acc_seed "$SID" fail "$ACC_PAIR" 0 "$(acc_cls tests/a.sh:undetermined:home-claude-ref tests/b.sh:preexisting:)"
acc_grant "$SID" undetermined fail
bos_ck "fixture: grant present before the run" "undetermined" "$(bos_tool path "$SID" run_tests baseline_accept kind)"
bos_ck "fixture: new run recorded" "ok" "$(run_with_timeout 30 node "$TMPROOT/acc-newrun.js" "$AGENTS_WIN" "$SID" 2>/dev/null)"
bos_ck "new run: grant cleared" "(absent)" "$(bos_tool field "$SID" run_tests baseline_accept)"
acc_refused "new run after grant" "$SID" 6
case_end

case_begin "accept-dispatch-outcome-identity" "bin/workflow/lib/run-tests-baseline-evidence.js"
# A grant on a dispatch-ingested run is bound to its outcome file (stem + outcome digest).
SID="$(bos_sid acc-src)"; bos_seed_ingested "$SID" 0
acc_ann "$SID" baseline_classification "$(acc_cls tests/bin/alpha.sh:undetermined:budget-exhausted)"
SRC="$(bos_tool field "$SID" run_tests outcome_source)"
acc_grant "$SID" undetermined fail "$SRC"
acc_completed "matching outcome_source" "$SID" undetermined
SID="$(bos_sid acc-digest)"; bos_seed_ingested "$SID" 0
acc_ann "$SID" baseline_classification "$(acc_cls tests/bin/alpha.sh:undetermined:budget-exhausted)"
acc_grant "$SID" undetermined fail '{"stem":"worker-test-runner-1","payload_sha256":"00","outcome_sha256":"00"}'
acc_refused "outcome digest differs" "$SID" 1
SID="$(bos_sid acc-unsettled)"; bos_seed_ingested "$SID" 0
acc_ann "$SID" baseline_classification "$(acc_cls tests/bin/alpha.sh:undetermined:budget-exhausted)"
acc_grant "$SID" undetermined fail "$(bos_tool field "$SID" run_tests outcome_source)"
bos_ck "fixture: newer dispatch placed" "worker-test-runner-2" "$(dispatch_outcome_place "$SID" 2 pass 1 0 0 "$AGENTS_WIN")"
acc_refused "unsettled newer dispatch" "$SID" 3
case_end

case_begin "accept-outcome-source-identity-needs-stem-and-both-sides" "bin/workflow/lib/run-tests-baseline-evidence.js"
# sameSource: a matching outcome digest under another stem refuses, and so does a grant whose
# outcome_source is null while the run's is set, or set while the run's is null.
SID="$(bos_sid acc-stem)"; bos_seed_ingested "$SID" 0
acc_ann "$SID" baseline_classification "$(acc_cls tests/bin/alpha.sh:undetermined:budget-exhausted)"
OSHA="$(bos_tool path "$SID" run_tests outcome_source outcome_sha256)"
PSHA="$(bos_tool path "$SID" run_tests outcome_source payload_sha256)"
bos_ck "fixture: ingested run carries an outcome digest" "yes" "$([[ -n "$OSHA" && "$OSHA" != "(absent)" ]] && echo yes || echo no)"
acc_grant "$SID" undetermined fail "{\"stem\":\"worker-test-runner-9\",\"payload_sha256\":\"$PSHA\",\"outcome_sha256\":\"$OSHA\"}"
acc_refused "same digest, other stem" "$SID" 1
SID="$(bos_sid acc-src-null)"; bos_seed_ingested "$SID" 0
acc_ann "$SID" baseline_classification "$(acc_cls tests/bin/alpha.sh:undetermined:budget-exhausted)"
acc_grant "$SID" undetermined fail
acc_refused "grant source null, run source set" "$SID" 1
SID="$(bos_sid acc-run-null)"
acc_seed "$SID" fail "$ACC_PAIR" 0 "$(acc_cls tests/a.sh:undetermined:home-claude-ref tests/b.sh:preexisting:)"
bos_ck "fixture: plain run has no outcome_source" "(absent)" "$(bos_tool field "$SID" run_tests outcome_source)"
acc_grant "$SID" undetermined fail '{"stem":"worker-test-runner-1","payload_sha256":"00","outcome_sha256":"00"}'
acc_refused "grant source set, run source null" "$SID" 1
case_end

case_begin "failing-and-record-point-at-the-sentinel" "bin/workflow/lib/run-tests-baseline-evidence.js"
# failing(): exit 3 on a list-less failing run names the sentinel, except when UNRUNNABLE>0.
SID="$(bos_sid acc-hint-nl)"; acc_seed "$SID" fail null 0
FAIL_ERR="$(acc_cli_err failing --session "$SID")"
if [[ "$FAIL_ERR" == *"$ACC_FORM"* ]]; then pass "failing exit-3 names $ACC_FORM"; else fail "failing exit-3 names $ACC_FORM" "stderr: $FAIL_ERR"; fi
SID="$(bos_sid acc-hint-unr)"; acc_seed "$SID" fail null 2
FAIL_ERR="$(acc_cli_err failing --session "$SID")"
if [[ "$FAIL_ERR" == *"$ACC_FORM"* ]]; then fail "UNRUNNABLE>0: no baseline hint" "stderr: $FAIL_ERR"; else pass "UNRUNNABLE>0: no baseline hint"; fi
# record(): UNMET with undetermined-only names the sentinel; with a broken entry it does not.
printf 'tests/a.sh\tundetermined\thome-claude-ref\ntests/b.sh\tpreexisting\t\n' >"$TMPROOT/acc-u.txt"
printf 'tests/a.sh\tundetermined\thome-claude-ref\ntests/b.sh\tbroken\t\n' >"$TMPROOT/acc-b.txt"
for row in u:yes b:no; do
  f="${row%%:*}"; want="${row##*:}"
  SID="$(bos_sid "acc-rec-$f")"; acc_seed "$SID" fail "$ACC_PAIR" 0
  REC_E="$(acc_cli_err record --session "$SID" --seq "$(bos_seq_of "$SID")" --classification "$(np "$TMPROOT/acc-$f.txt")")"
  got=no; [[ "$REC_E" == *"$ACC_FORM"* ]] && got=yes
  bos_ck "record UNMET ($f) names the sentinel: $want" "$want" "$got"
  bos_ck "record UNMET ($f) stays pending" "pending" "$(bos_tool field "$SID" run_tests status)"
done
case_end

case_begin "accept-failing-list-unrecorded-needs-an-exact-zero-unrunnable" "bin/workflow/lib/run-tests-baseline-evidence.js"
# The list-less kind is held to unrunnable_count === 0 like the undetermined kind: an unknown count
# (null, or the legacy unrecorded field) refuses. The exact-0 control is accept-failing-list-unrecorded.
for row in null:null absent:-; do
  SID="$(bos_sid "acc-nlunr-${row%%:*}")"
  acc_seed "$SID" fail null "${row##*:}"
  acc_grant "$SID" failing-list-unrecorded fail
  acc_refused "no-list unrunnable_count ${row%%:*}" "$SID" 1
done
case_end

case_begin "failing-listless-hint-needs-an-exact-zero-unrunnable" "bin/workflow/lib/run-tests-baseline-evidence.js"
# failing(): the list-less exit 3 names the sentinel only on an exact 0 (control: acc-hint-nl above).
for row in null:null absent:-; do
  SID="$(bos_sid "acc-hint-${row%%:*}")"; acc_seed "$SID" fail null "${row##*:}"
  HINT_RC=0
  (cd "$TMPROOT" && run_with_timeout 30 "$EVIDENCE_CLI" failing --session "$SID" >/dev/null 2>&1) || HINT_RC=$?
  bos_ck "unrunnable_count ${row%%:*}: failing exits 3" "3" "$HINT_RC"
  FAIL_ERR="$(acc_cli_err failing --session "$SID")"
  if [[ "$FAIL_ERR" == *"$ACC_FORM"* ]]; then
    fail "unrunnable_count ${row%%:*}: no baseline hint" "stderr: $FAIL_ERR"
  else
    pass "unrunnable_count ${row%%:*}: no baseline hint"
  fi
done
case_end
