#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate.js, bin/jev-report
# Tags: TL2, bin, jev, report, latency-percentiles, low-confidence-rate, low-confidence-rate-n, null-ratio, unreadable-generations, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): latency per status, the low-confidence rate, and unreadable log generations.

echo "=== latency per status; low-confidence rate over answered Jev records only ==="
LAT2_LOG="$FX/fixture/lat-status.log"
LCR_LOG="$FX/fixture/lc-rate.log"
# lat-status: completed jev {10 ok, 20 unmappable}, outages/not-run 9000x; completed llm {1000 ok,
# 2000 parse-fallback}, missing/not-run single digits. lc-rate: ok (S2 0.6) and low-confidence
# (S5 0.6) are the denominator; three unmappable records (partial / null probabilities) are not.
run_with_timeout 30 node - "$(np "$LAT2_LOG")" "$(np "$LCR_LOG")" "$SIGNAL_CSV" 2>/dev/null <<'JS'
const fs = require("fs");
const ids = process.argv[4].split(",");
const probs = (over) => Object.fromEntries(ids.map((k) => [k, over[k] !== undefined ? over[k] : 0.02]));
const rec = (stage, jev, llm) => JSON.stringify({ v: 1, point: "complexity-judge", ts: "2026-10-01T00:00:01Z", session_id: "sid-s",
  stage, agreement: null, fallback_reason: null, jev, llm });
const S = [["ok", 10, "ok", 1000], ["unmappable", 20, "parse-fallback", 2000], ["timeout", 90001, "missing", 3],
  ["http-error", 90002, "not-run", 4], ["bad-response", 90003, "missing", 5], ["unreachable", 90004, "missing", 6],
  ["not-run", 90005, "missing", 7], ["breaker-open", 90006, "missing", 8]];
fs.writeFileSync(process.argv[2], S.map(([js, jl, ls, ll]) => rec(js, { status: js, latency_ms: jl }, { status: ls, latency_ms: ll })).join("\n") + "\n");
const lc = (js, pr) => rec(js, { status: js, probabilities: pr }, { status: "ok", answer: "S1-multi-file" });
fs.writeFileSync(process.argv[3], [lc("ok", probs({ "S2-architecture": 0.6 })), lc("low-confidence", probs({ "S5-breaking": 0.6 })),
  lc("unmappable", { "S1-multi-file": 0.97, "S2-architecture": 0.55, "S3-security": 0.55 }),
  lc("unmappable", Object.assign(Object.fromEntries(ids.map((k) => [k, null])), { "S2-architecture": 0.6, "S3-security": 0.55 })),
  lc("unmappable", null)].join("\n") + "\n");
JS

case_begin "r-latency-status-table" "bin/lib/jev-report-aggregate.js"
check "fixture: eight records, one per Jev status (non-vacuity)" "8|8" \
  "$(hq qa "$(np "$LAT2_LOG")" 'recs.length + "|" + new Set(recs.map((r) => r.jev.status)).size')"
report "$J" --log "$(np "$LAT2_LOG")" --point complexity-judge --json --no-sweep
check "jev {ok, unmappable}: p50 10 / p95 20 (outages, not-run, breaker-open excluded); llm {ok, parse-fallback}: p50 1000 / p95 2000 (missing, not-run excluded)" \
  "0|8|10|20|1000|2000" "$REP_RC|$(jx "($P) && [$P.count, $P.latency_ms.jev.p50, $P.latency_ms.jev.p95, $P.latency_ms.llm.p50, $P.latency_ms.llm.p95].join('|')")"
case_end

case_begin "r-low-confidence-rate-answered-only" "bin/lib/jev-report-aggregate.js"
report "$J" --log "$(np "$LCR_LOG")" --point complexity-judge --json --no-sweep
# Counting unmappable with probabilities would give S2 0.75 (numerator too) or 0.25 (denominator only), and S3 > 0.
check "rate per signal over ok + low-confidence only (S2 0.5, S5 0.5, every other 0)" "0|5|0|0|0.5|0|0|0.5|0" \
  "$REP_RC|$(jx "($P) && [$P.count].concat('$SIGNAL_CSV'.split(',').map((k) => $P.low_confidence_rate_by_signal[k])).join('|')")"
check "low_confidence_rate_n is the answered Jev count (ok + low-confidence = 2 of 5 records)" "2" "$(jx "$P.low_confidence_rate_n")"
T="$FX/io/lc-rate.txt"
report "$T" --log "$(np "$LCR_LOG")" --point complexity-judge --no-sweep
check "text: the rate line shows the values and ends with (n=2)" "0|S2-architecture=0.5|S5-breaking=0.5|true" \
  "$REP_RC|$(tx 'const l = lines.find((x) => x.startsWith("low-confidence rate by signal: ")) || ""; [/\bS2-architecture=[^ ]+/.exec(l), /\bS5-breaking=[^ ]+/.exec(l), l.endsWith("  (n=2)")].join("|")')"
case_end

LC0_LOG="$FX/fixture/lc-none.log"
# lc-none: no answered Jev record — a timeout, an unmappable with probabilities, a not-run.
run_with_timeout 30 node - "$(np "$LC0_LOG")" "$SIGNAL_CSV" 2>/dev/null <<'JS'
const fs = require("fs");
const probs = Object.fromEntries(process.argv[3].split(",").map((k) => [k, 0.6]));
const rec = (jev) => JSON.stringify({ v: 1, point: "complexity-judge", ts: "2026-10-01T00:00:01Z", session_id: "sid-z",
  stage: "cos1", agreement: null, fallback_reason: jev.status, jev, llm: { status: "ok", answer: "S1-multi-file" } });
fs.writeFileSync(process.argv[2], [rec({ status: "timeout" }), rec({ status: "unmappable", probabilities: probs }),
  rec({ status: "not-run" })].join("\n") + "\n");
JS

case_begin "r-low-confidence-rate-null-without-answered" "bin/lib/jev-report-aggregate.js"
report "$J" --log "$(np "$LC0_LOG")" --point complexity-judge --json --no-sweep
check "--json: no answered Jev record gives low_confidence_rate_n 0 and a null rate for every signal (never 0)" "0|3|0|7|true" \
  "$REP_RC|$(jx "($P) && [$P.count, $P.low_confidence_rate_n, Object.keys($P.low_confidence_rate_by_signal).length, '$SIGNAL_CSV'.split(',').every((k) => $P.low_confidence_rate_by_signal[k] === null)].join('|')")"
T="$FX/io/lc-none.txt"
report "$T" --log "$(np "$LC0_LOG")" --point complexity-judge --no-sweep
check "text: every signal renders n/a and the line ends with (n=0)" "0|7|7|true" \
  "$REP_RC|$(tx 'const l = lines.find((x) => x.startsWith("low-confidence rate by signal: ")) || ""; [(l.match(/=n\/a\b/g) || []).length, (l.match(/S[0-9]+b?-[a-z-]+=/g) || []).length, l.endsWith("  (n=0)")].join("|")')"
case_end

case_begin "r-empty-point-rates-null" "bin/lib/jev-report-aggregate.js"
check "aggregatePoint([]): fallback_rate, every low-confidence rate and agreement_rate are null; both n are 0" "null|true|0|null|0" \
  "$(run_with_timeout 30 node -e 'const a = require(process.argv[1]).aggregatePoint([], 0.7); process.stdout.write([String(a.fallback_rate), Object.values(a.low_confidence_rate_by_signal).every((v) => v === null), a.low_confidence_rate_n, String(a.agreement_rate), a.agreement_n].join("|"));' "$REPO_N/bin/lib/jev-report-aggregate.js" 2>/dev/null)"
case_end

echo "=== an unreadable generation is reported, an absent one is not ==="
UNR_LOG="$FX/fixture/unread/jev-decisions.log"
ABS_LOG="$FX/fixture/absent/jev-decisions.log"
mkdir -p "$UNR_LOG.2" "$UNR_LOG" "$(dirname "$ABS_LOG")"
# unread: .2 and base are directories (EISDIR on every platform); .3 and .1 hold one record each.
# absent: base only (one record and one broken line); .1/.2/.3 do not exist.
run_with_timeout 30 node - "$(np "$UNR_LOG")" "$(np "$ABS_LOG")" 2>/dev/null <<'JS'
const fs = require("fs");
const rec = (stage) => JSON.stringify({ v: 1, point: "complexity-judge", ts: "2026-10-01T00:00:01Z", session_id: "sid-u",
  stage, agreement: null, fallback_reason: null, jev: { status: "ok" }, llm: { status: "ok" } }) + "\n";
fs.writeFileSync(process.argv[2] + ".3", rec("gen3"));
fs.writeFileSync(process.argv[2] + ".1", rec("gen1"));
fs.writeFileSync(process.argv[3], rec("base") + "{not json\n");
JS

case_begin "r-unreadable-generation-reported" "bin/jev-report"
report "$J" --log "$(np "$UNR_LOG")" --point complexity-judge --json --no-sweep
check "--json: exit 0, unreadable_generations [.2, base], the readable .3 and .1 still aggregated" '0|[".2","base"]|2|gen1,gen3' \
  "$REP_RC|$(jx "o && JSON.stringify(o.unreadable_generations) + '|' + ($P).count + '|' + Object.keys(($P).by_stage || {}).sort().join(',')")"
check "stderr: one warning line naming both labels" "jev-report: warning: unreadable log generations skipped: .2 base" \
  "$(cat "$FX/io/report.err")"
T="$FX/io/unread.txt"
report "$T" --log "$(np "$UNR_LOG")" --point complexity-judge --no-sweep
check "text: exit 0, the unreadable line follows the broken-lines line" "0|unreadable generations: 2 (.2 base)" \
  "$REP_RC|$(tx 'lines[lines.findIndex((l) => l.startsWith("broken lines: ")) + 1]')"
case_end

case_begin "r-absent-generations-silent" "bin/jev-report"
report "$J" --log "$(np "$ABS_LOG")" --point complexity-judge --json --no-sweep
check "--json: .1/.2/.3 absent (ENOENT) gives unreadable_generations [], the base still read, an empty stderr" "0|[]|1|" \
  "$REP_RC|$(jx "o && JSON.stringify(o.unreadable_generations) + '|' + ($P).count")|$(cat "$FX/io/report.err")"
T="$FX/io/absent.txt"
report "$T" --log "$(np "$ABS_LOG")" --point complexity-judge --no-sweep
check "text: no unreadable line; broken lines is the last line" "0|0|broken lines: 1" \
  "$REP_RC|$(tx 'lines.filter((l) => l.startsWith("unreadable")).length + "|" + lines[lines.length - 1]')"
case_end
