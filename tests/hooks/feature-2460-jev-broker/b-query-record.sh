#!/usr/bin/env bash
# Tests: hooks/lib/jev/broker.js
# Tags: TL2, hooks, jev, broker, prototype-pollution, mock-server, jev-gate, scope:issue-specific, pwsh-not-required, parse-fallback
# Fragment of tests/hooks/feature-2460-jev-broker.sh, sourced by it after a-normalize.sh (not
# standalone): query/record point checks, probe failure forwarding, and the JEV gate.

echo "=== query and record refuse an unregistered point before any side effect ==="
# Enabled from here on, so a null below comes from the point check and not from the JEV gate.
BP_JEV=on
case_begin "b-query-shadow-unregistered-point" "hooks/lib/jev/broker.js"
fx_new b-query
mock_mode '{}'
for _pt in '"constructor"' '"__proto__"' '"toString"' '"no-such-point"' 'undefined'; do
  check "queryShadow point $_pt resolves null (JEV=on)" "null" "$(bp query "$_pt")"
done
check "no request reached the mock and no state dir entry exists" "0|" "$(mock_total)|$(names "$FX/state")"
check "control: the registered point queries the mock and leaves one pending" "complexity-judge|ok|1|1|1" \
  "$(bp query "$POINT")|$(mock_count models)|$(mock_count systemone)|$(pending_count)"
case_end

echo "=== a failed probe's own status reaches the result and the breaker ==="
case_begin "b-probe-failure-status-forwarded" "hooks/lib/jev/broker.js"
# probe_row <tag> <stub-json> <expected status|http_status|latency_ms|breaker last_failure_status>
probe_row() {
  fx_new "b-probe-$1"
  mock_mode '{}'
  check "$1: jev status|http_status|latency_ms|breaker last_failure_status" "$3" \
    "$(bp query-probe-stub "$2")|$(hq json-get "$(np "$JEVDIR/sid-1/breaker.json")" last_failure_status)"
  check "$1: no query follows a failed probe" "0" "$(mock_count systemone)"
}
probe_row timeout '{"ok":false,"status":"timeout"}' 'timeout|null|null|"timeout"'
probe_row http401 '{"ok":false,"status":"http-error","http_status":401}' 'http-error|401|null|"http-error"'
probe_row unreachable '{"ok":false,"status":"unreachable"}' 'unreachable|null|null|"unreachable"'
probe_row non-int-http '{"ok":false,"status":"http-error","http_status":"401"}' 'http-error|null|null|"http-error"'
case_end

case_begin "b-record-shadow-unregistered-point" "hooks/lib/jev/broker.js"
fx_new b-record
mock_mode '{}'
for _pt in '"constructor"' '"__proto__"' '"toString"' '"no-such-point"' 'undefined'; do
  check "recordShadow point $_pt returns null" "null" "$(bp record "$_pt")"
done
check "no request, no log, no state dir entry" "0|absent|" \
  "$(mock_total)|$([ -e "$LOG" ] && echo present || echo absent)|$(names "$FX/state")"
check "control: the registered point returns the record object and logs one record" "record|1|complexity-judge|S1-multi-file" \
  "$(bp record "$POINT")|$(rq toolu_b_record 'recs.length + "|" + (r && r.point) + "|" + (r && r.llm.answer)')"
check "the control left no norm dir" "0" "$(norm_left)"
case_end

echo "=== JEV unset or not on: the library itself does nothing ==="
case_begin "b-library-gated-on-jev" "hooks/lib/jev/broker.js"
_i=0
for _jv in __unset__ off OFF "" true 1 " on-ish"; do
  _i=$((_i + 1))
  fx_new "b-gate-$_i"
  mock_mode '{}'
  if [[ "$_jv" == __unset__ ]]; then unset BP_JEV; else BP_JEV="$_jv"; fi
  check "JEV=[$_jv]: queryShadow and recordShadow both return null" "null|null" "$(bp qt toolu_b_gate)|$(bp rt toolu_b_gate)"
  check "JEV=[$_jv]: no Jev request, no log, no state dir entry" "0|absent|" "$(mock_total)|$(log_state)|$(names "$FX/state")"
done
fx_new b-gate-pending
mock_mode '{}'
BP_JEV=on
check "fixture: a JEV=on query leaves one pending" "ok|finite|1" "$(bp qt toolu_b_gate_p)|$(pending_count)"
BP_JEV=off
check "JEV=off: recordShadow returns null, the pending stays unclaimed, no log" "null|toolu_b_gate_p.json|absent" \
  "$(bp rt toolu_b_gate_p)|$(names "$JEVDIR/sid-1/pending")|$(log_state)"
BP_JEV=ON
check "control: JEV=ON (case-insensitive) pairs with that pending" "record|1|ok|0" \
  "$(bp rt toolu_b_gate_p)|$(rq toolu_b_gate_p 'recs.length + "|" + (r && r.jev.status)')|$(pending_count)"
BP_JEV=on
case_end

echo "=== the LLM-side parser failing makes the LLM answer a parse-fallback, never compared ==="
case_begin "b-record-llm-parser-exit-parse-fallback" "hooks/lib/jev/broker.js"
_i=0
for _st in 1 3; do
  _i=$((_i + 1))
  fx_new "b-pexit-$_i"
  mock_mode '{}'
  check "exit $_st: fixture: an ok Jev query leaves one pending" "ok|finite|1" "$(bp qt toolu_b_pexit)|$(pending_count)"
  check "exit $_st: llm parse-fallback with the registry fallback, agreement null, jev ok, one parser spawn" \
    "parse-fallback|S0-undecidable|null|ok|1" "$(bp rt-parser-exit toolu_b_pexit "$_st")"
  check "exit $_st: the logged record carries the same, the pending is claimed, no norm dir left" \
    "1|parse-fallback|S0-undecidable|null|0|0" \
    "$(rq toolu_b_pexit 'recs.length + "|" + (r && [r.llm.status, r.llm.answer, String(r.agreement)].join("|"))')|$(pending_count)|$(norm_left)"
done
fx_new b-pexit-ok
mock_mode '{}'
check "control: a parser exiting 0 yields an ok, compared LLM answer" "ok|finite|1|ok|S1-multi-file|true|ok|1" \
  "$(bp qt toolu_b_pexit)|$(pending_count)|$(bp rt-parser-exit toolu_b_pexit 0)"
case_end
