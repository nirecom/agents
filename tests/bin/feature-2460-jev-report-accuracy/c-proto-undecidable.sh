#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate.js, bin/jev-report
# Tags: TL2, bin, jev, report, prototype-pollution, undecidable, json-output, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): Object.prototype names as ordinary keys, and S0-undecidable over both-ok records.

echo "=== Object.prototype names in the log are ordinary keys ==="
PROTO_LOG="$FX/fixture/proto-names.log"
# Three records whose point is an Object.prototype member name, and three complexity-judge
# records carrying such names as stage and fallback_reason. On a plain {} map the first
# record would land on an inherited function and the report would crash.
run_with_timeout 30 node -e '
  const rec = (top) => JSON.stringify(Object.assign({ v: 1, ts: "2026-10-01T00:00:01Z", session_id: "sid-p", stage: "outline",
    agreement: null, fallback_reason: null, jev: { status: "ok" }, llm: { status: "ok" } }, top));
  require("fs").writeFileSync(process.argv[1], [
    rec({ point: "constructor" }),
    rec({ point: "__proto__" }),
    rec({ point: "toString" }),
    rec({ point: "complexity-judge", stage: "__proto__" }),
    rec({ point: "complexity-judge", fallback_reason: "constructor" }),
    rec({ point: "complexity-judge", stage: "toString", fallback_reason: "hasOwnProperty" }),
  ].join("\n") + "\n");
' "$(np "$PROTO_LOG")" 2>/dev/null
OWN='((x, k) => Object.prototype.hasOwnProperty.call(x, k))'

case_begin "r-proto-names-json" "bin/jev-report"
check "fixture: six records, three of them under a prototype member name" "6|3" \
  "$(hq qa "$(np "$PROTO_LOG")" 'recs.length + "|" + recs.filter((r) => ["constructor", "__proto__", "toString"].includes(r.point)).length')"
report "$J" --log "$(np "$PROTO_LOG")" --json --no-sweep
check "--json: exit 0, parseable, no broken line" "0|0" "$REP_RC|$(jx 'o && o.broken_lines')"
check "--json: the four point names are own keys of points, and the only ones" \
  "true|__proto__,complexity-judge,constructor,toString" \
  "$(jx "o && ['constructor', '__proto__', 'toString', 'complexity-judge'].every((k) => $OWN(o.points, k)) + '|' + Object.keys(o.points).sort().join(',')")"
check "--json: record counts per point (constructor, __proto__, toString, complexity-judge)" "1|1|1|3" \
  "$(jx "o && ['constructor', '__proto__', 'toString', 'complexity-judge'].map((k) => $OWN(o.points, k) && o.points[k].count).join('|')")"
check "--json: by_stage.__proto__ and by_stage.toString are own counts of 1" "true|1|true|1|1" \
  "$(jx "($P) && [$OWN($P.by_stage, '__proto__'), $P.by_stage['__proto__'], $OWN($P.by_stage, 'toString'), $P.by_stage.toString, $P.by_stage.outline].join('|')")"
check "--json: fallback_reasons.constructor and .hasOwnProperty are own counts of 1" "true|1|true|1|2" \
  "$(jx "($P) && [$OWN($P.fallback_reasons, 'constructor'), $P.fallback_reasons.constructor, $OWN($P.fallback_reasons, 'hasOwnProperty'), $P.fallback_reasons.hasOwnProperty, Object.keys($P.fallback_reasons).length].join('|')")"
case_end

case_begin "r-proto-names-point-filter" "bin/jev-report"
report "$J" --log "$(np "$PROTO_LOG")" --point constructor --json --no-sweep
check "--point constructor: exit 0 and only that group, with its one record" "0|constructor|1" \
  "$REP_RC|$(jx "o && Object.keys(o.points).join(',') + '|' + ($OWN(o.points, 'constructor') && o.points.constructor.count)")"
report "$J" --log "$(np "$PROTO_LOG")" --point __proto__ --json --no-sweep
check "--point __proto__: exit 0 and only that group, with its one record" "0|__proto__|1" \
  "$REP_RC|$(jx "o && Object.keys(o.points).join(',') + '|' + ($OWN(o.points, '__proto__') && o.points['__proto__'].count)")"
report "$J" --log "$(np "$PROTO_LOG")" --point hasOwnProperty --json --no-sweep
check "--point hasOwnProperty (no such record): exit 0 and an empty points map" "0|0" \
  "$REP_RC|$(jx 'o && Object.keys(o.points).length')"
case_end

case_begin "r-proto-names-text" "bin/lib/jev-report-aggregate.js"
T="$FX/io/proto.txt"
report "$T" --log "$(np "$PROTO_LOG")" --no-sweep
check "text mode exits 0 with nothing on stderr" "0|" "$REP_RC|$(cat "$FX/io/report.err")"
check "headings: charset-clean names verbatim, the mixed-case one as -" \
  "== __proto__ ==|== complexity-judge ==|== constructor ==|== - ==" "$(tx 'lines.filter((l) => l.startsWith("== ")).join("|")')"
check "by stage and fallback lines of complexity-judge: sanitised keys with their counts" \
  "records: 3  by stage: __proto__=1 outline=1 -=1|fallback: 0.667  constructor=1 -=1" \
  "$(tx '((i) => lines[i + 1] + "|" + lines.slice(i).find((l) => l.startsWith("fallback: ")))(lines.indexOf("== complexity-judge =="))')"
check "no function source, [object ...] text or control character is printed" "false|false" \
  "$(tx '/function|\[object|native code/.test(text) + "|" + new RegExp("[\\u0000-\\u0009\\u000b-\\u001f\\u007f-\\u009f]").test(text)')"
case_end

echo "=== S0-undecidable is counted over both-ok records only ==="
UNDEC_LOG="$FX/fixture/undecidable.log"
# U1/U11 jev S0 (U1 inside a csv), U2 llm S0, U3 both S0, U4/U5 neither (the only compared ones);
# U6 low-confidence, U7 parse-fallback, U8 missing carry S0 but are not both-ok;
# U9/U10 are both-ok with non-string answers. Expected: n=4 jev=3 llm=2 (asymmetric, so a
# swapped jev/llm counter shows), agreement_n 2.
run_with_timeout 30 node -e '
  const rec = (n, jev, llm, agreement) => JSON.stringify({ v: 1, point: "complexity-judge", ts: "2026-10-01T00:00:0" + (n % 10) + "Z",
    session_id: "sid-u" + n, stage: "outline", agreement: agreement === undefined ? null : agreement, fallback_reason: null,
    jev: Object.assign({ status: "ok" }, jev), llm: Object.assign({ status: "ok" }, llm) });
  require("fs").writeFileSync(process.argv[1], [
    rec(1, { answer: "S1-multi-file,S0-undecidable" }, { answer: "S1-multi-file" }),
    rec(2, { answer: "S1-multi-file" }, { answer: "S0-undecidable" }),
    rec(3, { answer: "S0-undecidable" }, { answer: "S0-undecidable" }),
    rec(4, { answer: "S1-multi-file" }, { answer: "S1-multi-file" }, true),
    rec(5, { answer: "S2-architecture" }, { answer: "S1-multi-file" }, false),
    rec(6, { status: "low-confidence", answer: "S0-undecidable" }, { answer: "S0-undecidable" }),
    rec(7, { answer: "S0-undecidable" }, { status: "parse-fallback", answer: "S0-undecidable" }),
    rec(8, { answer: "S0-undecidable" }, { status: "missing", answer: null }),
    rec(9, { answer: null }, { answer: 5 }),
    rec(10, { answer: { "S0-undecidable": true } }, { answer: ["S0-undecidable"] }),
    rec(11, { answer: "S0-undecidable" }, { answer: "S2-architecture" }),
  ].join("\n") + "\n");
' "$(np "$UNDEC_LOG")" 2>/dev/null
UND="(($P).undecidable || {})"

case_begin "r-undecidable-split" "bin/jev-report"
check "fixture: eleven records, eight of them carry S0-undecidable somewhere (non-vacuity)" "11|8" \
  "$(hq qa "$(np "$UNDEC_LOG")" 'recs.length + "|" + recs.filter((r) => JSON.stringify([r.jev.answer, r.llm.answer]).includes("S0-undecidable")).length')"
report "$J" --log "$(np "$UNDEC_LOG")" --point complexity-judge --json --no-sweep
check "--json: exit 0, count 11, undecidable n=4 jev=3 llm=2 (jev != llm)" "0|11|4|3|2" \
  "$REP_RC|$(jx "($P) && [$P.count, $UND.n, $UND.jev, $UND.llm].join('|')")"
check "agreement still counts only the neither-S0 records (U4 agree, U5 disagree)" "2|0.5" \
  "$(jx "($P) && $P.agreement_n + '|' + $P.agreement_rate")"
case_end

case_begin "r-undecidable-excludes-non-both-ok" "bin/jev-report"
# Fixture 1: R3 low-confidence Jev S0 and R5 parse-fallback LLM S0 are its only S0 answers.
report "$J" --log "$(np "$FIX_LOG")" --point complexity-judge --json --no-sweep
check "low-confidence and parse-fallback S0 answers are not counted" "0|0|0|0" \
  "$REP_RC|$(jx "($P) && [$UND.n, $UND.jev, $UND.llm].join('|')")"
case_end

case_begin "r-undecidable-zero-point" "bin/jev-report"
report "$J" --log "$(np "$FIX_LOG")" --point other-point --json --no-sweep
check "a point with no S0 record reports {n:0, jev:0, llm:0}" '{"n":0,"jev":0,"llm":0}' \
  "$(jx 'o && o.points["other-point"] && JSON.stringify(o.points["other-point"].undecidable)')"
T="$FX/io/undec-zero.txt"
report "$T" --log "$(np "$FIX_LOG")" --point other-point --no-sweep
check "text: the zero line sits right after the agreement line" "0|undecidable: 0 (jev=0 llm=0)" \
  "$REP_RC|$(tx 'lines[lines.findIndex((l) => l.startsWith("agreement: ")) + 1]')"
case_end

case_begin "r-undecidable-text-line" "bin/lib/jev-report-aggregate.js"
T="$FX/io/undec.txt"
report "$T" --log "$(np "$UNDEC_LOG")" --point complexity-judge --no-sweep
check "text: exit 0 (non-string answers do not throw), nothing on stderr" "0|" "$REP_RC|$(cat "$FX/io/report.err")"
check "text: exactly one undecidable line, directly after the agreement line, jev and llm not swapped" "1|undecidable: 4 (jev=3 llm=2)" \
  "$(tx 'lines.filter((l) => l.startsWith("undecidable: ")).length + "|" + lines[lines.findIndex((l) => l.startsWith("agreement: ")) + 1]')"
case_end
