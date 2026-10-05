#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate.js, bin/jev-report
# Tags: TL2, bin, jev, report, timestamp-sanitiser, low-confidence-reference, dedupe, latency-percentiles, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): mismatch-row timestamps, the low-confidence reference, per-judgment dedupe,
# completed-call latency, and the default sweep.

echo "=== mismatch-row timestamps: ISO-8601 or a finite number, anything else - ==="
TS_LOG="$FX/fixture/ts-table.log"
# One both-ok mismatch per ts shape; session_id sid-ts-<name> identifies the row. NaN has no
# JSON form and is not tested; 1e999 / -1e999 parse to +/-Infinity, which stand in for it.
run_with_timeout 30 node -e '
  const ESC = String.fromCharCode(27);
  const rows = [["iso-z", "2026-10-01T00:00:01Z"], ["iso-frac", "2026-10-01T00:00:01.123456Z"],
    ["iso-offset", "2026-10-01T09:00:01+09:00"], ["number", 1790000000000], ["number-frac", 1.5],
    ["date-only", "2026-10-01"], ["esc", "2026-10-01T00:00:01Z" + ESC + "[2J"], ["newline", "2026-10-01T00:00:01Z\n"],
    ["object", {}], ["array", ["2026-10-01T00:00:01Z"]], ["bool", true], ["null", null], ["infinity", "__INF__"],
    ["neg-infinity", "__NINF__"], ["non-iso", "Oct 1 2026 00:00:01"], ["space-sep", "2026-10-01 00:00:01Z"]];
  require("fs").writeFileSync(process.argv[1], rows.map(([name, ts]) => JSON.stringify({ v: 1, point: "complexity-judge", ts,
    session_id: "sid-ts-" + name, stage: "outline", agreement: false, fallback_reason: null,
    jev: { status: "ok", answer: "S1-multi-file" }, llm: { status: "ok", answer: "S2-architecture" } })
    .replace("\"__INF__\"", "1e999").replace("\"__NINF__\"", "-1e999")).join("\n") + "\n");
' "$(np "$TS_LOG")" 2>/dev/null
T="$FX/io/ts-table.txt"

case_begin "r-text-mismatch-ts-table" "bin/lib/jev-report-aggregate.js"
check "fixture: 16 records, two of them parse to +/-Infinity (non-vacuity)" "16|2" \
  "$(hq qa "$(np "$TS_LOG")" 'recs.length + "|" + recs.filter((r) => r.ts === Infinity || r.ts === -Infinity).length')"
report "$T" --log "$(np "$TS_LOG")" --point complexity-judge --no-sweep
check "text: exit 0, one mismatch row per record" "0|mismatches: 16" "$REP_RC|$(tx 'lines.find((l) => l.startsWith("mismatches: "))')"
while IFS='|' read -r name want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  want="${want//[[:space:]]/}"
  check "ts $name prints as $want" "$want" \
    "$(tx "((l) => (l ? l.trim().split(' ')[0] : 'NO-ROW'))(lines.find((x) => x.startsWith('  ') && x.includes(' sid-ts-$name ')))" < /dev/null)"
done <<'TABLE'
iso-z        | 2026-10-01T00:00:01Z
iso-frac     | 2026-10-01T00:00:01.123456Z
iso-offset   | 2026-10-01T09:00:01+09:00
number       | 1790000000000
number-frac  | 1.5
date-only    | -
esc          | -
newline      | -
object       | -
array        | -
bool         | -
null         | -
infinity     | -
neg-infinity | -
non-iso      | -
space-sep    | -
TABLE
case_end

echo "=== the low-confidence reference skips LLM S0 answers and reports its own n ==="
LC_LOG="$FX/fixture/low-conf-ref.log"
# L1/L2 are the only compared records: L1 Jev {S1,S2} vs LLM {S1}, L2 Jev {S1,S3} vs LLM {S1,S3},
# so S2 = 1/2 and every other signal 1. L3 (LLM S0, Jev {S2,S3}) is skipped and counted; had
# it been compared S2 would read 1/3 and S3 2/3. L4 has no probabilities, L5/L6 a non-ok LLM.
run_with_timeout 30 node -e '
  const ids = process.argv[2].split(",");
  const probs = (over) => Object.fromEntries(ids.map((k) => [k, over[k] !== undefined ? over[k] : 0.02]));
  const rec = (n, pr, llm) => JSON.stringify({ v: 1, point: "complexity-judge", ts: "2026-10-01T00:00:0" + n + "Z",
    session_id: "sid-l" + n, stage: "outline", agreement: null, fallback_reason: "low-confidence",
    jev: { status: "low-confidence", answer: "S0-undecidable", probabilities: pr, min_confidence: 0.6 },
    llm: Object.assign({ status: "ok" }, llm) });
  require("fs").writeFileSync(process.argv[1], [
    rec(1, probs({ "S1-multi-file": 0.9, "S2-architecture": 0.6 }), { answer: "S1-multi-file" }),
    rec(2, probs({ "S1-multi-file": 0.9, "S3-security": 0.7 }), { answer: "S1-multi-file,S3-security" }),
    rec(3, probs({ "S2-architecture": 0.9, "S3-security": 0.9 }), { answer: "S0-undecidable" }),
    rec(4, null, { answer: "S0-undecidable" }),
    rec(5, probs({ "S2-architecture": 0.9 }), { status: "parse-fallback", answer: "S0-undecidable" }),
    rec(6, probs({ "S2-architecture": 0.9 }), { status: "missing", answer: null }),
  ].join("\n") + "\n");
' "$(np "$LC_LOG")" "$SIGNAL_CSV" 2>/dev/null

case_begin "r-low-confidence-reference-skips-llm-s0" "bin/lib/jev-report-aggregate.js"
report "$J" --log "$(np "$LC_LOG")" --point complexity-judge --json --no-sweep
check "--json: exit 0, count 6, low_confidence_reference_n 2, low_confidence_reference_llm_undecidable 1" "0|6|2|1" \
  "$REP_RC|$(jx "($P) && [$P.count, $P.low_confidence_reference_n, $P.low_confidence_reference_llm_undecidable].join('|')")"
check "--json: reference ratios over L1/L2 only (S2 0.5, every other signal 1)" "1|1|0.5|1|1|1|1" \
  "$(jx "($P) && '$SIGNAL_CSV'.split(',').map((k) => $P.low_confidence_reference_by_signal[k]).join('|')")"
T="$FX/io/low-conf-ref.txt"
report "$T" --log "$(np "$LC_LOG")" --point complexity-judge --no-sweep
check "text: the reference line carries the same ratios and ends with the n / llm-undecidable suffix" \
  "0|low-confidence reference by signal: S1-multi-file=1 S1b-wide-change=1 S2-architecture=0.5 S3-security=1 S4-installer=1 S5-breaking=1 S6-long-plan=1  (n=2 llm-undecidable=1)" \
  "$REP_RC|$(tx 'lines.find((l) => l.startsWith("low-confidence reference by signal: "))')"
case_end

echo "=== one record per (session_id, tool_use_id); latency samples only from completed calls ==="
DUP_LOG="$FX/fixture/dup.log"
LAT_LOG="$FX/fixture/lat.log"
# dup: the stage names each record; kept = a2 (llm ran beats jev-only, though later), b1 (same tid,
# other session), c1-c3 (no / empty tool_use_id), t1 (tie: earliest), j2 (jev ran), k1 (k1's jev + k2's llm merged).
# lat: L3's timeout 99999 and L4's missing 5 must not move p50/p95; L3's parse-fallback 88888 must.
run_with_timeout 30 node - "$(np "$DUP_LOG")" "$(np "$LAT_LOG")" 2>/dev/null <<'JS'
const fs = require("fs");
const rec = (stage, sid, tid, js, ls, extra) => Object.assign({ v: 1, point: "complexity-judge", ts: "2026-10-01T00:00:01Z",
  session_id: sid, tool_use_id: tid, stage, agreement: null, fallback_reason: null,
  jev: { status: js, latency_ms: 10 }, llm: { status: ls, latency_ms: 20 } }, extra || {});
const noTid = (r) => { delete r.tool_use_id; return r; };
const D = [
  rec("a1", "sid-a", "toolu_x", "ok", "missing"), rec("a2", "sid-a", "toolu_x", "ok", "ok", { agreement: true }),
  rec("b1", "sid-b", "toolu_x", "ok", "ok", { agreement: false }),
  noTid(rec("c1", "sid-c", null, "ok", "ok")), noTid(rec("c2", "sid-c", null, "ok", "ok")), rec("c3", "sid-c", "", "ok", "ok"),
  rec("t1", "sid-t", "toolu_t", "ok", "ok"), rec("t2", "sid-t", "toolu_t", "ok", "ok", { agreement: true }),
  rec("j1", "sid-j", "toolu_j", "not-run", "missing"), rec("j2", "sid-j", "toolu_j", "ok", "missing"),
  rec("k1", "sid-k", "toolu_k", "ok", "missing", { jev: { status: "ok", answer: "S1-multi-file", latency_ms: 777, est_cost_usd: 0.25 } }),
  rec("k2", "sid-k", "toolu_k", "not-run", "ok", { llm: { status: "ok", answer: "S2-architecture", latency_ms: 888 } }),
];
const lat = (n, js, jl, ls, ll) => rec("outline", "sid-l", "toolu_l" + n, js, ls, { jev: { status: js, latency_ms: jl }, llm: { status: ls, latency_ms: ll } });
const L = [lat(1, "ok", 100, "ok", 1000), lat(2, "ok", 200, "ok", 2000),
  lat(3, "timeout", 99999, "parse-fallback", 88888), lat(4, "low-confidence", 300, "missing", 5)];
fs.writeFileSync(process.argv[2], D.map((r) => JSON.stringify(r)).join("\n") + "\n");
fs.writeFileSync(process.argv[3], L.map((r) => JSON.stringify(r)).join("\n") + "\n");
JS

case_begin "r-dedupe-per-judgment" "bin/lib/jev-report-aggregate.js"
check "fixture: twelve records, three without a usable tool_use_id (non-vacuity)" "12|3" \
  "$(hq qa "$(np "$DUP_LOG")" 'recs.length + "|" + recs.filter((r) => !r.tool_use_id).length')"
report "$J" --log "$(np "$DUP_LOG")" --point complexity-judge --json --no-sweep
check "--json: exit 0, count 8, duplicates_dropped 4" "0|8|4" "$REP_RC|$(jx "($P) && $P.count + '|' + $P.duplicates_dropped")"
check "kept: llm-ran over jev-only, jev-ran over neither, earliest on a tie; other sessions and id-less records untouched" \
  "a2,b1,c1,c2,c3,j2,k1,t1" "$(jx "($P) && Object.keys($P.by_stage).sort().join(',')")"
check "agreement counts a2, b1 and the merged k1 (recomputed: S1 vs S2 disagree); the dropped tie t2 is not compared" "3|0.333" \
  "$(jx "($P) && $P.agreement_n + '|' + $P.agreement_rate.toFixed(3)")"
check "merged k1 carries k1's jev answer, cost and latency with k2's llm answer and latency" "k1|S1-multi-file|S2-architecture|0.25|777|888" \
  "$(jx "($P) && [...$P.mismatches.filter(m => m.stage === 'k1').map(m => [m.stage, m.jev, m.llm].join('|')), $P.est_cost_usd_total, $P.latency_ms.jev.p95, $P.latency_ms.llm.p95].join('|')")"
T="$FX/io/dup.txt"
report "$T" --log "$(np "$DUP_LOG")" --point complexity-judge --no-sweep
check "text: the duplicates line sits right after the cost line" "0|duplicates dropped: 4" \
  "$REP_RC|$(tx 'lines[lines.findIndex((l) => l.startsWith("est cost usd total: ")) + 1]')"
report "$J" --log "$(np "$FIX_LOG")" --point complexity-judge --json --no-sweep
check "a log without duplicates reports duplicates_dropped 0" "0" "$(jx "($P) && $P.duplicates_dropped")"
case_end

case_begin "r-latency-completed-calls" "bin/lib/jev-report-aggregate.js"
report "$J" --log "$(np "$LAT_LOG")" --point complexity-judge --json --no-sweep
# llm {1000,2000,88888}: with missing 5 included p50 would be 1000; without parse-fallback p95 would be 2000.
check "jev p50 200 / p95 300 (timeout 99999 excluded); llm p50 2000 / p95 88888 (parse-fallback included, missing excluded)" \
  "0|4|200|300|2000|88888" "$REP_RC|$(jx "($P) && [$P.count, $P.latency_ms.jev.p50, $P.latency_ms.jev.p95, $P.latency_ms.llm.p50, $P.latency_ms.llm.p95].join('|')")"
case_end

echo "=== sweep on by default, off with --no-sweep ==="
case_begin "r-no-sweep-leaves-pending" "bin/jev-report"
mock_start
mock_mode '{}'
mkpayload "$FX/io/pre.json" pre jev2460-r-sweep toolu_r_sweep
run_hook pre "$FX/io/pre.json"
check "fixture: one pending file from a real pre hook" "1" "$(pending_count)"
[ -d "$JEVDIR/jev2460-r-sweep" ] && hq age "$(np "$JEVDIR/jev2460-r-sweep")" 7200000 --recursive
report "$FX/io/ns.txt" --no-sweep
check "--no-sweep: exit 0, pending kept, no orphan record" "0|1|0" "$REP_RC|$(pending_count)|$(rq toolu_r_sweep 'recs.length')"
report "$FX/io/sw.txt"
check "default: exit 0, pending swept into one llm-missing record" "0|0|1|missing" \
  "$REP_RC|$(pending_count)|$(rq toolu_r_sweep 'recs.length + "|" + (r && r.llm.status)')"
case_end
