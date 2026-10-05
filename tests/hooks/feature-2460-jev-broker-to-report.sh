#!/usr/bin/env bash
# Tests: hooks/lib/jev/broker.js, bin/lib/jev-report-aggregate.js
# Tags: TL2, hooks, bin, jev, broker, report, latency, latency-percentiles, unmappable, mock-server, cross-module, scope:issue-specific, s1b-without-s1, agreement, pwsh-not-required

# A Jev call whose query POST completed but whose answer set is unmappable still cost real
# time: the hook pair must log its latency and jev-report must count it in the Jev p50/p95.
# An outage (HTTP 500) beside it stays out of the percentiles. Driven through the real
# pre/post hooks against the loopback mock, then the real bin/jev-report on that log.

# TL3 gap (what this test does NOT catch): a real Jev endpoint's response time and the
# host's real Agent tool_use_id pairing; TL3-hook-agent-jev-shadow.sh covers the pairing.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"
. "$AGENTS_DIR/tests/hooks/feature-2460-jev-shadow/_lib.sh"
mock_start
REPORT="$REPO_N/bin/jev-report"
P='((o && o.points && o.points["complexity-judge"]) || {})'

echo "=== an unmappable Jev answer after a completed POST reaches the report's latency ==="
case_begin "x-unmappable-latency-logged-by-hooks" "hooks/lib/jev/broker.js"
fx_new x-unmap
SID="jev2460-x-unmap"
mock_mode '{"systemone":"http:500"}'
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_x_outage
mock_mode '{"systemone":"missing"}'
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_x_unmap
check "both hook pairs exit 0" "0|0" "$PRE_RC|$HOOK_RC"
check "the mock answered the unmappable query's POST" "1" "$(mock_count systemone)"
check "outage record: jev http-error, latency null" "1|http-error|null" \
  "$(rq toolu_x_outage 'recs.length + "|" + (r && [r.jev.status, String(r.jev.latency_ms)].join("|"))')"
X_LAT="$(rq toolu_x_unmap 'r && r.jev.latency_ms')"
check "unmappable record: jev unmappable with the fallback answer and an integer latency >= 0" "1|unmappable|S0-undecidable|int" \
  "$(rq toolu_x_unmap 'recs.length + "|" + (r && [r.jev.status, r.jev.answer].join("|"))')|$([[ "$X_LAT" =~ ^[0-9]+$ ]] && echo int || echo "bad:$X_LAT")"
case_end

case_begin "x-report-jev-percentiles-include-unmappable" "bin/lib/jev-report-aggregate.js"
J="$FX/io/report.json"
(cd "$FX/cwd" && bash "$RWT" 60 node "$REPORT" --log "$(np "$LOG")" --point complexity-judge --json --no-sweep > "$J" 2> "$FX/io/report.err")
REP_RC=$?
check "jev-report --json: exit 0, two records, Jev p50 and p95 are the unmappable call's latency (the outage is excluded)" \
  "0|2|$X_LAT|$X_LAT" \
  "$REP_RC|$(hq json-expr "$(np "$J")" "($P) && [$P.count, String($P.latency_ms.jev.p50), String($P.latency_ms.jev.p95)].join('|')")"
check "the unmappable record is a fallback and not an answered low-confidence sample" "1|0" \
  "$(hq json-expr "$(np "$J")" "($P) && [$P.fallback_reasons.unmappable, $P.low_confidence_rate_n].join('|')")"
case_end

echo "=== an S1b-without-S1 answer is a disagreement in the record and in the report ==="
case_begin "x-report-agreement-s1b-without-s1" "bin/lib/jev-report-aggregate.js"
fx_new x-s1b
SID="jev2460-x-s1b"
mock_mode '{"answers":{"S1-multi-file":0.02,"S1b-wide-change":0.95}}'
LLM_TEXT="SIGNALS: S1-multi-file, S1b-wide-change" pair "$SID" toolu_x_s1b_viol
mock_mode '{"answers":{"S1-multi-file":0.97,"S1b-wide-change":0.95}}'
LLM_TEXT="SIGNALS: S1-multi-file, S1b-wide-change" pair "$SID" toolu_x_s1b_pair
check "records: the jev S1b-only judgment disagrees, the valid pair agrees" "false|true" \
  "$(rq toolu_x_s1b_viol 'r && String(r.agreement)')|$(rq toolu_x_s1b_pair 'r && String(r.agreement)')"
J="$FX/io/report.json"
(cd "$FX/cwd" && bash "$RWT" 60 node "$REPORT" --log "$(np "$LOG")" --point complexity-judge --json --no-sweep > "$J" 2> "$FX/io/report.err")
REP_RC=$?
check "jev-report --json: agreement 0.5 over 2, S1 by-signal 0.5, S1b 1, s1b_without_s1 jev=1 llm=0, one mismatch" \
  '0|0.5|2|0.5|1|{"jev":1,"llm":0}|1' \
  "$REP_RC|$(hq json-expr "$(np "$J")" "($P) && [$P.agreement_rate, $P.agreement_n, $P.agreement_by_signal['S1-multi-file'], $P.agreement_by_signal['S1b-wide-change'], JSON.stringify($P.s1b_without_s1), $P.mismatches.length].join('|')")"
case_end

finish
