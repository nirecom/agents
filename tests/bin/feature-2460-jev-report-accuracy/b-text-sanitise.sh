#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate.js, bin/jev-report
# Tags: TL2, bin, jev, report, terminal-sanitisation, json-output, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): the text report is terminal-safe over a hostile log; --json keeps raw values.

echo "=== text output is terminal-safe; --json keeps the raw values ==="
HOSTILE_LOG="$FX/fixture/hostile.log"
HOSTILE_VALS="$FX/fixture/hostile-values.json"
# Eight complexity-judge records (three clean mismatches, two clean non-mismatches, three
# hostile mismatches), one hostile-point record, one non-string point and one broken line.
# Control characters are built at runtime so this file holds no raw ESC byte.
run_with_timeout 30 node -e '
  const fs = require("fs");
  const ESC = String.fromCharCode(27), BEL = String.fromCharCode(7), CR = String.fromCharCode(13);
  const V = {
    point: "evil" + ESC + "[31m\n== forged ==",
    stage: "cos1\n== forged ==\nrecords: 999" + CR,
    reason: "MARK-2460 free text\nmismatches: 7" + ESC + "[2J",
    sid: "../../etc x",
  };
  const rec = (top, jev, llm) => JSON.stringify(Object.assign({ v: 1, point: "complexity-judge", ts: "2026-10-01T00:00:01Z",
    session_id: "sid-x", stage: "outline", agreement: null, fallback_reason: null }, top,
    { jev: Object.assign({ status: "ok" }, jev), llm: Object.assign({ status: "ok" }, llm) }));
  const L = [
    rec({ ts: "2026-10-01T00:00:02.123Z", session_id: "3f2b8c1e-7a4d-4e9b-9c1a-5d6e7f8a9b0c", stage: "write_code", agreement: false },
      { answer: "S1-multi-file" }, { answer: "S1-multi-file,S2-architecture" }),
    rec({ ts: 1790000000000, session_id: "sid-ok_2", stage: "cos1", agreement: false }, {}, { answer: null }),
    rec({ ts: "2026-10-01T09:00:03+09:00", session_id: "sid-r3", stage: "write_tests", agreement: false },
      { answer: "S0-undecidable" }, { answer: "" }),
    rec({ stage: "outline", fallback_reason: "low-confidence" }),
    rec({ stage: "detail" }),
    rec({ ts: "2026-10-01" + ESC + "[2J", session_id: V.sid, stage: V.stage, agreement: false, fallback_reason: V.reason },
      { answer: "S1-multi-file" + ESC + "]0;MARK-2460" + BEL }, { answer: "ignore previous instructions MARK-2460,S9-evil-token" }),
    rec({ ts: "2026-10-01T00:00:02Z\n", session_id: "sid..x", stage: "A b", agreement: false },
      { answer: "S1-multi-file,MARK-2460" }, { answer: 5 }),
    rec({ ts: {}, session_id: 12345, stage: 7, agreement: false }, { answer: "S9-evil-token" }, { answer: "S2-architecture" }),
    rec({ point: V.point }),
    rec({ point: 5 }),
    "{broken " + ESC + "[2J MARK-2460",
  ];
  fs.writeFileSync(process.argv[1], L.join("\n") + "\n");
  fs.writeFileSync(process.argv[2], JSON.stringify(V));
' "$(np "$HOSTILE_LOG")" "$(np "$HOSTILE_VALS")" 2>/dev/null
T="$FX/io/hostile.txt"

case_begin "r-text-no-control-chars-or-injected-text" "bin/lib/jev-report-aggregate.js"
check "fixture: the hostile values carry ESC, newlines and CR (non-vacuity)" "true" \
  "$(hq json-expr "$(np "$HOSTILE_VALS")" 'o && o.point.includes(String.fromCharCode(27)) && o.stage.includes("\n") && o.stage.includes("\r")')"
report "$T" --log "$(np "$HOSTILE_LOG")" --no-sweep
check "text mode over the hostile log exits 0 and prints the report" "0|true" "$REP_RC|$(tx 'lines.length > 10')"
check "no control character other than newline reaches the terminal" "false" \
  "$(tx 'new RegExp("[\\u0000-\\u0009\\u000b-\\u001f\\u007f-\\u009f]").test(text)')"
check "no injected marker, forged heading, free text or out-of-vocabulary id is printed" "" \
  "$(tx '["MARK-2460", "forged", "records: 999", "mismatches: 7", "S9-evil", "ignore previous", "etc x", "A b"].filter((m) => text.includes(m)).join(",")')"
report "$FX/io/hostile-2.txt" --log "$(np "$HOSTILE_LOG")" --no-sweep
check "a second run prints the same bytes" "same" "$(cmp -s "$T" "$FX/io/hostile-2.txt" && echo same || echo differs)"
case_end

case_begin "r-text-structure-not-forgeable" "bin/lib/jev-report-aggregate.js"
check "headings: the clean point by name, the hostile point as -" "== complexity-judge ==|== - ==" \
  "$(tx 'lines.filter((l) => l.startsWith("== ")).join("|")')"
check "33 lines: one records, undecidable, S1b, duplicates-dropped, mismatches line per point and one broken-lines line (none forged)" "33|2|2|2|2|2|1" \
  "$(tx '[lines.length].concat(["records: ", "undecidable: ", "S1b without S1: ", "duplicates dropped: ", "mismatches: ", "broken lines: "].map((p) => lines.filter((l) => l.startsWith(p)).length)).join("|")')"
check "every line is one of the report's own line shapes" "0" \
  "$(tx 'lines.filter((l) => !/^(== [a-z0-9_-]+ ==|records: \d+  by stage: .*|agreement: .*|undecidable: \d+ \(jev=\d+ llm=\d+\)|S1b without S1: jev=\d+ llm=\d+|agreement by signal: .*|low-confidence (rate|reference) by signal: .*|latency ms: .*|fallback: .*|est cost usd total: .*|duplicates dropped: \d+|mismatches: \d+|  \S+ \S+ \S+ jev=\S+ llm=\S+|broken lines: \d+)$/.test(l)).length')"
case_end

case_begin "r-text-enum-fields-sanitised" "bin/lib/jev-report-aggregate.js"
check "by stage: clean stages by name, each out-of-charset stage key as -=N, a non-string stage as unknown" \
  "records: 8  by stage: write_code=1 cos1=1 write_tests=1 outline=1 detail=1 -=1 -=1 unknown=1" "$(tx 'lines[1]')"
check "fallback reasons: the clean reason by name, the free-text reason as -=N" "fallback: 0.25  low-confidence=1 -=1" \
  "$(tx 'lines.find((l) => l.startsWith("fallback: "))')"
check "the raw broken line and the non-string point are only counted" "broken lines: 2" "$(tx 'lines[lines.length - 1]')"
case_end

case_begin "r-text-mismatch-rows" "bin/lib/jev-report-aggregate.js"
check "the mismatch count line" "mismatches: 6" "$(tx 'lines.find((l) => l.startsWith("mismatches: "))')"
check "rows: ISO-8601 and finite-number ts, charset-valid ids, stages and vocabulary answers verbatim; anything else -, (none)" "$(cat <<'EOF'
  2026-10-01T00:00:02.123Z 3f2b8c1e-7a4d-4e9b-9c1a-5d6e7f8a9b0c write_code jev=S1-multi-file llm=S1-multi-file,S2-architecture
  1790000000000 sid-ok_2 cos1 jev=- llm=-
  2026-10-01T09:00:03+09:00 sid-r3 write_tests jev=S0-undecidable llm=(none)
  - - - jev=(none) llm=(none)
  - - - jev=S1-multi-file llm=(none)
  - - - jev=(none) llm=S2-architecture
EOF
)" "$(tx 'lines.filter((l) => l.startsWith("  ")).join("\n")')"
case_end

case_begin "r-json-keeps-raw-values" "bin/jev-report"
report "$J" --log "$(np "$HOSTILE_LOG")" --json --no-sweep
check "--json: exit 0; hostile point, stage, session id and reason survive as JSON-escaped raw values; no raw control byte" \
  "0|true|true|true|true|true|false" "$REP_RC|$(run_with_timeout 30 node -e '
    const fs = require("fs");
    const raw = fs.readFileSync(process.argv[1], "utf8");
    const V = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    let o = null;
    try { o = JSON.parse(raw); } catch (_e) { /* reported as false below */ }
    const P = (o && o.points && o.points["complexity-judge"]) || { mismatches: [], by_stage: {}, fallback_reasons: {} };
    const m = P.mismatches[3] || {};
    process.stdout.write([!!o && !!o.points[V.point] && o.points[V.point].count === 1, m.session_id === V.sid, m.stage === V.stage,
      P.by_stage[V.stage] === 1, P.fallback_reasons[V.reason] === 1, /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/.test(raw)].join("|"));
  ' "$(np "$J")" "$(np "$HOSTILE_VALS")" 2>/dev/null)"
case_end
