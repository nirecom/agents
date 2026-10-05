#!/usr/bin/env bash
# Tests: bin/jev-report
# Tags: TL2, bin, jev, report, aggregation, json-output, low-confidence-reference, latency-percentiles, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): JSON aggregation over FIX_LOG, the point filter, human output and an empty log.

# jev-report is how the shadow PoC is judged: it must aggregate every rotated generation,
# count only both-ok records toward agreement (missing and parse-fallback never inflate
# or deflate it), expose which signal drags the confidence bar, and survive broken lines.
# The --json shape pinned here is the contract the write-code step implements.

# TL3 gap (what this test does NOT catch): a real week-long log; figures here come from a
# hand-built fixture whose expected values are derived in the comments beside each row.

echo "=== JSON aggregation over .1 + base, point-filtered ==="
case_begin "r-json-counts-and-stages" "bin/jev-report"
report "$J" --log "$(np "$FIX_LOG")" --point complexity-judge --json --no-sweep
check "exit 0" "0" "$REP_RC"
check "points holds only the requested point; broken line counted" "complexity-judge|1" \
  "$(jx 'o && Object.keys(o.points).join(",") + "|" + o.broken_lines')"
check "count 6 across both generations; stage counts" "6|2,1,1,1,1" \
  "$(jx "($P) && [$P.count, ['outline','detail','cos1','unknown','write_code'].map(s => $P.by_stage[s]).join(',')].join('|')")"
case_end

case_begin "r-agreement-both-ok-only" "bin/jev-report"
# R1 agree, R2 disagree; R3 low-confidence, R4 missing, R5 parse-fallback, R6 http-error excluded.
check "agreement_rate 0.5 over agreement_n 2" "0.5|2" "$(jx "($P) && $P.agreement_rate + '|' + $P.agreement_n")"
check "per-signal agreement: S1 1, S2 0.5, S3 1" "1|0.5|1" \
  "$(jx "($P) && ['S1-multi-file','S2-architecture','S3-security'].map(k => $P.agreement_by_signal[k]).join('|')")"
check "missing and parse_fallback counted separately" "1|1" "$(jx "($P) && $P.missing + '|' + $P.parse_fallback")"
case_end

case_begin "r-low-confidence-columns" "bin/jev-report"
check "low-confidence rate: S2 above zero, every other signal zero" "true|true" \
  "$(jx "($P) && [$P.low_confidence_rate_by_signal['S2-architecture'] > 0, Object.entries($P.low_confidence_rate_by_signal).filter(([k]) => k !== 'S2-architecture').every(([, v]) => v === 0)].join('|')")"
# R3 reference: p>=0.5 -> {S1,S2}; llm {S1}: S1 agrees (1), S2 disagrees (0).
check "low-confidence reference column: S1 1, S2 0" "1|0" \
  "$(jx "($P) && ['S1-multi-file','S2-architecture'].map(k => $P.low_confidence_reference_by_signal[k]).join('|')")"
check "low-confidence reference counts: n 1 (R3), llm-undecidable 0" "1|0" \
  "$(jx "($P) && $P.low_confidence_reference_n + '|' + $P.low_confidence_reference_llm_undecidable")"
case_end

case_begin "r-mismatches-latency-fallback-cost" "bin/jev-report"
check "one mismatch row (R2) with ts, session_id, stage, jev, llm" "1|sid-r2|detail|S1-multi-file|S1-multi-file,S2-architecture" \
  "$(jx "($P) && $P.mismatches.length + '|' + [$P.mismatches[0].session_id, $P.mismatches[0].stage, $P.mismatches[0].jev, $P.mismatches[0].llm].join('|')")"
# Only completed calls are sampled: jev {100..500} drops R6's http-error 600; llm
# {1000,2000,3000,5000,6000} keeps R5's parse-fallback 5000 and drops R4's missing null (without R5, p50 would be 2000).
check "jev p50 300 / p95 500 (http-error sample excluded); llm p50 3000 / p95 6000 (parse-fallback sample included)" "300|500|3000|6000" \
  "$(jx "($P) && ((l) => [l.jev.p50, l.jev.p95, l.llm.p50, l.llm.p95].join('|'))($P.latency_ms)")"
check "fallback_rate 2/6 with per-reason breakdown" "true|1|1" \
  "$(jx "($P) && [Math.abs($P.fallback_rate - 2 / 6) < 1e-9, $P.fallback_reasons['low-confidence'], $P.fallback_reasons['http-error']].join('|')")"
check "est cost total 0.00015 (null cost skipped, other-point excluded)" "true" \
  "$(jx "($P) && Math.abs($P.est_cost_usd_total - 0.00015) < 1e-12")"
case_end

echo "=== point filter, human output, empty log ==="
case_begin "r-no-point-filter-lists-both" "bin/jev-report"
report "$J" --log "$(np "$FIX_LOG")" --json --no-sweep
check "without --point both points are reported" "complexity-judge,other-point" "$(jx 'o && Object.keys(o.points).sort().join(",")')"
case_end
case_begin "r-human-output" "bin/jev-report"
report "$FX/io/report.txt" --log "$(np "$FIX_LOG")" --no-sweep
check "text mode exits 0 and names the point" "0|present" \
  "$REP_RC|$(grep -qF complexity-judge "$FX/io/report.txt" && echo present || echo absent)"
case_end
case_begin "r-empty-log" "bin/jev-report"
report "$J" --log "$(np "$FX/fixture/does-not-exist.log")" --json --no-sweep
check "absent log: exit 0, valid JSON, no point with records" "0|true" \
  "$REP_RC|$(jx 'o && typeof o.points === "object" && Object.values(o.points).every(p => !p.count)')"
case_end
