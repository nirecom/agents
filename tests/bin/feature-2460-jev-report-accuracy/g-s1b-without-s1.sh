#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate.js
# Tags: TL1, bin, jev, report, s1b-without-s1, agreement, dedupe, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): the S1b-without-S1 rubric gap per side, and such a record scoring as disagreement.

# s1b <scenario>: aggregatePoint over the scenario's records. Prints
#   s1b_without_s1 JSON|count|dropped|agreement_n|agreement_rate
# A both-ran record's stored agreement is compare() of its sides, as the record builder writes it.
S1B_JS="$TMPROOT/s1b-probe.js"
cat > "$S1B_JS" <<'JS'
"use strict";
const [aggPath, recPath, routingPath, scenario] = process.argv.slice(2);
const { aggregatePoint, formatText } = require(aggPath);
const { compare } = require(recPath);
const { SIGNAL_IDS } = require(routingPath);
const S1 = "S1-multi-file";
const S1B = "S1b-wide-change";
const S2 = "S2-architecture";
const BOTH = S1 + "," + S1B;
const NONE = { status: "missing", answer: null };
const NOTRUN = { status: "not-run", answer: null };
const ok = (answer) => ({ status: "ok", answer });
const rec = (tid, jev, llm) => {
  const c = compare(jev, llm);
  return { v: 1, point: "complexity-judge", ts: "2026-10-01T00:00:01Z", session_id: "sid-s", tool_use_id: tid,
    stage: "outline", jev, llm, fallback_reason: null, agreement: c.agreement, agreement_by_signal: c.agreement_by_signal };
};
const SC = {
  ids: null,
  "jev-s1b-only": [rec("t1", ok(S1B), ok(BOTH))],
  "llm-s1b-only": [rec("t1", ok(BOTH), ok(S1B))],
  "both-full": [rec("t1", ok(BOTH), ok(BOTH))],
  "both-s1b-only": [rec("t1", ok(S1B), ok(S1B))],
  "neither": [rec("t1", ok(S1), ok(S2)), rec("t2", ok(S2), ok(S1))],
  // Four S1b-only answers, each on a side whose status is not "ok".
  "not-ok-sides": [rec("t1", { status: "low-confidence", answer: S1B }, ok(BOTH)),
    rec("t2", { status: "unmappable", answer: S1B }, ok(S1)),
    rec("t3", ok(S1), { status: "missing", answer: S1B }),
    rec("t4", ok(BOTH), { status: "parse-fallback", answer: S1B })],
  // t1 logged twice (raw jev count 2 -> 1); t2 split into a Jev-only and an LLM-only record, merged.
  "dup": [rec("t1", ok(S1B), ok(BOTH)), rec("t1", ok(S1B), ok(BOTH)),
    rec("t2", ok(S1B), NONE), rec("t2", NOTRUN, ok(S1B))],
  "empty": [],
};
if (scenario === "ids") {
  process.stdout.write(String(SIGNAL_IDS.includes(S1) && SIGNAL_IDS.includes(S1B)));
} else if (scenario.startsWith("sig:")) {
  const p = aggregatePoint(SC[scenario.slice(4)], 0.9);
  process.stdout.write([p.agreement_by_signal[S1], p.agreement_by_signal[S1B]].join("|"));
} else if (scenario.startsWith("text:")) {
  const p = aggregatePoint(SC[scenario.slice(5)], 0.9);
  const lines = formatText({ points: { "complexity-judge": p }, broken_lines: 0 }).split("\n");
  const i = lines.findIndex((l) => l.startsWith("undecidable: "));
  process.stdout.write(lines.filter((l) => l.startsWith("S1b without S1")).length + "|" + lines[i + 1]);
} else {
  const p = aggregatePoint(SC[scenario], 0.9);
  const keys = Object.keys(p);
  const placed = keys[keys.indexOf("undecidable") + 1] === "s1b_without_s1";
  process.stdout.write([JSON.stringify(p.s1b_without_s1), p.count, p.duplicates_dropped, p.agreement_n, p.agreement_rate, placed].join("|"));
}
JS
s1b() {
  run_with_timeout 30 node "$(np "$S1B_JS")" "$REPO_N/bin/lib/jev-report-aggregate.js" "$RECORD_JS" \
    "$REPO_N/hooks/workflow-state/complexity-routing.js" "$1" 2>&1
}

echo "=== S1b without S1: raw rubric gap per side, and such a record scores as disagreement ==="
case_begin "d-s1b-without-s1-jev-side" "bin/lib/jev-report-aggregate.js"
check "the S1 and S1b literals are SIGNAL_IDS members (non-vacuity)" "true" "$(s1b ids)"
check "jev S1b only vs llm S1,S1b: {jev:1,llm:0}, agreement 0/1, key right after undecidable" \
  '{"jev":1,"llm":0}|1|0|1|0|true' "$(s1b jev-s1b-only)"
check "jev S1b only vs llm S1,S1b: per-signal S1 0, S1b 1" "0|1" "$(s1b sig:jev-s1b-only)"
case_end

case_begin "d-s1b-without-s1-llm-side" "bin/lib/jev-report-aggregate.js"
check "llm S1b only vs jev S1,S1b: {jev:0,llm:1}, agreement 0/1" '{"jev":0,"llm":1}|1|0|1|0|true' "$(s1b llm-s1b-only)"
check "llm S1b only vs jev S1,S1b: per-signal S1 0, S1b 1" "0|1" "$(s1b sig:llm-s1b-only)"
case_end

case_begin "d-s1b-without-s1-both-sides-violate" "bin/lib/jev-report-aggregate.js"
check "both sides S1b only: {jev:1,llm:1}, agreement 0/1 even though the raw answers are identical" \
  '{"jev":1,"llm":1}|1|0|1|0|true' "$(s1b both-s1b-only)"
check "both sides S1b only: per-signal S1 0, S1b 1" "0|1" "$(s1b sig:both-s1b-only)"
case_end

case_begin "d-s1b-without-s1-not-counted" "bin/lib/jev-report-aggregate.js"
check "both sides S1,S1b: zero, agreement 1/1" '{"jev":0,"llm":0}|1|0|1|1|true' "$(s1b both-full)"
check "both sides S1,S1b: per-signal S1 1, S1b 1" "1|1" "$(s1b sig:both-full)"
check "no side carries S1b: zero (S1 vs S2 disagree both ways)" '{"jev":0,"llm":0}|2|0|2|0|true' "$(s1b neither)"
check "S1b-only answers on low-confidence / unmappable / missing / parse-fallback sides: zero" \
  '{"jev":0,"llm":0}|4|0|0||true' "$(s1b not-ok-sides)"
case_end

case_begin "d-s1b-without-s1-after-dedupe" "bin/lib/jev-report-aggregate.js"
check "a duplicate counts once and a merged split counts on both sides: {jev:2,llm:1}, dropped 2" \
  '{"jev":2,"llm":1}|2|2|2|0|true' "$(s1b dup)"
case_end

case_begin "d-s1b-without-s1-empty" "bin/lib/jev-report-aggregate.js"
check "no records: the key is present as zero, no crash" '{"jev":0,"llm":0}|0|0|0||true' "$(s1b empty)"
case_end

case_begin "d-s1b-without-s1-text-line" "bin/lib/jev-report-aggregate.js"
check "text: exactly one S1b line, right after the undecidable line, jev and llm not swapped" \
  "1|S1b without S1: jev=1 llm=0" "$(s1b text:jev-s1b-only)"
check "text: the empty point prints the zero line" "1|S1b without S1: jev=0 llm=0" "$(s1b text:empty)"
case_end
