#!/usr/bin/env bash
# Tests: hooks/lib/jev/broker.js, bin/lib/jev-report-aggregate.js
# Tags: TL2, hooks, bin, jev, broker, report, mock-server, cross-module, scope:issue-specific, pwsh-not-required, production-switch, two-stage, orphan, crash-recovery, superseded, short-circuit, frozen-policy, input-insufficient, adoption

# The decision log written by the real two-stage query / finalize / sweep path in production
# mode must read back through the real bin/jev-report as the adoption figures it claims:
# an orphan is finalize_absent, a crash re-run is one record, a superseded ticket is only
# superseded_count, a skip short circuit is counted, the mode frozen at query time is the
# by_mode bucket, and a truncated issue body is an input-insufficient "issue body".

# TL3 gap (what this test does NOT catch): a real Jev endpoint and a real subagent dispatch;
# the subagent answer is written straight into the ANSWER_FILE the query hands out.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
BTR_PRE_ISO="$(make_tmp)"
harness_isolate "$BTR_PRE_ISO"
unset CLAUDE_CODE_SESSION_ID
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2460-jev-judge/_lib.sh"
. "$JJ_DIR/two-stage-lib.sh"
. "$JJ_DIR/_skip-lib.sh"
rm -rf "$BTR_PRE_ISO"
REPORT="$REPO_N/bin/jev-report"
RFX="$(np "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2460-jev-report-accuracy/report-fx.js")"

# brep: run the real jev-report over this fixture's decision log; sets REP_RC and RJ.
brep() {
  RJ="$FX/io/report.json"
  (cd "$FX/cwd" && bash "$RWT" 60 node "$REPORT" --log "$(np "$LOG")" --json --no-sweep > "$RJ" 2> "$FX/io/report.err")
  REP_RC=$?
}
# bq <expr>: evaluate <expr> over $RJ with A(pt) AO() R(pt) C(pt,t) K(pt,t,key) L(pt) f4(x).
bq() { run_with_timeout 30 node "$RFX" q "$(np "$RJ")" "$1" 2>/dev/null; }

echo "=== production two-stage records read back as adoption figures ==="
case_begin "btr-orphan-is-finalize-absent" "hooks/lib/jev/broker.js"
if need_mod hooks/lib/jev/two-stage/query.js && need_mod bin/lib/jev-report-aggregate/adoption.js; then
  jj_fx btr-orphan
  mock_p 0.01 S2-architecture 0.5
  jj_query complexity
  check "query with one unsure key: RESULT=need-subagent" "need-subagent" "$(kv RESULT)"
  sleep 1.1
  tsp sweep "$SID" 1
  check "sweep: exit 0" "0" "$TS_RC"
  brep
  check "report: exit 0, one complexity-judge record, finalize_absent 1, production" "0|1|1|1" \
    "$REP_RC|$(bq '[A("complexity-judge").count, A("complexity-judge").finalize_absent, A("complexity-judge").by_mode?.production].join("|")')"
fi
case_end

case_begin "btr-crash-rerun-counted-once" "bin/lib/jev-report-aggregate.js"
if need_mod hooks/lib/jev/two-stage/finalize.js && need_mod bin/lib/jev-report-aggregate/adoption.js; then
  jj_fx btr-crash
  mock_p 0.01
  ts_query complexity
  ts_fin '{"crashAt":"after-append"}'
  check "crashAt after-append: probe stopped with 99" "99" "$TS_RC"
  jj finalize --session "$SID" --ticket "$TICKET"
  check "re-run finalize: exit 0" "0" "$JJ_RC"
  brep
  check "report: exit 0, one decision for the ticket, duplicate_ticket_records 0" "0|1|0" \
    "$REP_RC|$(bq 'A("complexity-judge").count')|$(bq 'get(o, "duplicate_ticket_records")')"
fi
case_end

case_begin "btr-superseded-complexity" "bin/lib/jev-report-aggregate.js"
if need_mod bin/workflow/jev-judge && need_mod bin/lib/jev-report-aggregate/adoption.js; then
  jj_fx btr-super
  # complexity-judge adopts Jev only on the true side (false bar null): 0.99 lets Jev decide.
  mock_p 0.99
  jj_query complexity
  TA="$TICKET"
  jj_query complexity
  TB="$TICKET"
  jj finalize --session "$SID" --ticket "$TB"
  jj finalize --session "$SID" --ticket "$TA"
  check "older ticket finalized last: SETTLE=superseded" "superseded" "$(kv SETTLE)"
  brep
  check "report: only the newer ticket counted, superseded_count 1 (point and overall)" "0|1|1|1|1" \
    "$REP_RC|$(bq '[A("complexity-judge").count, A("complexity-judge").adopted?.jev, A("complexity-judge").superseded_count, get(o, "superseded_count")].join("|")')"
  check "the registry's production mode reached the log" "1" "$(bq 'A("complexity-judge").by_mode?.production')"
fi
case_end

case_begin "btr-detail-skip-short-circuit" "bin/lib/jev-report-aggregate.js"
if need_mod bin/workflow/lib/jev-skip-adapter.js && need_mod bin/lib/jev-report-aggregate/adoption.js; then
  sk_fx btr-sc detail
  mock_p 0.01
  ts_query outline detail-skip
  check "detail-skip query, every key confidently false: RESULT=final" "final" "$(kv RESULT)"
  ts_fin '{}'
  check "finalize: exit 0" "0" "$TS_RC"
  brep
  check "report: one detail-skip record, short_circuit_count 1, production, no LLM needed" "0|1|1|1|0.0000" \
    "$REP_RC|$(bq '[A("detail-skip").count, A("detail-skip").short_circuit_count, A("detail-skip").by_mode?.production, f4(A("detail-skip").llm_needed_rate)].join("|")')"
fi
case_end

case_begin "btr-frozen-mode-bucket" "bin/lib/jev-report-aggregate.js"
if need_mod hooks/lib/jev/two-stage/finalize.js && need_mod bin/lib/jev-report-aggregate/adoption.js; then
  jj_fx btr-mode
  mock_p 0.01
  ts_query complexity
  ts_fin '{"entryPatch":{"complexity-judge":{"mode":"shadow"}}}'
  check "finalize under a shadow entry: exit 0" "0" "$TS_RC"
  brep
  check "report: the query-time production mode is the bucket" "0|1|0" \
    "$REP_RC|$(bq 'A("complexity-judge").by_mode?.production')|$(bq 'A("complexity-judge").by_mode?.shadow || 0')"
fi
case_end

case_begin "btr-truncated-issue-body-input-insufficient" "bin/lib/jev-report-aggregate.js"
if need_mod bin/workflow/jev-judge && need_mod bin/lib/jev-report-aggregate/adoption.js; then
  BIG_BODY="$(head -c 30000 /dev/zero | tr '\0' 'x')"
  jj_fx btr-big "$BIG_BODY"
  mock_p 0.01
  jj_query complexity
  check "over-budget issue body: RESULT=need-subagent" "need-subagent" "$(kv RESULT)"
  answer_with "SIGNALS: none"
  jj finalize --session "$SID" --ticket "$TICKET"
  check "finalize: exit 0" "0" "$JJ_RC"
  brep
  check "report: input_insufficient 1 for the issue body section" "0|1|1" \
    "$REP_RC|$(bq 'A("complexity-judge").input_insufficient')|$(bq 'get(A("complexity-judge"), "input_insufficient_by_section", "issue body")')"
  check "the sentinel API key appears in no report output or stderr" "absent|absent" \
    "$(grep_absent "$SENTINEL_KEY" "$FX/io")|$(grep_absent "$SENTINEL_KEY" "$ERR_ALL")"
fi
case_end

finish
